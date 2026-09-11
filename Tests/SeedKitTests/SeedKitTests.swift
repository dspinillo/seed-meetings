import AVFoundation
import FluidAudio
import Foundation
import Testing

@testable import SeedKit

// MARK: - TranscriptBuilder

@Suite("TranscriptBuilder")
struct TranscriptBuilderTests {
    private func timing(_ token: String, _ start: Double, _ end: Double) -> TokenTiming {
        TokenTiming(token: token, tokenId: 0, startTime: start, endTime: end, confidence: 0.9)
    }

    @Test("agrupa tokens em falas e quebra em pausas > gap")
    func utterancesSplitOnGap() {
        let timings = [
            timing("▁olá", 0.0, 0.3),
            timing("▁mundo", 0.35, 0.7),
            // pausa de 2s → nova fala
            timing("▁tudo", 2.8, 3.0),
            timing("▁bem", 3.05, 3.3),
        ]
        let result = TranscriptBuilder.utterances(from: timings, track: "mic", speaker: "Você")
        #expect(result.count == 2)
        #expect(result[0].text == "olá mundo")
        #expect(result[1].text == "tudo bem")
        #expect(result[0].start == 0.0)
        #expect(result[1].speaker == "Você")
    }

    @Test("descarta falas só de pontuação (alucinação de ASR)")
    func utterancesDropPunctuationOnly() {
        let timings = [
            timing(".", 0.0, 0.1),
            // pausa → nova fala com conteúdo real
            timing("▁ok", 2.0, 2.2),
        ]
        let result = TranscriptBuilder.utterances(from: timings, track: "mic", speaker: "Você")
        #expect(result.count == 1)
        #expect(result[0].text == "ok")
    }

    @Test("cacos em inglês caem; português e inglês real ficam")
    func englishShards() {
        #expect(TranscriptBuilder.isEnglishShard("of the"))
        #expect(TranscriptBuilder.isEnglishShard("Well that you'll go"))
        #expect(TranscriptBuilder.isEnglishShard("things."))
        #expect(!TranscriptBuilder.isEnglishShard("Você tá tomando o quê?"))
        #expect(!TranscriptBuilder.isEnglishShard("vamos revisar o dashboard"))
        #expect(!TranscriptBuilder.isEnglishShard("the dashboard tá pronto"))
        #expect(!TranscriptBuilder.isEnglishShard("I think we should reconsider the entire quarterly plan"))
    }

    @Test("atribui falante por overlap com a diarização, usando labels")
    func assignSpeakersByOverlap() {
        let utterances = [
            Utterance(start: 0, end: 4, track: "system", speaker: "Falante 1", cluster: nil, text: "a"),
            Utterance(start: 10, end: 14, track: "system", speaker: "Falante 1", cluster: nil, text: "b"),
        ]
        let segments = [
            SpeakerSegment(speakerId: "1", start: 0, end: 5, embedding: []),
            SpeakerSegment(speakerId: "2", start: 9, end: 15, embedding: []),
        ]
        let labeled = TranscriptBuilder.assignSpeakers(utterances, segments: segments, labels: ["2": "Maria"])
        #expect(labeled[0].speaker == "Falante 1")
        #expect(labeled[0].cluster == "1")
        #expect(labeled[1].speaker == "Maria")
        #expect(labeled[1].cluster == "2")
    }

    @Test("render lista participantes e formata timestamps")
    func renderDocument() {
        let utterances = [
            Utterance(start: 0, end: 2, track: "mic", speaker: "Você", cluster: nil, text: "oi"),
            Utterance(start: 65, end: 70, track: "system", speaker: "Pessoa D", cluster: "1", text: "olá"),
        ]
        let doc = TranscriptBuilder.render(title: "Teste", utterances: utterances)
        #expect(doc.contains("# Teste"))
        #expect(doc.contains("Participantes: Você, Pessoa D"))
        #expect(doc.contains("[01:05] **Pessoa D:** olá"))
    }
}

// MARK: - Voiceprints

@Suite("VoiceprintStore")
struct VoiceprintTests {
    private func makeStore() -> VoiceprintStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("seed-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return VoiceprintStore(rootURL: dir)
    }

