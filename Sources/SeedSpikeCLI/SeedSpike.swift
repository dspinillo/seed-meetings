import AVFoundation
import Foundation
import SeedKit

/// Sinal de parada thread-safe: dispara por Ctrl+C ou Enter, resume quem espera.
final class StopSignal: @unchecked Sendable {
    private var continuation: CheckedContinuation<Void, Never>?
    private let lock = NSLock()
    private var fired = false

    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if fired {
                lock.unlock()
                c.resume()
                return
            }
            continuation = c
            lock.unlock()
        }
    }

    func fire() {
        lock.lock()
        let c = continuation
        continuation = nil
        let alreadyFired = fired
        fired = true
        lock.unlock()
        if !alreadyFired { c?.resume() }
    }
}

@main
struct SeedSpikeMain {
    static func main() async {
        do {
            try await run()
        } catch {
            fputs("\nerro: \(error)\n", stderr)
            exit(1)
        }
    }

    static func run() async throws {
        var args = Array(CommandLine.arguments.dropFirst())
        guard !args.isEmpty else {
            printUsage()
            exit(2)
        }
        let command = args.removeFirst()
        switch command {
        case "run":
            try await recordCommand(args, processAfter: true)
        case "record":
            try await recordCommand(args, processAfter: false)
        case "transcribe":
            try await transcribeCommand(args)
        case "summarize":
            try await summarizeCommand(args)
        case "reprocess":
            try await reprocessCommand(args)
        case "chat":
            try chatCommand(args)
        case "diarize":
            try await diarizeCommand(args)
        case "mictest":
            try await micTestCommand(args)
        case "subdivide":
            try await subdivideCommand(args)
        case "reassign":
            try reassignCommand(args)
        case "classify":
            try classifyCommand(args)
        case "topic":
            // seed-spike topic "Nome" ID1 ID2… [--ask "pergunta"]: cria o tópico se
            // não existir e imprime o resumo consolidado ou a resposta do chat
            let positional = args.filter { !$0.hasPrefix("--") && $0 != flagValue(args, "--ask") }
            guard let name = positional.first else { throw SeedError("informe o nome do tópico") }
            let store = MeetingStore()
            let topic = Topics.load().first { $0.name == name }
                ?? Topics.create(name: name, meetingIDs: Array(positional.dropFirst()))
            if let question = flagValue(args, "--ask") {
                print(try Topics.ask(question, topic: topic, store: store).last?.content ?? "")
            } else {
                print(try Topics.consolidate(topic, store: store))
            }
        case "index":
            let store = MeetingStore()
            for meeting in store.list() {
                let done = try SemanticIndex.index(meeting, store: store)
                print("\(meeting.id) \(done ? "indexada" : "sem alteração") — \(meeting.title)")
            }
        case "search":
            guard let query = args.first else { throw SeedError("informe a consulta") }
            let store = MeetingStore()
            let titles = Dictionary(uniqueKeysWithValues: store.list().map { ($0.id, $0.title) })
            for hit in try SemanticIndex.search(query, store: store, limit: 8, perMeeting: 2) {
                print(String(format: "%.3f  %@ %@ — %@", hit.score, hit.stamp, titles[hit.meetingID] ?? hit.meetingID,
                             String(hit.text.replacingOccurrences(of: "\n", with: " ").prefix(140))))
            }
        case "fdleak":
            // diagnóstico: descritores abertos depois de N ciclos de detecção
            func openFDs() -> Int { (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1 }
            let rounds = Int(args.first ?? "") ?? 20
            print("antes: \(openFDs()) descritores")
            for _ in 0..<rounds { _ = MeetingDetector.diagnose() }
            print("depois de \(rounds) ciclos: \(openFDs()) descritores")
        case "detect":
            let diag = MeetingDetector.diagnose()
            print("Chrome aberto: \(diag.chromeRunning)")
            print("Aba de reunião: \(diag.meetingTab ?? "nenhuma")")
            if let issue = diag.tabIssue { print("Problema: \(issue)") }
            print("Teams app: \(diag.teamsAppRunning)")
            print("Mic em uso: \(diag.micInUse)")
            print("Resultado: \(diag.result.map { "\($0.title) — \($0.source.rawValue)" } ?? "nada detectado")")
        default:
            printUsage()
            exit(2)
        }
    }

    static func printUsage() {
        fputs(
            """
            seed-spike — diagnóstico de captura, transcrição e resumo do Seed

            Uso:
              seed-spike run [--name "Nome da reunião"] [--out DIR]
                  Grava mic + áudio do sistema, transcreve, diariza e resume. Tudo em um.
              seed-spike record [--name "..."] [--out DIR]
                  Só grava as duas trilhas (mic.wav + sistema.wav).
              seed-spike transcribe ARQUIVO.wav [--diarize]
                  Transcreve um WAV existente (e opcionalmente diariza).
              seed-spike summarize TRANSCRIPT.md [--name "..."]
                  Gera o resumo com o motor selecionado nas Preferências.
              seed-spike diarize PASTA_DA_REUNIAO
                  Raio-X da diarização: clusters crus vs após cleanClusters, com
                  airtime, cossenos entre clusters e matches de voiceprint.

              seed-spike classify PASTA_DA_REUNIÃO
                  Classifica a reunião (temperatura, flags, ferramentas, temas) e grava classificacao.json.
              seed-spike topic "Nome" ID1 ID2… [--ask "pergunta"]
                  Cria o tópico (se não existir) e gera o resumo consolidado, ou pergunta ao chat do tópico.
              seed-spike index
                  Gera o índice semântico das reuniões prontas (exige a busca semântica ligada e o Ollama).
              seed-spike search "consulta"
                  Busca por sentido nos trechos indexados.

            Para parar a gravação: Enter ou Ctrl+C.

            """,
            stderr
        )
    }

    // MARK: - record / run

    static func recordCommand(_ args: [String], processAfter: Bool) async throws {
        let name = flagValue(args, "--name") ?? "Reunião sem nome"
        let outDir = try prepareOutputDir(flagValue(args, "--out"))

        guard await MicRecorder.requestPermission() else {
            throw SeedError(
                "permissão de microfone negada. Libere em Ajustes > Privacidade e Segurança > Microfone."
            )
        }

        let micSink = try ConvertingWavSink(url: outDir.appendingPathComponent("mic.wav"))
        let systemSink = try ConvertingWavSink(url: outDir.appendingPathComponent("sistema.wav"))
        let mic = MicRecorder(sink: micSink)
        let tap = TapRecorder(sink: systemSink)

        try tap.start()
        try mic.start()

        fputs("gravando \"\(name)\" em \(outDir.path)\n", stderr)
        fputs("entre na call (ou toque um vídeo) e fale normalmente. Enter ou Ctrl+C para parar.\n\n", stderr)

        let stop = StopSignal()

        signal(SIGINT, SIG_IGN)
        let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        sigintSource.setEventHandler { stop.fire() }
        sigintSource.resume()

        Thread {
            _ = readLine()
            stop.fire()
        }.start()

        let meterTask = Task.detached {
            let startedAt = Date()
            while !Task.isCancelled {
                let elapsed = Int(Date().timeIntervalSince(startedAt))
                let line = String(
                    format: "\rgravando %02d:%02d  |  você %@  |  outros %@   ",
                    elapsed / 60, elapsed % 60,
                    levelBar(micSink.lastRMS), levelBar(systemSink.lastRMS)
                )
                fputs(line, stderr)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }

        await stop.wait()
        meterTask.cancel()
        sigintSource.cancel()

        mic.stop()
        tap.stop()
        micSink.close()
        systemSink.close()

        fputs("\n\ngravação encerrada:\n", stderr)
        fputs(String(format: "  você   → %@ (%.0fs de áudio)\n", micSink.url.path, micSink.seconds), stderr)
        fputs(String(format: "  outros → %@ (%.0fs de áudio)\n", systemSink.url.path, systemSink.seconds), stderr)

        if systemSink.seconds < 1 {
            fputs(
                "\naviso: a trilha do sistema ficou vazia — a permissão de 'Gravação de áudio do sistema' "
                    + "pode ter sido negada, ou nada estava tocando. Confira em Ajustes > Privacidade e Segurança.\n",
                stderr
            )
        }

        guard processAfter else { return }
        try await process(outDir: outDir, name: name)
    }

    static func process(outDir: URL, name: String) async throws {
        let micURL = outDir.appendingPathComponent("mic.wav")
        let systemURL = outDir.appendingPathComponent("sistema.wav")

        let asr = SpikeASR()
        try await asr.load()

        fputs("[asr] transcrevendo a sua trilha (mic)...\n", stderr)
        let started = Date()
        let micText = try await asr.transcribe(micURL)
        fputs("[asr] transcrevendo a trilha dos outros (sistema)...\n", stderr)
        let systemText = try await asr.transcribe(systemURL)
        let asrSeconds = Date().timeIntervalSince(started)
        fputs(String(format: "[asr] transcrição concluída em %.1fs\n", asrSeconds), stderr)

        var timeline = "(diarização indisponível)"
        do {
            let diarizer = SpikeDiarizer()
            try await diarizer.load()
            fputs("[diarizacao] separando vozes na trilha do sistema...\n", stderr)
            let segments = try diarizer.diarize(systemURL)
            timeline = formatTimeline(segments)
        } catch {
            fputs("[diarizacao] falhou (não bloqueia o teste): \(error)\n", stderr)
        }

        let transcript = """
        # \(name)

        ## Trilha VOCÊ (microfone)

        \(micText.isEmpty ? "(vazio)" : micText)

        ## Trilha OUTROS (áudio do sistema)

        \(systemText.isEmpty ? "(vazio)" : systemText)

        ## Linha do tempo de vozes na trilha OUTROS (diarização)

        \(timeline)
        """

        let transcriptURL = outDir.appendingPathComponent("transcript.md")
        try transcript.write(to: transcriptURL, atomically: true, encoding: .utf8)
        fputs("transcript salvo em \(transcriptURL.path)\n", stderr)

        fputs("[resumo] gerando resumo via claude -p (assinatura Max)...\n", stderr)
        let summary = try Summarizer.summarize(transcript: transcript, meetingName: name)
        let summaryURL = outDir.appendingPathComponent("resumo.md")
        try summary.write(to: summaryURL, atomically: true, encoding: .utf8)
        fputs("resumo salvo em \(summaryURL.path)\n\n", stderr)

        print(summary)
    }

    // MARK: - transcribe

    static func transcribeCommand(_ args: [String]) async throws {
        guard let path = args.first(where: { !$0.hasPrefix("--") }) else {
            throw SeedError("informe o caminho de um arquivo .wav")
        }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SeedError("arquivo não encontrado: \(url.path)")
        }

        let asr = SpikeASR()
        try await asr.load()
        let started = Date()
        let text = try await asr.transcribe(url)
        fputs(String(format: "[asr] concluído em %.1fs\n\n", Date().timeIntervalSince(started)), stderr)
        print(text)

        if args.contains("--diarize") {
            let diarizer = SpikeDiarizer()
            try await diarizer.load()
            let segments = try diarizer.diarize(url)
            print("\n--- diarização ---")
            print(formatTimeline(segments))
        }
    }

    // MARK: - summarize

    static func summarizeCommand(_ args: [String]) async throws {
        guard let path = args.first(where: { !$0.hasPrefix("--") }) else {
            throw SeedError("informe o caminho do transcript")
        }
        let name = flagValue(args, "--name") ?? "Reunião"
        let transcript = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
        let summary = try Summarizer.summarize(transcript: transcript, meetingName: name)
        print(summary)
    }

    // MARK: - subdivide (bancada do bloco 12: quebrar cluster gigante)

    static func subdivideCommand(_ args: [String]) async throws {
        guard let folder = args.first(where: { !$0.hasPrefix("--") }) else {
            throw SeedError("uso: seed-spike subdivide PASTA [--anchor 0.55] [--join 0.60] [--merge 0.65] [--minsub 20]")
        }
        let folderURL = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath)
        let store = MeetingStore()
        guard let meeting = store.read(folderURL: folderURL) else {
            throw SeedError("meta.json não encontrado em \(folder)")
        }
        let anchor = Float(flagValue(args, "--anchor") ?? "0.55") ?? 0.55
        let join = Float(flagValue(args, "--join") ?? "0.60") ?? 0.60
        let merge = Float(flagValue(args, "--merge") ?? "0.65") ?? 0.65
        let minSub = Double(flagValue(args, "--minsub") ?? "20") ?? 20

        // cache da diarização crua: itera parâmetros sem re-diarizar 75min
        let cacheURL = folderURL.appendingPathComponent(".raw-diar.json")
        var raw: [SpeakerSegment] = []
        if let data = try? Data(contentsOf: cacheURL),
           let cached = try? JSONDecoder().decode([SpeakerSegment].self, from: data) {
            raw = cached
            fputs("[cache] diarização crua carregada (\(raw.count) segmentos)\n", stderr)
        } else {
            let diarizer = SpikeDiarizer()
            try await diarizer.load()
            raw = try diarizer.diarize(meeting.systemURL)
            try? JSONEncoder().encode(raw).write(to: cacheURL)
            fputs("[cache] diarização crua salva em \(cacheURL.lastPathComponent)\n", stderr)
        }

        let times = Speakers.airtimes(raw)
        guard let target = times.max(by: { $0.value < $1.value })?.key else {
            throw SeedError("nenhum cluster encontrado")
        }
        print("alvo: cluster \(target) (\(String(format: "%.1f", times[target]! / 60))min) · anchor=\(anchor) join=\(join) merge=\(merge) minsub=\(Int(minSub))s")

        let bins = Speakers.subdivideCluster(
            target, segments: raw, voiceprints: store.voiceprints.all(),
            anchorThreshold: anchor, joinThreshold: join,
            mergeThreshold: merge, minSubSeconds: minSub
        )

        let utterances = (try? JSONDecoder().decode(
            [Utterance].self,
            from: Data(contentsOf: folderURL.appendingPathComponent("segments.json"))
        )) ?? []

        func quote(for segment: SpeakerSegment) -> String {
            let match = utterances
                .filter { $0.track == "system" }
                .max { a, b in
                    let oa = min(a.end, segment.end) - max(a.start, segment.start)
                    let ob = min(b.end, segment.end) - max(b.start, segment.start)
                    return oa < ob
                }
            guard let match, min(match.end, segment.end) - max(match.start, segment.start) > 0.3 else {
                return "(sem fala mapeada)"
            }
            return String(match.text.prefix(110))
        }

        for bin in bins {
            let centroid = Speakers.weightedCentroid(bin.segments)
            let matches = store.voiceprints.matches(for: centroid)
                .map { "\($0.name) \(String(format: "%.2f", $0.score))" }
                .joined(separator: ", ")
            print("\n== \(bin.id): \(String(format: "%.1f", bin.airtime / 60))min · \(bin.segments.count) segs · matches: \(matches.isEmpty ? "—" : matches)")
            let sorted = bin.segments.sorted { $0.start < $1.start }
            for index in [sorted.count / 6, sorted.count / 2, sorted.count * 5 / 6] where sorted.indices.contains(index) {
                let segment = sorted[index]
                print(String(format: "   [%02d:%02d] %@", Int(segment.start) / 60, Int(segment.start) % 60, quote(for: segment)))
            }
        }
    }

