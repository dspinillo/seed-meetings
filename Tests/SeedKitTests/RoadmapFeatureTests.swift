import Foundation
import Testing
@testable import SeedKit

@Suite("Classificação da reunião")
struct ClassificationTests {
    @Test("aceita JSON com cerca de código e aplica as listas fechadas")
    func parseTolerant() throws {
        let answer = """
        Aqui está:
        ```json
        {"temperatura": "tensa", "temperatura_motivo": " Discordância sobre prazo ",
         "evidencias": [{"momento": "[12:40]", "trecho": "não dá pra entregar"}, {"momento": "13:00", "trecho": " "}],
         "ferramentas": ["Zendesk", "zendesk", " "], "temas": ["CSAT"],
         "flags": ["RISCO_DE_PRAZO", "inventada"]}
        ```
        """
        let result = try Classifier.parse(answer)
        #expect(result.temperatura == .tensa)
        #expect(result.temperaturaMotivo == "Discordância sobre prazo")
        #expect(result.evidencias == [.init(momento: "12:40", trecho: "não dá pra entregar")])
        #expect(result.ferramentas == ["Zendesk"])
        #expect(result.flags == ["risco_de_prazo"])
    }

    @Test("chaves ausentes viram listas vazias; temperatura é obrigatória e fechada")
    func parseStrict() throws {
        #expect(try Classifier.parse(#"{"temperatura": "neutra"}"#).temas.isEmpty)
        for answer in ["sem json", #"{"temas": []}"#, #"{"temperatura": "furiosa"}"#] {
            #expect(throws: (any Error).self) { try Classifier.parse(answer) }
        }
    }

    @Test("sem evidências não há temperatura forte nem flags")
    func evidenceRequired() throws {
        #expect(throws: (any Error).self) { try Classifier.parse(#"{"temperatura": "conflituosa"}"#) }
        let calm = try Classifier.parse(#"{"temperatura": "tranquila", "flags": ["escalonamento"]}"#)
        #expect(calm.flags.isEmpty)
    }
}

@Suite("Índice semântico")
struct SemanticIndexTests {
    @Test("corta para as dimensões do índice e normaliza")
    func reduce() throws {
        let vector = try SemanticIndex.reduce([Float](repeating: 2, count: 768))
        #expect(vector.count == SemanticIndex.dims)
        #expect(abs(SemanticIndex.dot(vector, vector) - 1) < 1e-4)
        #expect(SemanticIndex.decode(SemanticIndex.encode(vector)) == vector)
    }

    @Test("rejeita NaN, infinito e norma nula em vez de gravar vetor estragado")
    func invalidVectors() {
        var nan = [Float](repeating: 1, count: 768)
        nan[3] = .nan
        for vector in [nan, [Float](repeating: 0, count: 768), [.infinity, 1], []] {
            #expect(throws: (any Error).self) { try SemanticIndex.reduce(vector) }
        }
    }

    @Test("prompts de tarefa só para a família EmbeddingGemma")
    func prompts() {
        #expect(SemanticIndex.prepared("prazo", query: true, title: nil, model: "embeddinggemma-2:270m")
            == "task: search result | query: prazo")
        #expect(SemanticIndex.prepared("fala", query: false, title: "Comitê", model: "embeddinggemma-2:270m")
            == "title: Comitê | text: fala")
        #expect(SemanticIndex.prepared("fala", query: false, title: nil, model: "nomic-embed-text") == "fala")
    }

    @Test("trechos de 30 a 60 s a partir do transcript em markdown")
    func chunking() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("seed-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(rootURL: root)
        let meeting = try store.create(title: "Teste")
        let lines = stride(from: 0, to: 200, by: 10).map {
            String(format: "[%02d:%02d] **Você:** fala %d", $0 / 60, $0 % 60, $0)
        }
        try ("# Teste\n\nParticipantes: Você\n\n" + lines.joined(separator: "\n\n"))
            .write(to: meeting.transcriptURL, atomically: true, encoding: .utf8)
        let chunks = SemanticIndex.chunks(for: meeting, store: store)
        #expect(chunks.map(\.start) == [0, 60, 120, 180])
        #expect(chunks[0].text.hasPrefix("[00:00] Você: fala 0"))
        #expect(chunks.allSatisfy { $0.text.contains("[") })
    }
}

