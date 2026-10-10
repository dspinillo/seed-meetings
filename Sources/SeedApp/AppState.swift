import AVFoundation
import Foundation
import SeedKit
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    let store = MeetingStore()

    @Published var meetings: [Meeting] = []
    @Published var session: RecordingSession?
    @Published var processingStage: [String: String] = [:]
    @Published var selectedMeetingID: String?
    @Published var lastError: String?
    @Published var detected: DetectedMeeting?
    @Published var searchText = ""
    @Published var openLibraryTick = 0
    @Published var chatBusy: Set<String> = []
    @Published var chatTick = 0
    /// Incrementa quando uma nota por voz é gravada em notas.md — a view
    /// aberta recarrega o TextEditor (que segura uma cópia do texto).
    @Published var notesTick = 0
    /// Incrementa quando speakers.json de alguma reunião muda (refino em 2º
    /// plano terminou) — a view aberta recarrega os chips de participantes.
    @Published var speakersTick = 0
    @Published var folderFilter: String?  // nil = todas; "" = sem pasta
    @Published var showPreferences = false
    @Published var liveLines: [String] = []

    private var liveTask: Task<Void, Never>?
    private var livePendingMic: [Float] = []
    private var livePendingSystem: [Float] = []
    private var liveOffsetMic = 0        // amostras já consumidas (16 kHz)
    private var liveOffsetSystem = 0
    private var liveUtterances: [Utterance] = []

    private var searchCache: [String: String] = [:]
    /// Reuniões com indexação em andamento; invalidar remove daqui para o
    /// resultado antigo ser descartado e o próximo refresh reindexar.
    private var searchIndexing: Set<String> = []

    var allFolders: [String] {
        Set(meetings.compactMap(\.folder)).sorted()
    }

    var allTags: [String] {
        Set(meetings.flatMap(\.tags)).sorted()
    }

    var filteredMeetings: [Meeting] {
        var result = meetings
        if let folderFilter {
            result = result.filter { folderFilter.isEmpty ? $0.folder == nil : $0.folder == folderFilter }
        }
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return result }
        return result.filter { meeting in
            meeting.title.lowercased().contains(query)
                || meeting.tags.joined(separator: " ").lowercased().contains(query)
                || (meeting.folder ?? "").lowercased().contains(query)
                || (searchCache[meeting.id]?.contains(query) ?? false)
        }
    }

    private var recordingSource: DetectedMeeting.Source?
    private var recordingViaBrowser = false
    private var dismissedUntil: [String: Date] = [:]
    private var notifiedKeys: Set<String> = []
    private var meetTabMisses = 0
    private var lastAudibleAt = Date()
    private var monitorTask: Task<Void, Never>?
    private var lastTickLine = ""
    private var sigtermSource: DispatchSourceSignal?

    /// Silêncio na trilha do sistema que dispara o auto-stop (gravações detectadas).
    private let silenceLimitSeconds: Double = 150

    @Published var notificationsDenied = false

    private init() {
        rotateDetectorLog()
        installTerminationLogging()
        refresh()
        let store = self.store
        let retentionDays = SeedSettings.load().retentionDays
        Task.detached(priority: .background) {
            store.purgeAudio(olderThanDays: retentionDays)
        }
        Notifier.shared.setup()
        Notifier.shared.checkAuthorization { [weak self] status in
            Task { @MainActor in
                self?.notificationsDenied = (status == "denied")
                self?.dlog("launch: notificações=\(status)")
            }
        }
        Notifier.shared.onRecordAction = { [weak self] meeting in
            self?.acceptDetection(meeting)
        }
        Task.detached(priority: .background) {
            await Pipeline.shared.warmUp()
        }
        recoverOrphans()
        startMonitor()

        // atalho global da nota por voz (registro adiado: HotkeyManager não
        // pode tocar AppState.shared de forma reentrante durante este init)
        Task { @MainActor in
            HotkeyManager.shared.onPressed = { VoiceNoteController.shared.hotkeyPressed() }
            HotkeyManager.shared.onReleased = { VoiceNoteController.shared.hotkeyReleased() }
            HotkeyManager.shared.apply(SeedSettings.load())
        }
    }

    /// Resgata reuniões órfãs (app morreu gravando/processando): se o áudio é
    /// legível (>5s, gravação em .caf sobrevive a crash), reprocessa; senão,
    /// marca como falha com explicação.
    private func recoverOrphans() {
        for orphan in meetings where orphan.status == .recording || orphan.status == .processing {
            var meeting = orphan
            let duration = Self.audioDuration(meeting.micURL) ?? Self.audioDuration(meeting.systemURL)
            if let duration, duration > 5 {
                meeting.durationSeconds = max(meeting.durationSeconds, duration)
                store.save(meeting)
                dlog("resgate: reprocessando gravação órfã \(meeting.id) (\(Int(duration))s de áudio)")
                processingStage[meeting.id] = "Na fila…"
                let recovered = meeting
                Task { @MainActor in
                    await self.waitUntilIdle()
                    self.process(recovered)
                }
            } else {
                meeting.status = .failed
                meeting.errorMessage = "Gravação interrompida (o app fechou durante a reunião) e o áudio não pôde ser recuperado."
                store.save(meeting)
                dlog("resgate: órfã \(meeting.id) sem áudio recuperável — marcada como falha")
            }
        }

        // refino interrompido (app fechou no meio): ready + refined=false com
        // áudio ainda em disco → re-enfileira o refino silencioso, idempotente
        let store = self.store
        for meeting in meetings
        where meeting.status == .ready && meeting.refined == false
            && FileManager.default.fileExists(atPath: meeting.systemURL.path) {
            dlog("resgate: retomando refino interrompido de \(meeting.id)")
            Task.detached(priority: .utility) {
                await AppState.shared.waitUntilIdle()
                _ = await Pipeline.shared.process(meeting, store: store, silent: true)
                await MainActor.run {
                    AppState.shared.searchCacheInvalidate(meeting.id)
                    AppState.shared.refresh()
                    AppState.shared.speakersTick += 1
                }
            }
        }
        refresh()
    }

    /// Resgates do launch esperam a máquina ficar livre: quem reabre o app
    /// para gravar não pode disputar CPU/disco com ASR + diarização de uma
    /// reunião antiga (somado à carga dos modelos, foi o que travou em 08/10).
    private func waitUntilIdle() async {
        try? await Task.sleep(nanoseconds: 30_000_000_000)
        while session != nil {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
        }
    }

    private static func audioDuration(_ url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { return nil }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    var isRecording: Bool { session != nil }

    func refresh() {
        meetings = store.list()
        // índice de busca (resumo + transcript de cada reunião) montado fora
        // da main thread — no launch isso segurava a janela até ler tudo
        let pending = meetings.filter {
            $0.status == .ready && searchCache[$0.id] == nil && !searchIndexing.contains($0.id)
        }
        guard !pending.isEmpty else { return }
        searchIndexing.formUnion(pending.map(\.id))
        let store = self.store
        Task.detached(priority: .utility) {
            var built: [String: String] = [:]
            for meeting in pending {
                let summary = store.readSummary(meeting) ?? ""
                let transcript = store.readTranscript(meeting) ?? ""
                built[meeting.id] = (summary + " " + transcript).lowercased()
            }
            let result = built
            await MainActor.run {
                let state = AppState.shared
                for (id, text) in result where state.searchIndexing.remove(id) != nil {
                    state.searchCache[id] = text
                }
                // busca digitada antes do índice ficar pronto: reavalia o filtro
                if !state.searchText.isEmpty { state.objectWillChange.send() }
            }
        }
    }

    func meeting(id: String?) -> Meeting? {
        guard let id else { return nil }
        return meetings.first { $0.id == id }
    }

    // MARK: - Gravação

    func startRecording(title: String? = nil, source: DetectedMeeting.Source? = nil, viaBrowser: Bool = false) {
        guard session == nil else { return }
        lastError = nil
        detected = nil
        Task {
            var created: Meeting?
            do {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "pt_BR")
                formatter.dateFormat = "HH:mm"
                let meetingTitle = title ?? "Reunião das \(formatter.string(from: Date()))"
                var meeting = try store.create(title: meetingTitle)
                meeting.template = SeedSettings.load().defaultTemplate
                store.save(meeting)
                created = meeting
                let newSession = try RecordingSession(meeting: meeting)
                try await newSession.start()
                session = newSession
                recordingSource = source
                recordingViaBrowser = viaBrowser
                meetTabMisses = 0
                lastAudibleAt = Date()
                selectedMeetingID = meeting.id
                refresh()
                FloatingBubble.shared.show()
                liveLines = []
                livePendingMic = []
                livePendingSystem = []
                liveOffsetMic = 0
                liveOffsetSystem = 0
                liveUtterances = []
                startLiveLoop()
            } catch {
                if let created { store.delete(created) }
                lastError = "\(error)"
                refresh()
            }
        }
    }

    /// Abre a janela principal na reunião atual (usado pela bolha flutuante).
    func openLibrary() {
        if let session { selectedMeetingID = session.meeting.id }
        openLibraryTick += 1
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.windows.first { $0.title == "Seed" }?.makeKeyAndOrderFront(nil)
    }

    func stopRecording() {
        guard let current = session else { return }
        FloatingBubble.shared.hide()
        liveTask?.cancel()
        liveTask = nil
        session = nil
        recordingSource = nil
        recordingViaBrowser = false
        let (micSeconds, systemSeconds) = current.stop()

        // último drain: o que ficou nos buffers entra no transcript rápido
        let (mic, system) = current.drainLive()
        livePendingMic.append(contentsOf: mic)
        livePendingSystem.append(contentsOf: system)

        let meeting = store.update(current.meeting) {
            $0.durationSeconds = max(micSeconds, systemSeconds)
            $0.status = .processing
        }
        refresh()
        selectedMeetingID = meeting.id
        processingStage[meeting.id] = "Finalizando transcript…"

        let store = self.store
        Task { @MainActor in
            // flush dos rabos finais das duas trilhas
            await consumeLive(isMic: true, flush: true)
            await consumeLive(isMic: false, flush: true)
            let utterances = liveUtterances

            // caminho rápido: resumo na hora a partir do transcript ao vivo
            let fast = await Pipeline.shared.finishFast(meeting, store: store, utterances: utterances) { stage in
                Task { @MainActor in
                    AppState.shared.processingStage[meeting.id] = stage
                }
            }
            processingStage[meeting.id] = nil
            searchCacheInvalidate(meeting.id)
            refresh()
            if fast.status == .ready {
                Notifier.shared.notify(title: "Resumo pronto 🌱", body: fast.title)
            }

            // refino de qualidade total em 2º plano (substitui os arquivos em silêncio)
            guard fast.status == .ready, fast.refined == false else { return }
            Task.detached(priority: .utility) {
                _ = await Pipeline.shared.process(fast, store: store, silent: true)
                await MainActor.run {
                    AppState.shared.searchCacheInvalidate(meeting.id)
                    AppState.shared.refresh()
                    AppState.shared.speakersTick += 1
                }
            }
        }
    }

    // MARK: - Transcrição ao vivo

    private func startLiveLoop() {
        liveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            while !Task.isCancelled {
                await self?.liveTick()
                try? await Task.sleep(nanoseconds: 12_000_000_000)
            }
        }
    }

    private func liveTick() async {
        guard let session else { return }
        let (mic, system) = session.drainLive()
        livePendingMic.append(contentsOf: mic)
        livePendingSystem.append(contentsOf: system)
        await consumeLive(isMic: true)
        await consumeLive(isMic: false)
    }

    /// Consome o buffer pendente da trilha cortando em PAUSAS (não no relógio),
    /// para não mutilar palavras — qualidade do transcript rápido.
    private func consumeLive(isMic: Bool, flush: Bool = false) async {
        let pending = isMic ? livePendingMic : livePendingSystem
        let head: [Float]
        let tail: [Float]
        if flush {
            head = pending
            tail = []
            guard head.count >= 8_000 else { return } // ≥0,5s no flush final
        } else {
            guard let split = LiveSegmenter.splitAtPause(pending) else { return }
            head = split.head
            tail = split.tail
        }
        if isMic { livePendingMic = tail } else { livePendingSystem = tail }
        let offset = isMic ? liveOffsetMic : liveOffsetSystem
        let newOffset = offset + head.count
        if isMic { liveOffsetMic = newOffset } else { liveOffsetSystem = newOffset }

        // silêncio não gasta ASR (mas o offset avança para manter o relógio)
        let rms = (head.reduce(Float(0)) { $0 + $1 * $1 } / Float(head.count)).squareRoot()
        guard rms > 0.004 else { return }
        guard let text = try? await Pipeline.shared.transcribeSamples(head), !text.isEmpty,
              // caco de inglês alucinado (code-switch na reunião): o refinado
              // já filtra via TranscriptBuilder; o live segue a mesma política
              !TranscriptBuilder.isEnglishShard(text) else { return }

        let utterance = Utterance(
            start: Double(offset) / 16_000,
            end: Double(newOffset) / 16_000,
            track: isMic ? "mic" : "system",
            speaker: isMic ? "Você" : "Outros",
            cluster: nil,
            text: text
        )
        liveUtterances.append(utterance)
        let stamp = String(format: "[%02d:%02d]", Int(utterance.start) / 60, Int(utterance.start) % 60)
        liveLines.append("\(stamp) **\(utterance.speaker):** \(text)")
        if liveLines.count > 300 { liveLines.removeFirst(liveLines.count - 300) }
    }

    private func autoStop(reason: String) {
        guard isRecording else { return }
        Notifier.shared.notify(
            title: "Gravação encerrada",
            body: "\(reason). Gerando o resumo…"
        )
        stopRecording()
    }

    // MARK: - Detecção de reunião

    func acceptDetection(_ meeting: DetectedMeeting) {
        guard session == nil else { return }
        startRecording(title: meeting.title, source: meeting.source, viaBrowser: meeting.viaBrowser)
    }

    func dismissDetection() {
        guard let current = detected else { return }
        dismissedUntil[current.key] = Date().addingTimeInterval(30 * 60)
        detected = nil
        if session == nil { FloatingBubble.shared.hide() }
    }

    private func startMonitor() {
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await self?.tick()
            }
        }
    }

    private func tick() async {
        let settings = SeedSettings.load()
        if let session {
            // silêncio: alguém falou recentemente?
            if session.systemLevel > 0.06 || session.micLevel > 0.15 {
                lastAudibleAt = Date()
            }
            // auto-stop só para gravações iniciadas por detecção (e se habilitado)
            guard let source = recordingSource, settings.autoStop else { return }
            if recordingViaBrowser {
                let present = await Task.detached { MeetingDetector.browserTabPresent(for: source) }.value
                if present {
                    meetTabMisses = 0
                } else {
                    meetTabMisses += 1
                }
                if meetTabMisses >= 2 {
                    autoStop(reason: "A aba da reunião foi fechada")
                    return
                }
            }
            if Date().timeIntervalSince(lastAudibleAt) > silenceLimitSeconds {
                autoStop(reason: "Silêncio prolongado — a reunião parece ter terminado")
            }
        } else {
            guard settings.detectMeet || settings.detectTeams else {
                if detected != nil { detected = nil }
                return
            }
            let diag = await Task.detached {
                MeetingDetector.diagnose(meetEnabled: settings.detectMeet, teamsEnabled: settings.detectTeams)
            }.value
            // só loga quando o diagnóstico muda: uma linha a cada 5s para
            // sempre levou o .detector.log a 26 MB / 336 mil linhas
            let tickLine = "tick chrome=\(diag.chromeRunning) tab=\(diag.meetingTab ?? "-") issue=\(diag.tabIssue ?? "-") teams=\(diag.teamsAppRunning) mic=\(diag.micInUse) → \(diag.result?.title ?? "nada")"
            if tickLine != lastTickLine {
                lastTickLine = tickLine
                dlog(tickLine)
            }
            guard let detection = diag.result else {
                if detected != nil { detected = nil }
                FloatingBubble.shared.hide()
                // reunião acabou/sumiu: re-arma a notificação para a próxima
                if !notifiedKeys.isEmpty { notifiedKeys.removeAll() }
                return
            }
            if let until = dismissedUntil[detection.key], until > Date() { return }
            if detected != detection { detected = detection }
            FloatingBubble.shared.show() // bolha de gravação já na detecção
            if !notifiedKeys.contains(detection.key) {
                notifiedKeys.insert(detection.key)
                Notifier.shared.notifyDetected(detection)
                dlog("notificação enviada: \(detection.title) [\(detection.source.rawValue)]")
            }
        }
    }

    /// No launch, corta o .detector.log para a cauda recente se passou de 1 MB.
    private func rotateDetectorLog() {
        let url = store.rootURL.appendingPathComponent(".detector.log")
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
        guard size > 1_000_000, let handle = try? FileHandle(forReadingFrom: url) else { return }
        try? handle.seek(toOffset: UInt64(size - 200_000))
        var tail = (try? handle.readToEnd()) ?? Data()
        try? handle.close()
        if let newline = tail.firstIndex(of: 0x0A) { tail = tail.suffix(from: newline + 1) }
        try? tail.write(to: url, options: .atomic)
    }

    /// Caixa-preta do encerramento: em 07/10 e 08/10 o app saiu sozinho ~24s
    /// depois de começar a gravar (SIGTERM vindo do próprio processo, sem
    /// crash report) e nada no log dizia por quê. Agora fica registrado se a
    /// saída veio por sinal ou pelo AppKit, e a gravação fecha os arquivos.
    private func installTerminationLogging() {
        signal(SIGTERM, SIG_IGN)
        // fila de fundo: com a main travada o sinal ainda é atendido (e o log
        // diz se ela estava respondendo — a pista que faltou nas duas mortes)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global(qos: .userInitiated))
        source.setEventHandler { [weak self] in
            self?.dlog("encerramento: SIGTERM recebido")
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let state = AppState.shared
                    state.dlog("encerramento: main respondeu (gravando=\(state.isRecording)) — fechando")
                    state.session?.stop()
                    exit(0)
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                self?.dlog("encerramento: main thread NÃO respondeu em 3s — saindo assim mesmo")
                exit(0)
            }
        }
        source.resume()
        sigtermSource = source
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                let state = AppState.shared
                state.dlog("encerramento: willTerminate do AppKit (gravando=\(state.isRecording))\n"
                    + Thread.callStackSymbols.prefix(20).joined(separator: "\n"))
                state.session?.stop()
            }
        }
    }

    /// Log de diagnóstico da detecção (.detector.log na pasta de dados).
    nonisolated func dlog(_ message: String) {
        let url = store.rootURL.appendingPathComponent(".detector.log")
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        let line = "\(formatter.string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    // MARK: - Pipeline

    func process(_ meeting: Meeting) {
        processingStage[meeting.id] = "Na fila…"
        let store = self.store
        Task.detached(priority: .userInitiated) {
            let updated = await Pipeline.shared.process(meeting, store: store) { stage in
                Task { @MainActor in
                    AppState.shared.processingStage[meeting.id] = stage
                }
            }
            await MainActor.run {
                AppState.shared.processingStage[meeting.id] = nil
                AppState.shared.refresh()
                AppState.shared.speakersTick += 1
                if updated.status == .ready {
                    Notifier.shared.notify(title: "Resumo pronto 🌱", body: updated.title)
                }
            }
        }
    }

    /// Regenera só o resumo (após renomear falante ou editar notas) — sem re-transcrever.
    func resummarize(_ meeting: Meeting) {
        processingStage[meeting.id] = "Gerando resumo…"
        let store = self.store
        Task.detached(priority: .userInitiated) {
            let updated = await Pipeline.shared.resummarize(meeting, store: store) { stage in
                Task { @MainActor in
                    AppState.shared.processingStage[meeting.id] = stage
                }
            }
            _ = updated
            await MainActor.run {
                AppState.shared.processingStage[meeting.id] = nil
                AppState.shared.searchCacheInvalidate(meeting.id)
                AppState.shared.refresh()
            }
        }
    }

    func searchCacheInvalidate(_ id: String) {
        searchCache[id] = nil
        searchIndexing.remove(id)
    }

    // MARK: - Notas por voz

    /// Append atômico em notas.md + aviso para a view recarregar o editor.
    /// Seguro em relação ao TextEditor porque tudo roda no MainActor: no
    /// momento do append, o arquivo é idêntico ao estado do editor.
    func appendVoiceNote(_ line: String, to meeting: Meeting) {
        let current = store.readNotes(meeting) ?? ""
        store.writeNotes(current.isEmpty ? line : current + "\n" + line, for: meeting)
        notesTick += 1
    }

    /// Reunião-contêiner das notas avulsas de hoje (cria se não existir).
    /// Nasce .ready na hora — create() marca .recording, que o recoverOrphans
    /// trataria como gravação órfã no próximo launch.
    func strayNotesMeeting() -> Meeting? {
        if let existing = store.list().first(where: {
            $0.tags.contains("notas-avulsas") && Calendar.current.isDateInToday($0.startedAt)
        }) {
            return existing
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.dateFormat = "dd/MM"
        guard let created = try? store.create(title: "Notas avulsas — \(formatter.string(from: Date()))")
        else { return nil }
        let ready = store.update(created) {
            $0.status = .ready
            $0.tags = ["notas-avulsas"]
        }
        refresh()
        return ready
    }

    /// Pergunta sobre a reunião EM ANDAMENTO: snapshot do transcript ao vivo
    /// + notas tirado aqui (MainActor) antes do detached — o LLM responde
    /// "o que perdi?" pelos timestamps relativos ao momento atual.
    func askLive(_ question: String) {
        guard let session else { return }
        let meeting = session.meeting
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !chatBusy.contains(meeting.id) else { return }

        let transcript = TranscriptBuilder.dialogue(liveUtterances.sorted { $0.start < $1.start })
        let clock = Int(max(0, session.micClockSeconds))
        let nowStamp = String(format: "[%02d:%02d]", clock / 60, clock % 60)
        let notes = store.readNotes(meeting) ?? ""

        chatBusy.insert(meeting.id)
        Task.detached(priority: .userInitiated) {
            var failure: String?
            do {
                try MeetingChat.askLive(
                    trimmed, meeting: meeting,
                    liveTranscript: transcript, notes: notes, nowStamp: nowStamp
                )
            } catch {
                failure = "\(error)"
            }
            await MainActor.run {
                AppState.shared.chatBusy.remove(meeting.id)
                AppState.shared.chatTick += 1
                if let failure { AppState.shared.lastError = failure }
            }
        }
    }

    /// Pergunta algo sobre a reunião (chat) — roda no provider selecionado.
    func ask(_ question: String, about meeting: Meeting) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !chatBusy.contains(meeting.id) else { return }
        chatBusy.insert(meeting.id)
        let store = self.store
        Task.detached(priority: .userInitiated) {
            var failure: String?
            do {
                try MeetingChat.ask(trimmed, meeting: meeting, store: store)
            } catch {
                failure = "\(error)"
            }
            await MainActor.run {
                AppState.shared.chatBusy.remove(meeting.id)
                AppState.shared.chatTick += 1
                if let failure { AppState.shared.lastError = failure }
            }
        }
    }

    /// Troca o template do resumo e o refaz (sem re-transcrever).
    func setTemplate(_ template: SummaryTemplate, for meeting: Meeting) {
        let updated = store.update(meeting) { $0.template = template.rawValue }
        refresh()
        resummarize(updated)
    }

    /// Nomeia um falante: atualiza transcript + resumo por substituição local
    /// (sem LLM) e ensina a voz. Refazer o resumo é ação manual do usuário.
    func renameSpeaker(_ meeting: Meeting, cluster: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Speakers.rename(cluster: cluster, to: trimmed, meeting: meeting, voiceprints: store.voiceprints)
        searchCacheInvalidate(meeting.id)
        refresh()
    }

    /// Desfaz um nome confirmado errado: reverte o voiceprint e volta o
    /// falante para "Falante N". Tudo local.
    func unnameSpeaker(_ meeting: Meeting, cluster: String) {
        Speakers.unname(cluster: cluster, meeting: meeting, voiceprints: store.voiceprints)
        searchCacheInvalidate(meeting.id)
        refresh()
        speakersTick += 1
    }

    /// Mescla dois falantes (mesma pessoa dividida pela diarização) — tudo
    /// local, sem chamada de LLM.
    func mergeSpeakers(_ meeting: Meeting, cluster source: String, into target: String) {
        Speakers.merge(cluster: source, into: target, meeting: meeting, voiceprints: store.voiceprints)
        searchCacheInvalidate(meeting.id)
        refresh()
        speakersTick += 1
    }

    // MARK: - Tags e pastas

    func addTag(_ tag: String, to meeting: Meeting) {
        let cleaned = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleaned.isEmpty, !meeting.tags.contains(cleaned) else { return }
        store.update(meeting) { fresh in
            if !fresh.tags.contains(cleaned) { fresh.tags.append(cleaned) }
        }
        refresh()
    }

    func removeTag(_ tag: String, from meeting: Meeting) {
        store.update(meeting) { $0.tags.removeAll { $0 == tag } }
        refresh()
    }

    func setFolder(_ folder: String?, for meeting: Meeting) {
        store.update(meeting) { fresh in
            fresh.folder = folder?.trimmingCharacters(in: .whitespacesAndNewlines)
            if fresh.folder?.isEmpty == true { fresh.folder = nil }
        }
        refresh()
    }

    // MARK: - Edição

    func rename(_ meeting: Meeting, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != meeting.title else { return }
        store.update(meeting) { $0.title = trimmed }
        refresh()
    }

    func delete(_ meeting: Meeting) {
        store.delete(meeting)
        if selectedMeetingID == meeting.id { selectedMeetingID = nil }
        refresh()
    }
}