    // MARK: - reassign (reconstrói falantes do cache da diarização — desfaz mescla)

    static func reassignCommand(_ args: [String]) throws {
        guard let folder = args.first(where: { !$0.hasPrefix("--") }) else {
            throw SeedError("uso: seed-spike reassign PASTA (requer .raw-diar.json na pasta)")
        }
        let folderURL = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath)
        let store = MeetingStore()
        guard let meeting = store.read(folderURL: folderURL) else {
            throw SeedError("meta.json não encontrado em \(folder)")
        }
        let cacheURL = folderURL.appendingPathComponent(".raw-diar.json")
        guard let data = try? Data(contentsOf: cacheURL),
              let raw = try? JSONDecoder().decode([SpeakerSegment].self, from: data)
        else {
            throw SeedError("cache .raw-diar.json ausente — rode seed-spike subdivide antes")
        }

        let refined = Speakers.refineClusters(raw, voiceprints: store.voiceprints)
        let segments = Speakers.cleanClusters(
            refined.segments, voiceprints: store.voiceprints, protected: refined.protected)

        let speakers = Speakers.build(segments: segments, voiceprints: store.voiceprints)
        Speakers.save(speakers, for: meeting)
        let labels = Dictionary(uniqueKeysWithValues: speakers.map { ($0.cluster, $0.label) })