    @Test("cosseno: idênticos = 1, ortogonais = 0")
    func cosine() {
        #expect(abs(VoiceprintStore.cosine([1, 0, 1], [1, 0, 1]) - 1) < 0.0001)
        #expect(abs(VoiceprintStore.cosine([1, 0], [0, 1])) < 0.0001)
        #expect(VoiceprintStore.cosine([], []) == 0)
        #expect(VoiceprintStore.cosine([1], [1, 2]) == 0) // tamanhos diferentes
    }

    @Test("unlearn reverte o learn exatamente (média móvel reversível)")
    func unlearnReverses() {
        let store = makeStore()
        store.learn(name: "Pessoa A", embedding: [1, 0, 0])
        store.learn(name: "Pessoa A", embedding: [0.8, 0.2, 0])
        let before = store.all().first!

        // confirmação errada contamina…
        store.learn(name: "Pessoa A", embedding: [0, 1, 0])
        // …e o unlearn restaura o estado anterior
        store.unlearn(name: "Pessoa A", embedding: [0, 1, 0])
        let after = store.all().first!
        #expect(after.samples == before.samples)
        for (a, b) in zip(after.embedding, before.embedding) {
            #expect(abs(a - b) < 0.0001)
        }

        // única amostra → voiceprint some por completo
        store.learn(name: "Fantasma", embedding: [0, 0, 1])
        store.unlearn(name: "Fantasma", embedding: [0, 0, 1])
        #expect(!store.all().contains { $0.name == "Fantasma" })
    }

    @Test("learn cria, reforça com média móvel e matches respeita o limiar")
    func learnAndMatch() {
        let store = makeStore()
        store.learn(name: "Maria", embedding: [1, 0, 0])
        store.learn(name: "maria", embedding: [0.8, 0.2, 0]) // case-insensitive: reforça
        let prints = store.all()
        #expect(prints.count == 1)
        #expect(prints[0].samples == 2)

        let close = store.matches(for: [1, 0.05, 0])
        #expect(close.first?.name == "Maria")
        #expect((close.first?.score ?? 0) >= VoiceprintStore.autoThreshold)

        let far = store.matches(for: [0, 0, 1])
        #expect(far.isEmpty) // abaixo do limiar de sugestão
    }
}

// MARK: - Falantes fantasma (cleanClusters / assignSpeakers / merge)

@Suite("Speakers.cleanClusters")
struct CleanClustersTests {
    private func segment(_ id: String, _ start: Double, _ end: Double, _ embedding: [Float]) -> SpeakerSegment {
        SpeakerSegment(speakerId: id, start: start, end: end, embedding: embedding)
    }

    @Test("funde cluster gêmeo (cosseno ≥ 0,55) no dominante; distinto fica")
    func fusesTwins() {
        let segments = [
            segment("2", 0, 70, [1, 0, 0]),        // dominante
            segment("1", 80, 110, [0.9, 0.1, 0]),  // gêmeo (cos ≈ 0,99), 30s
            segment("3", 120, 150, [0, 1, 0]),     // pessoa distinta, 30s
        ]
        let cleaned = Speakers.cleanClusters(segments)
        let clusters = Set(cleaned.map(\.speakerId))
        #expect(clusters == ["2", "3"])
        #expect(Speakers.airtimes(cleaned)["2"] == 100)
    }

    @Test("descarta cluster de ruído (<20s ou <2%), nunca o dominante")
    func dropsNoise() {
        let segments = [
            segment("2", 0, 100, [1, 0, 0]),
            segment("3", 110, 115, [0, 1, 0]),   // 5s de ruído → cai
        ]
        let cleaned = Speakers.cleanClusters(segments)
        #expect(Set(cleaned.map(\.speakerId)) == ["2"])

        // reunião curtinha: o dominante fica mesmo abaixo dos mínimos
        let short = [segment("1", 0, 10, [1, 0, 0])]
        #expect(Speakers.cleanClusters(short).count == 1)
    }

