import Foundation

/// Índice semântico local (`indice.json` na pasta de cada reunião): trechos do
/// transcript com embeddings gerados pelo Ollama (`/api/embed`). Camada nova de
/// busca e recuperação — não substitui o Parakeet, o motor de resumo nem a
/// memória de vozes. Opcional: só funciona com a preferência ligada, o servidor
/// do Ollama rodando e o modelo baixado.
public enum SemanticIndex {
    public struct Chunk: Codable, Sendable {
        public let start: Double
        public let text: String
        let vector: String  // Float32 little-endian em base64
    }

    struct File: Codable {
        let model: String
        let dims: Int
        let transcriptModified: Double
        let chunks: [Chunk]
    }

    public struct Hit: Sendable {
        public let meetingID: String
        public let score: Float
        public let start: Double
        public let text: String

        public var stamp: String { String(format: "[%02d:%02d]", Int(start) / 60, Int(start) % 60) }
    }

    /// Matryoshka: o vetor de 768 é cortado e renormalizado. Com 256 dimensões
    /// o índice ocupa cerca de 1,4 KB por trecho.
    static let dims = 256
    /// Trechos de 30 a 60 s de fala.
    static let chunkTargetSeconds = 45.0
    static let chunkMaxSeconds = 60.0
    /// Similaridade mínima de um trecho para contar como achado. Os scores do
    /// EmbeddingGemma 2 (270m, 256 dims) ficam comprimidos: numa amostra de 152
    /// trechos de reuniões reais em português, consultas sem relação chegaram a
    /// 0,61–0,66 (uma a 0,71) e consultas relacionadas ficaram em 0,70–0,79.
    /// Calibração preliminar: rever com mais reuniões ou ao trocar de modelo.
    public static let searchThreshold: Float = 0.70
    /// Similaridade mínima entre o vetor médio da reunião e o do tópico. Vetores
    /// médios são ainda mais próximos entre si (0,89–0,92 entre reuniões do
    /// mesmo gênero e assuntos diferentes; 0,98 no mesmo assunto). Também
    /// preliminar — por isso a sugestão nunca vincula sozinha.
    public static let suggestionThreshold: Float = 0.93

    public static var enabled: Bool { SeedSettings.load().semanticSearch }

    static func fileURL(for meeting: Meeting) -> URL {
        meeting.folderURL.appendingPathComponent("indice.json")
    }

    // MARK: - Embeddings

    /// Prompts de tarefa da família EmbeddingGemma: consulta e documento são
    /// codificados de formas diferentes.
    static func prepared(_ text: String, query: Bool, title: String?, model: String) -> String {
        guard model.lowercased().contains("embeddinggemma") else { return text }
        return query ? "task: search result | query: \(text)" : "title: \(title ?? "none") | text: \(text)"
    }