        let utterancesURL = folderURL.appendingPathComponent("segments.json")
        let utterances = try JSONDecoder().decode([Utterance].self, from: Data(contentsOf: utterancesURL))
        let mic = utterances.filter { $0.track == "mic" }
        let system = TranscriptBuilder.assignSpeakers(
            utterances.filter { $0.track == "system" }, segments: segments, labels: labels)
        let merged = TranscriptBuilder.merge(mic, system)
        try JSONEncoder().encode(merged).write(to: utterancesURL)
        let transcript = TranscriptBuilder.render(title: meeting.title, utterances: merged)
        try transcript.write(to: meeting.transcriptURL, atomically: true, encoding: .utf8)

        print("falantes reconstruídos:")
        for speaker in speakers {
            let falas = merged.filter { $0.cluster == speaker.cluster }.count
            let sug = speaker.suggestions.first.map { " (\($0.name) \(String(format: "%.2f", $0.score)))" } ?? ""
            print("  cluster \(speaker.cluster): \(speaker.label)\(sug) · \(falas) falas")
        }
    }

    // MARK: - mictest (debug da captura de mic com dispositivo fixo)

    static func micTestCommand(_ args: [String]) async throws {
        print("dispositivos de entrada:")
        for device in AudioInputDevices.list() {
            print("  \(device.name) — \(device.uid)")
        }
        let preferred = args.first ?? SeedSettings.load().micDeviceUID
        print("\ntestando com micDeviceUID = \(preferred)\n")

        let engine = AVAudioEngine()
        let input = engine.inputNode
        print("formato ANTES do bind: \(input.outputFormat(forBus: 0))")

        if preferred != "default", var deviceID = AudioInputDevices.deviceID(forUID: preferred) {
            guard let unit = input.audioUnit else {
                print("input.audioUnit == nil — bind impossível")
                return
            }
            let status = AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0, &deviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size))
            print("bind status: \(status)")
        }
        let format = input.outputFormat(forBus: 0)
        print("formato APÓS o bind:  \(format)")

        var buffers = 0
        var maxRMS: Float = 0
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            buffers += 1
            if let data = buffer.floatChannelData?[0] {
                var acc: Float = 0
                for i in 0..<Int(buffer.frameLength) { acc += data[i] * data[i] }
                maxRMS = max(maxRMS, (acc / Float(max(buffer.frameLength, 1))).squareRoot())
            }
        }
        try engine.start()
        print("engine.isRunning: \(engine.isRunning) — capturando 4s…")
        try await Task.sleep(nanoseconds: 4_000_000_000)
        engine.stop()
        print("RESULTADO: \(buffers) buffers · RMS máx \(maxRMS)")
    }

    // MARK: - diarize (raio-X da diarização, p/ debug de falantes)

    static func diarizeCommand(_ args: [String]) async throws {
        guard let folder = args.first else {
            throw SeedError("uso: seed-spike diarize PASTA_DA_REUNIAO")
        }
        let folderURL = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath)
        let store = MeetingStore()
        guard let meeting = store.read(folderURL: folderURL) else {
            throw SeedError("meta.json não encontrado em \(folder)")
        }
        guard FileManager.default.fileExists(atPath: meeting.systemURL.path) else {
            throw SeedError("áudio do sistema não existe mais (retenção): \(meeting.systemURL.path)")
        }

        let diarizer = SpikeDiarizer()
        try await diarizer.load()
        let raw = try diarizer.diarize(meeting.systemURL)

        func report(_ label: String, _ segments: [SpeakerSegment]) {
            let times = Speakers.airtimes(segments)
            let embeddings = Speakers.clusterEmbeddings(from: segments)
            print("\n=== \(label): \(times.count) cluster(s) ===")
            for cluster in times.keys.sorted(by: { (times[$0] ?? 0) > (times[$1] ?? 0) }) {
                let seconds = times[cluster] ?? 0
                let count = segments.filter { $0.speakerId == cluster }.count
                let matches = store.voiceprints.matches(for: embeddings[cluster] ?? [])
                    .map { "\($0.name) \(String(format: "%.2f", $0.score))" }
                    .joined(separator: ", ")
                print(String(
                    format: "  cluster %@: %.1f min · %d segmentos · vozes conhecidas: %@",
                    cluster, seconds / 60, count, matches.isEmpty ? "—" : matches
                ))
            }
            let clusters = embeddings.keys.sorted()
            for i in 0..<clusters.count {
                for j in (i + 1)..<clusters.count {
                    let score = VoiceprintStore.cosine(
                        embeddings[clusters[i]] ?? [], embeddings[clusters[j]] ?? [])
                    print(String(format: "  cosseno %@ × %@: %.3f", clusters[i], clusters[j], score))
                }
            }
        }

        report("DIARIZAÇÃO CRUA", raw)
        let split = Speakers.splitMixedClusters(raw, voiceprints: store.voiceprints)
        report("APÓS splitMixedClusters (desmistura por voiceprint)", split)
        report(
            "APÓS cleanClusters (fusão + filtro)",
            Speakers.cleanClusters(split, voiceprints: store.voiceprints)
        )
    }

    // MARK: - chat (pergunta sobre uma reunião existente, p/ debug)

    static func chatCommand(_ args: [String]) throws {
        let positional = args.filter { !$0.hasPrefix("--") }
        guard positional.count >= 2 else {
            throw SeedError("uso: seed-spike chat <pasta-da-reunião> \"pergunta\"")
        }
        let folder = URL(fileURLWithPath: (positional[0] as NSString).expandingTildeInPath)
        let store = MeetingStore(rootURL: folder.deletingLastPathComponent())
        guard let meeting = store.read(folderURL: folder) else {
            throw SeedError("meta.json não encontrado em \(folder.path)")
        }
        // --stream mostra no stderr o tamanho da resposta parcial a cada pedaço
        var onPartial: (@Sendable (String) -> Void)?
        if args.contains("--stream") {
            onPartial = { text in fputs("[stream] \(text.count) caracteres\n", stderr) }
        }
        let history = try MeetingChat.ask(positional[1], meeting: meeting, store: store, onPartial: onPartial)
        if let answer = history.last, answer.role == "assistant" {
            print(answer.content)
        }
    }

    // MARK: - classify (classificação de uma pasta de reunião existente)

    static func classifyCommand(_ args: [String]) throws {
        guard let path = args.first(where: { !$0.hasPrefix("--") }) else {
            throw SeedError("informe a pasta da reunião")
        }
        let folder = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let store = MeetingStore(rootURL: folder.deletingLastPathComponent())
        guard let meeting = store.read(folderURL: folder) else {
            throw SeedError("meta.json não encontrado em \(folder.path)")
        }
        let result = try Classifier.classify(meeting, store: store, force: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: try encoder.encode(result), as: UTF8.self))
    }

    // MARK: - reprocess (roda o pipeline do app numa pasta de reunião existente)

    static func reprocessCommand(_ args: [String]) async throws {
        guard let path = args.first(where: { !$0.hasPrefix("--") }) else {
            throw SeedError("informe a pasta da reunião (ex.: ~/Library/Application Support/Seed/20260706-185205)")
        }
        let folder = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let store = MeetingStore(rootURL: folder.deletingLastPathComponent())
        guard let meeting = store.read(folderURL: folder) else {
            throw SeedError("meta.json não encontrado em \(folder.path)")
        }
        let updated = await Pipeline.shared.process(meeting, store: store) { stage in
            fputs("[pipeline] \(stage)\n", stderr)
        }
        guard updated.status == .ready else {
            throw SeedError(updated.errorMessage ?? "falha no processamento")
        }
        print(try String(contentsOf: updated.summaryURL, encoding: .utf8))
    }

    // MARK: - helpers

    static func flagValue(_ args: [String], _ flag: String) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    static func prepareOutputDir(_ override: String?) throws -> URL {
        let base: URL
        if let override {
            base = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd-HHmm"
            base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents/seed-flow/gravacoes")
                .appendingPathComponent(formatter.string(from: Date()))
        }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
}

func levelBar(_ rms: Float, width: Int = 8) -> String {
    // escala em dB calibrada para voz: piso -52 dB (ruído ambiente) até -20 dB (alto)
    let db = 20 * log10(max(rms, 0.000_01))
    let level = max(0, min(width, Int((db + 52) / 32 * Float(width))))
    return String(repeating: "█", count: level) + String(repeating: "·", count: width - level)
}