    @Test("splitMixedClusters desmistura cluster que bate em 2 vozes conhecidas")
    func splitsMixedCluster() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("seed-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let voiceprints = VoiceprintStore(rootURL: dir)
        voiceprints.learn(name: "Pessoa A", embedding: [1, 0.2, 0])
        voiceprints.learn(name: "Pessoa B", embedding: [0.2, 1, 0])

        // cluster "1" misturado: 2 segmentos com cara de Pessoa A + 1 de Pessoa B
        let mixed = [
            segment("1", 0, 60, [0.95, 0.25, 0]),
            segment("1", 70, 130, [0.9, 0.3, 0]),
            segment("1", 140, 170, [0.25, 0.95, 0]),
        ]
        let split = Speakers.splitMixedClusters(mixed, voiceprints: voiceprints)
        let times = Speakers.airtimes(split)
        #expect(times.count == 2)
        #expect(times["1"] == 120)   // Pessoa A (dominante) herda o id
        #expect(times["2"] == 30)    // Pessoa B ganha id novo

        // e a fusão do cleanClusters NÃO pode re-colar vozes conhecidas distintas
        let cleaned = Speakers.cleanClusters(
            split, minSeconds: 5, minShare: 0.01, voiceprints: voiceprints)
        #expect(Set(cleaned.map(\.speakerId)) == ["1", "2"])
    }

    @Test("cluster que bate em só 1 voz conhecida não é dividido")
    func keepsSingleVoiceCluster() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("seed-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let voiceprints = VoiceprintStore(rootURL: dir)
        voiceprints.learn(name: "Pessoa A", embedding: [1, 0, 0])
        voiceprints.learn(name: "Flavio", embedding: [0, 0, 1])

        let pure = [
            segment("1", 0, 60, [0.95, 0.1, 0]),
            segment("1", 70, 130, [0.9, 0.15, 0]),
        ]
        let split = Speakers.splitMixedClusters(pure, voiceprints: voiceprints)
        #expect(Set(split.map(\.speakerId)) == ["1"])
    }

    @Test("fala sem overlap vai ao falante mais próximo no tempo, não ao rótulo genérico")
    func noOverlapNearest() {
        let utterances = [
            Utterance(start: 20, end: 24, track: "system", speaker: "Falante 1", cluster: nil, text: "solta"),
        ]
        let segments = [
            segment("1", 0, 5, []),
            segment("2", 9, 15, []),
        ]
        let labeled = TranscriptBuilder.assignSpeakers(utterances, segments: segments, labels: ["2": "Maria"])
        #expect(labeled[0].cluster == "2")   // distância 5 vs 15
        #expect(labeled[0].speaker == "Maria")
    }
}

@Suite("Speakers.merge")
struct MergeSpeakersTests {
    @Test("mescla: falas migram, transcript e resumo reescritos, voiceprint reforçado")
    func mergeClusters() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("seed-tests-\(UUID().uuidString)")
        let store = MeetingStore(rootURL: dir)
        let meeting = try store.create(title: "Meet")

        let speakers = [
            MeetingSpeaker(cluster: "4", label: "Pessoa B Exemplo", confirmed: true,
                           embedding: [1, 0], suggestions: []),
            MeetingSpeaker(cluster: "5", label: "Falante 5", confirmed: false,
                           embedding: [0.9, 0.1], suggestions: []),
        ]
        Speakers.save(speakers, for: meeting)
        let utterances = [
            Utterance(start: 0, end: 4, track: "system", speaker: "Pessoa B Exemplo", cluster: "4", text: "oi"),
            Utterance(start: 10, end: 14, track: "system", speaker: "Falante 5", cluster: "5", text: "sou eu de novo"),
        ]
        try JSONEncoder().encode(utterances)
            .write(to: meeting.folderURL.appendingPathComponent("segments.json"))
        try "Falante 5 pediu os dados a Pessoa B Exemplo."
            .write(to: meeting.summaryURL, atomically: true, encoding: .utf8)

        Speakers.merge(cluster: "5", into: "4", meeting: meeting, voiceprints: store.voiceprints)

        let remaining = Speakers.load(for: meeting)
        #expect(remaining.map(\.cluster) == ["4"])

        let migrated = try JSONDecoder().decode(
            [Utterance].self,
            from: Data(contentsOf: meeting.folderURL.appendingPathComponent("segments.json"))
        )
        #expect(migrated.allSatisfy { $0.cluster == "4" && $0.speaker == "Pessoa B Exemplo" })