@Suite("Chat ao vivo e streaming")
struct LiveChatTests {
    private let transcript = (0..<10).map { String(format: "[%02d:00] **Outros:** minuto %d", $0, $0) }
        .joined(separator: "\n\n")

    @Test("pergunta sobre os últimos minutos envia só a janela recente")
    func recentWindow() {
        let window = MeetingChat.recentWindow(of: transcript, question: "o que perdi nos últimos 3 min?", nowStamp: "[09:30]")
        #expect(window.hasPrefix("[06:00]"))
        #expect(!window.contains("[05:00]"))
    }

    @Test("outras perguntas e janelas maiores que a reunião mantêm o transcript inteiro")
    func fullTranscript() {
        #expect(MeetingChat.recentWindow(of: transcript, question: "já decidiram o prazo?", nowStamp: "[09:30]") == transcript)
        #expect(MeetingChat.recentWindow(of: transcript, question: "resuma os últimos 30 minutos", nowStamp: "[09:30]") == transcript)
    }

    @Test("stream-json do Claude: deltas viram texto parcial e o result fecha")
    func claudeStream() {
        let stream = ClaudeStream()
        #expect(!stream.consume(#"{"type":"system","subtype":"init"}"#))
        #expect(stream.consume(#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Olá"}}}"#))
        #expect(stream.consume(#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":", mundo"}}}"#))
        #expect(!stream.consume(#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"x"}}}"#))
        #expect(stream.text == "Olá, mundo")
        #expect(stream.result == nil)
        #expect(!stream.consume(#"{"type":"result","is_error":false,"result":"Olá, mundo."}"#))
        #expect(stream.result == "Olá, mundo.")
    }

    @Test("erro no result do Claude não vira resposta")
    func claudeStreamError() {
        let stream = ClaudeStream()
        _ = stream.consume(#"{"type":"result","is_error":true,"result":"limite atingido"}"#)
        #expect(stream.result == nil)
        #expect(stream.failure?.contains("limite atingido") == true)
    }
}

@Suite("Tópicos")
struct TopicTests {
    @Test("reuniões do tópico em ordem cronológica, ignorando as apagadas")
    func ordering() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("seed-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(rootURL: root)
        var first = try store.create(title: "Primeira")
        first.startedAt = Date(timeIntervalSince1970: 1_000)
        store.save(first)
        // create() usa o segundo atual como id: garante pastas distintas
        try FileManager.default.createDirectory(at: root.appendingPathComponent("20990101-000000"), withIntermediateDirectories: true)
        var second = try #require(store.read(folderURL: first.folderURL))
        second = Meeting(id: "20990101-000000", title: "Segunda", startedAt: Date(timeIntervalSince1970: 500),
                         durationSeconds: 0, status: .ready, errorMessage: nil, template: nil, tags: [], folder: nil,
                         refined: nil, folderURL: root.appendingPathComponent("20990101-000000"))
        store.save(second)

        var topic = Topic(name: "Churn")
        topic.meetingIDs = [first.id, "apagada", second.id]
        #expect(Topics.meetings(of: topic, in: store.list()).map(\.title) == ["Segunda", "Primeira"])
    }

    @Test("topicos.json antigo, sem os campos novos, continua decodificando")
    func decoding() throws {
        let json = #"[{"id":"T1","name":"Q4","description":"","meetingIDs":["a"],"createdAt":"2026-10-01T10:00:00Z"}]"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let topics = try decoder.decode([Topic].self, from: Data(json.utf8))
        #expect(topics.first?.summary == nil)
        #expect(topics.first?.meetingIDs == ["a"])
    }
}