    static func embed(_ texts: [String], query: Bool, title: String? = nil) throws -> [[Float]] {
        let model = SeedSettings.load().embeddingModel
        var request = URLRequest(url: URL(string: "http://localhost:11434/api/embed")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "input": texts.map { prepared($0, query: query, title: title, model: model) },
        ])
        let (data, _) = try LLM.syncRequest(request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SeedError("resposta inválida do Ollama (embeddings)")
        }
        if let error = json["error"] as? String {
            throw SeedError("Ollama: \(error) — rode 'ollama pull \(model)'")
        }
        guard let raw = json["embeddings"] as? [[NSNumber]], raw.count == texts.count else {
            throw SeedError("o Ollama não devolveu os embeddings esperados")
        }
        return try raw.map { try reduce($0.map(\.floatValue)) }
    }

    /// Corta para `dims`, valida e normaliza. Vetor com NaN/infinito ou norma
    /// nula é erro: gravá-lo estragaria a busca em silêncio.
    static func reduce(_ vector: [Float]) throws -> [Float] {
        let cut = Array(vector.prefix(dims))
        let norm = cut.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        guard cut.count == min(dims, vector.count), !cut.isEmpty,
              cut.allSatisfy(\.isFinite), norm.isFinite, norm > 1e-6 else {
            throw SeedError("embedding inválido (NaN, infinito ou norma nula)")
        }
        return cut.map { $0 / norm }
    }

    static func encode(_ vector: [Float]) -> String {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }.base64EncodedString()
    }

    static func decode(_ base64: String) -> [Float] {
        guard let data = Data(base64Encoded: base64) else { return [] }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var sum: Float = 0
        for index in a.indices { sum += a[index] * b[index] }
        return sum
    }

    // MARK: - Trechos

    /// Agrupa as falas em janelas de ~45 s (teto de 60 s), cada linha com
    /// `[mm:ss]` e o falante. Sem `segments.json`, lê o transcript em markdown.
    static func chunks(for meeting: Meeting, store: MeetingStore) -> [(start: Double, text: String)] {
        var lines: [(start: Double, text: String)] = []
        if let data = try? Data(contentsOf: meeting.folderURL.appendingPathComponent("segments.json")),
           let utterances = try? JSONDecoder().decode([Utterance].self, from: data), !utterances.isEmpty {
            lines = utterances.sorted { $0.start < $1.start }.map { utterance in
                (utterance.start, String(format: "[%02d:%02d] %@: %@", Int(utterance.start) / 60,
                                         Int(utterance.start) % 60, utterance.speaker, utterance.text))
            }
        } else if let transcript = store.readTranscript(meeting) {
            lines = transcriptLines(transcript)
        }
        var result: [(start: Double, text: String)] = []
        var current: [String] = []
        var windowStart = 0.0
        for line in lines {
            if current.isEmpty { windowStart = line.start }
            let elapsed = line.start - windowStart
            if !current.isEmpty, elapsed >= chunkMaxSeconds {
                result.append((windowStart, current.joined(separator: "\n")))
                current = []
                windowStart = line.start
            }
            current.append(line.text)
            if line.start - windowStart >= chunkTargetSeconds {
                result.append((windowStart, current.joined(separator: "\n")))
                current = []
            }
        }
        if !current.isEmpty { result.append((windowStart, current.joined(separator: "\n"))) }
        return result
    }

    static func transcriptLines(_ transcript: String) -> [(start: Double, text: String)] {
        transcript.split(separator: "\n").compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
            let parts = line[line.index(after: line.startIndex)..<close].split(separator: ":").compactMap { Double($0) }
            guard parts.count == 2 || parts.count == 3 else { return nil }
            let seconds = parts.reduce(0) { $0 * 60 + $1 }
            return (seconds, line.replacingOccurrences(of: "**", with: ""))
        }
    }

    // MARK: - Indexação

    static func load(for meeting: Meeting) -> File? {
        guard let data = try? Data(contentsOf: fileURL(for: meeting)) else { return nil }
        return try? JSONDecoder().decode(File.self, from: data)
    }

    static func transcriptModified(_ meeting: Meeting) -> Double {
        let date = (try? FileManager.default.attributesOfItem(atPath: meeting.transcriptURL.path))?[.modificationDate] as? Date
        return (date?.timeIntervalSince1970 ?? 0).rounded()
    }

    /// O índice existe e corresponde ao modelo, às dimensões e ao transcript atuais?
    public static func isCurrent(_ meeting: Meeting) -> Bool {
        guard let file = load(for: meeting) else { return false }
        return file.model == SeedSettings.load().embeddingModel && file.dims == dims
            && file.transcriptModified == transcriptModified(meeting)
    }

    /// Indexa uma reunião pronta e refinada. Devolve false se não havia o que fazer.
    @discardableResult
    public static func index(_ meeting: Meeting, store: MeetingStore) throws -> Bool {
        guard meeting.status == .ready, meeting.refined != false, !isCurrent(meeting) else { return false }
        let pieces = chunks(for: meeting, store: store)
        guard !pieces.isEmpty else { return false }
        var chunks: [Chunk] = []
        for batchStart in stride(from: 0, to: pieces.count, by: 16) {
            let batch = Array(pieces[batchStart..<min(batchStart + 16, pieces.count)])
            let vectors = try embed(batch.map(\.text), query: false, title: meeting.title)
            for (piece, vector) in zip(batch, vectors) {
                chunks.append(Chunk(start: piece.start, text: piece.text, vector: encode(vector)))
            }
        }
        let file = File(model: SeedSettings.load().embeddingModel, dims: dims,
                        transcriptModified: transcriptModified(meeting), chunks: chunks)
        try JSONEncoder().encode(file).write(to: fileURL(for: meeting), options: .atomic)
        return true
    }

    /// Indexa o que estiver pendente, uma reunião por vez. `shouldStop` é
    /// consultado entre reuniões: nunca indexar durante uma gravação.
    @discardableResult
    public static func indexPending(store: MeetingStore, shouldStop: () -> Bool = { false }) -> Int {
        guard enabled, LLM.ollamaServerUp() else { return 0 }
        var indexed = 0
        for meeting in store.list() {
            if shouldStop() { break }
            do {
                if try index(meeting, store: store) { indexed += 1 }
            } catch {
                fputs("[indice] \(meeting.id): \(error)\n", stderr)
                break  // modelo ausente ou servidor caiu: não insistir nas demais
            }
        }
        return indexed
    }

    // MARK: - Busca

    /// Trechos mais próximos da consulta, no máximo `perMeeting` por reunião.
    public static func search(
        _ query: String,
        store: MeetingStore,
        meetingIDs: Set<String>? = nil,
        limit: Int = 20,
        perMeeting: Int = 3
    ) throws -> [Hit] {
        guard enabled else { throw SeedError("a busca semântica está desligada nas Preferências") }
        guard LLM.ollamaServerUp() else { throw SeedError("servidor do Ollama fora do ar") }
        let model = SeedSettings.load().embeddingModel
        guard let queryVector = try embed([query], query: true).first else { return [] }
        var hits: [Hit] = []
        for meeting in store.list() where meetingIDs?.contains(meeting.id) ?? true {
            guard let file = load(for: meeting), file.model == model, file.dims == dims else { continue }
            let scored = file.chunks
                .map { Hit(meetingID: meeting.id, score: dot(queryVector, decode($0.vector)), start: $0.start, text: $0.text) }
                .sorted { $0.score > $1.score }
            hits.append(contentsOf: scored.prefix(perMeeting))
        }
        return Array(hits.sorted { $0.score > $1.score }.prefix(limit))
    }

    /// Trechos formatados para entrar num prompt. Melhor esforço: devolve ""
    /// quando o índice está desligado, vazio ou o servidor não responde.
    static func excerpts(for question: String, meetingIDs: [String], store: MeetingStore, limit: Int) -> String {
        guard enabled,
              let hits = try? search(question, store: store, meetingIDs: Set(meetingIDs), limit: limit, perMeeting: 3)
        else { return "" }
        let titles = Dictionary(uniqueKeysWithValues: store.list().map { ($0.id, $0.title) })
        return hits.filter { $0.score >= searchThreshold }
            .map { "--- \(titles[$0.meetingID] ?? $0.meetingID) ---\n\($0.text)" }
            .joined(separator: "\n\n")
    }

    // MARK: - Sugestão de tópico

    /// Vetor médio (normalizado) dos trechos de uma reunião.
    static func centroid(of meeting: Meeting) -> [Float]? {
        guard let file = load(for: meeting), file.dims == dims, !file.chunks.isEmpty else { return nil }
        return mean(file.chunks.map { decode($0.vector) })
    }

    static func mean(_ vectors: [[Float]]) -> [Float]? {
        let valid = vectors.filter { $0.count == dims }
        guard !valid.isEmpty else { return nil }
        var sum = [Float](repeating: 0, count: dims)
        for vector in valid { for index in 0..<dims { sum[index] += vector[index] } }
        return try? reduce(sum)
    }

    /// Tópicos aos quais a reunião provavelmente pertence: proximidade entre o
    /// vetor médio dela e o das reuniões do tópico, com um pequeno bônus por
    /// ferramentas e temas em comum. A sugestão é sempre confirmada pelo usuário.
    public static func suggestedTopics(for meeting: Meeting, topics: [Topic], meetings: [Meeting]) -> [(topic: Topic, score: Float)] {
        guard enabled, let own = centroid(of: meeting) else { return [] }
        let ownTerms = terms(of: meeting)
        return topics.compactMap { topic -> (Topic, Float)? in
            guard !topic.meetingIDs.contains(meeting.id), !(topic.dismissed ?? []).contains(meeting.id) else { return nil }
            let members = Topics.meetings(of: topic, in: meetings)
            guard let topicVector = mean(members.compactMap(centroid(of:))) else { return nil }
            let shared = ownTerms.intersection(members.reduce(into: Set<String>()) { $0.formUnion(terms(of: $1)) })
            let score = dot(own, topicVector) + min(0.04, Float(shared.count) * 0.02)
            return score >= suggestionThreshold ? (topic, score) : nil
        }.sorted { $0.1 > $1.1 }
    }

    private static func terms(of meeting: Meeting) -> Set<String> {
        guard let classification = Classifier.load(for: meeting) else { return [] }
        return Set((classification.ferramentas + classification.temas).map { $0.lowercased() })
    }
}