        let transcript = try String(contentsOf: meeting.transcriptURL, encoding: .utf8)
        #expect(transcript.contains("**Pessoa B Exemplo:** sou eu de novo"))
        #expect(!transcript.contains("Falante 5"))

        let summary = try String(contentsOf: meeting.summaryURL, encoding: .utf8)
        #expect(summary == "Pessoa B Exemplo pediu os dados a Pessoa B Exemplo.")

        #expect(store.voiceprints.all().first?.name == "Pessoa B Exemplo")
    }
}

// MARK: - Speakers.confidenceNote

@Suite("Speakers.confidenceNote")
struct ConfidenceNoteTests {
    @Test("lista % de auto-identificados, confirmados como confirmados, e some quando não há nada")
    func note() {
        let auto = MeetingSpeaker(
            cluster: "1", label: "Pessoa D", confirmed: false, embedding: [],
            suggestions: [.init(name: "Pessoa D", score: 0.74)])
        let confirmed = MeetingSpeaker(
            cluster: "2", label: "Pessoa C", confirmed: true, embedding: [], suggestions: [])
        let anonymous = MeetingSpeaker(
            cluster: "3", label: "Falante 3", confirmed: false, embedding: [], suggestions: [])

        let note = Speakers.confidenceNote([auto, confirmed, anonymous])
        #expect(note != nil)
        #expect(note!.contains("Pessoa D: 74% de confiança"))
        #expect(note!.contains("Pessoa C: confirmado pelo usuário"))
        #expect(!note!.contains("Falante 3"))

        #expect(Speakers.confidenceNote([anonymous]) == nil)
    }
}

// MARK: - Speakers.relabel

@Suite("Speakers.relabel")
struct RelabelTests {
    @Test("troca placeholder com word boundary (Falante 1 ≠ Falante 15)")
    func simplePlaceholder() {
        let text = "Falante 1 concordou; Falante 15 discordou."
        let out = Speakers.relabel(text, from: "Falante 1", to: "Maria")
        #expect(out == "Maria concordou; Falante 15 discordou.")
    }

    @Test("colapsa 'Falante 5 (Pessoa B)' e 'Pessoa B (Falante 5)' sem duplicar")
    func parenthesized() {
        let text = "Você e Falante 5 (Pessoa B) reforçaram; Pessoa B (Falante 5) pediu dados; Falante 5 fecha."
        let out = Speakers.relabel(text, from: "Falante 5", to: "Pessoa B")
        #expect(out == "Você e Pessoa B reforçaram; Pessoa B pediu dados; Pessoa B fecha.")
    }

    @Test("case-insensitive e sem duplicar quando o texto já tem o nome novo")
    func confirmedRename() {
        let text = "Pessoa B Exemplo apresentou. pessoa b decidiu."
        let out = Speakers.relabel(text, from: "Pessoa B", to: "Pessoa B Exemplo")
        #expect(out == "Pessoa B Exemplo apresentou. Pessoa B Exemplo decidiu.")
    }

    @Test("rótulos iguais ou vazios não alteram o texto")
    func noOp() {
        #expect(Speakers.relabel("abc", from: "x", to: "x") == "abc")
        #expect(Speakers.relabel("abc", from: "", to: "y") == "abc")
    }
}

// MARK: - Glossary

@Suite("Glossary")
struct GlossaryTests {
    private let entries = [
        GlossaryEntry(certo: "Projeto Alfa", variantes: ["Alfa"], nota: "sistema"),
        GlossaryEntry(certo: "Pessoa Exemplo", variantes: ["Exempro", "Exenplo"], nota: "PESSOA = Pessoa Exemplo"),
        GlossaryEntry(certo: "Projeto Beta", variantes: ["ProjBeta", "Proj Beta"], nota: nil),
    ]

    @Test("apply troca variantes com word boundary, case-insensitive; não toca palavras contidas")
    func applyReplaces() {
        let text = "A alfa do Alfa ficou com Exempro; o exenplo não é alfante. Proj Beta e ProjBeta."
        let out = Glossary.apply(to: text, entries: entries)
        #expect(out == "A Projeto Alfa do Projeto Alfa ficou com Pessoa Exemplo; o Pessoa Exemplo não é alfante. Projeto Beta e Projeto Beta.")
    }

    @Test("apply não mexe em termos sem variante cadastrada")
    func applyOnlyRegistered() {
        let text = "O Jesta e o Exempl seguem como estão."
        #expect(Glossary.apply(to: text, entries: entries) == text)
    }

    @Test("promptBlock lista termos, variantes e instrução de não normalizar")
    func promptBlockContent() {
        let block = Glossary.promptBlock(entries)
        #expect(block.contains("Projeto Alfa"))
        #expect(block.contains("Exempro"))
        #expect(block.contains("Pessoa Exemplo"))
        #expect(block.contains("MANTENHA"))
        #expect(Glossary.promptBlock([]).isEmpty)
    }
}

// MARK: - MeetingStore

@Suite("MeetingStore")
struct MeetingStoreTests {
    @Test("roundtrip: create/save/read preserva tudo, inclusive campos novos")
    func roundtrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("seed-tests-\(UUID().uuidString)")
        let store = MeetingStore(rootURL: dir)
        var meeting = try store.create(title: "Weekly")
        meeting.tags = ["ba", "tech"]
        meeting.folder = "1:1"
        meeting.template = SummaryTemplate.umAUm.rawValue
        meeting.status = .ready
        meeting.refined = false
        meeting.durationSeconds = 123
        store.save(meeting)

        let loaded = store.read(folderURL: meeting.folderURL)
        #expect(loaded?.title == "Weekly")
        #expect(loaded?.tags == ["ba", "tech"])
        #expect(loaded?.folder == "1:1")
        #expect(loaded?.summaryTemplate == .umAUm)
        #expect(loaded?.refined == false)
        #expect(loaded?.status == .ready)
        #expect(store.list().count == 1)
    }

    @Test("update re-lê o meta do disco: save com cópia stale não clobbera refined")
    func updatePreservesConcurrentFields() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("seed-tests-\(UUID().uuidString)")
        let store = MeetingStore(rootURL: dir)
        var meeting = try store.create(title: "Reunião")
        meeting.status = .ready
        meeting.refined = false
        store.save(meeting)

        let staleCopy = store.read(folderURL: meeting.folderURL)! // a UI segura essa cópia

        // refino em 2º plano termina e marca refined=true
        store.update(meeting) { $0.refined = true }

        // ação da UI com a cópia antiga (renomear título) não pode reverter o refino
        let updated = store.update(staleCopy) { $0.title = "Novo título" }
        #expect(updated.refined == true)
        let onDisk = store.read(folderURL: meeting.folderURL)
        #expect(onDisk?.refined == true)
        #expect(onDisk?.title == "Novo título")
    }

    @Test("meta.json antigo (sem campos novos) continua decodando")
    func backwardCompatibleMeta() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("seed-tests-\(UUID().uuidString)")
        let folder = dir.appendingPathComponent("20260101-100000")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let oldMeta = """
        {"title":"Antiga","startedAt":"2026-01-01T10:00:00Z","durationSeconds":60,"status":"ready"}
        """
        try oldMeta.write(to: folder.appendingPathComponent("meta.json"), atomically: true, encoding: .utf8)
        let meeting = MeetingStore(rootURL: dir).read(folderURL: folder)
        #expect(meeting?.title == "Antiga")
        #expect(meeting?.tags == [])
        #expect(meeting?.folder == nil)
        #expect(meeting?.summaryTemplate == .trabalho)
    }
}

// MARK: - AsyncGate

@Suite("AsyncGate")
struct AsyncGateTests {
    final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var current = 0
        private(set) var maxSeen = 0

        func enter() -> Int {
            lock.lock()
            defer { lock.unlock() }
            current += 1
            maxSeen = max(maxSeen, current)
            return current
        }

        func exit() {
            lock.lock()
            current -= 1
            lock.unlock()
        }
    }

    @Test("nunca duas seções críticas simultâneas (DiarizerManager não é thread-safe)")
    func serializes() async {
        let gate = AsyncGate()
        let probe = Probe()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    await gate.acquire()
                    _ = probe.enter()
                    try? await Task.sleep(nanoseconds: 15_000_000)
                    probe.exit()
                    gate.release()
                }
            }
        }
        #expect(probe.maxSeen == 1)
    }
}

// MARK: - ConvertingWavSink

@Suite("ConvertingWavSink")
struct WavSinkTests {
    @Test("padSilence realinha a timeline após queda de captura")
    func padSilenceAdvancesTimeline() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("seed-tests-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let sink = try ConvertingWavSink(url: url)
        #expect(sink.seconds == 0)
        sink.padSilence(seconds: 2.0)
        #expect(abs(sink.seconds - 2.0) < 0.01)
        sink.close()

        let file = try AVAudioFile(forReading: url)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        #expect(abs(duration - 2.0) < 0.01)
    }
}

// MARK: - SeedSettings

@Suite("SeedSettings")
struct SettingsTests {
    @Test("config parcial (versões antigas) decoda com padrões")
    func partialDecode() throws {
        let json = #"{"provider":"antigravity"}"#.data(using: .utf8)!
        let settings = try JSONDecoder().decode(SeedSettings.self, from: json)
        #expect(settings.provider == .antigravity)
        #expect(settings.retentionDays == 30)
        #expect(settings.detectMeet == true)
        #expect(settings.refineProvider == "same")
        #expect(settings.claudeModel == "sonnet")
        #expect(settings.micDeviceUID == "default")
    }
}

// MARK: - AudioInputDevices

@Suite("AudioInputDevices")
struct AudioDevicesTests {
    @Test("lista mics sem crashar e UID inexistente resolve nil")
    func listAndResolve() {
        let devices = AudioInputDevices.list()
        // nesta máquina há pelo menos o mic embutido; UIDs são únicos
        #expect(Set(devices.map(\.uid)).count == devices.count)
        #expect(AudioInputDevices.deviceID(forUID: "seed-uid-inexistente") == nil)
        if let first = devices.first {
            #expect(AudioInputDevices.deviceID(forUID: first.uid) != nil)
        }
    }
}

// MARK: - MeetingDetector (limpeza de títulos)

@Suite("Títulos de abas")
struct TitleCleaningTests {
    @Test("Meet: tira prefixo e troca código de sala por nome genérico")
    func meetTitles() {
        #expect(MeetingDetector.cleanMeetTitle("Meet – Weekly BA") == "Weekly BA")
        #expect(MeetingDetector.cleanMeetTitle("abc-defg-hij") == "Reunião no Meet")
        #expect(MeetingDetector.cleanMeetTitle("") == "Reunião no Meet")
    }

    @Test("Teams: tira sufixo e contador de notificações")
    func teamsTitles() {
        #expect(MeetingDetector.cleanTeamsTitle("Daily | Microsoft Teams") == "Daily")
        #expect(MeetingDetector.cleanTeamsTitle("(2) Daily | Microsoft Teams") == "Daily")
        #expect(MeetingDetector.cleanTeamsTitle("Microsoft Teams") == "Reunião no Teams")
        #expect(MeetingDetector.cleanTeamsTitle("Chat | Microsoft Teams") == "Reunião no Teams")
    }
}

// MARK: - LiveSegmenter

@Suite("LiveSegmenter")
struct LiveSegmenterTests {
    @Test("corta na pausa, preservando a fala seguinte no tail")
    func splitsAtSilence() {
        var samples = [Float](repeating: 0.2, count: 16_000 * 3)      // 3s de fala
        samples += [Float](repeating: 0.0, count: 16_000)             // 1s de silêncio
        samples += [Float](repeating: 0.2, count: 16_000)             // 1s de fala nova
        let split = LiveSegmenter.splitAtPause(samples)
        #expect(split != nil)
        if let split {
            // o corte acontece dentro do silêncio: o head guarda a fala anterior
            #expect(split.head.count >= 16_000 * 3)
            #expect(split.head.count <= 16_000 * 4)
            #expect(split.tail.count >= 16_000)
        }
    }

    @Test("sem material suficiente, não corta")
    func waitsForMinimum() {
        let short = [Float](repeating: 0.2, count: 16_000)
        #expect(LiveSegmenter.splitAtPause(short) == nil)
    }

    @Test("sem pausa nenhuma, força o corte no máximo")
    func forcesAtMax() {
        let long = [Float](repeating: 0.2, count: 16_000 * 26)
        let split = LiveSegmenter.splitAtPause(long)
        #expect(split != nil)
        #expect(split?.tail.isEmpty == true)
    }
}
