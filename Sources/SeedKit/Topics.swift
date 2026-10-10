import Foundation

/// Um tópico liga reuniões de títulos diferentes sobre o mesmo assunto
/// ("Planejamento Q4", "Churn"). Diferente da pasta (`Meeting.folder`): cada
/// reunião fica em uma pasta só, mas pode pertencer a vários tópicos.
public struct Topic: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var description: String
    public var meetingIDs: [String]
    public var createdAt: Date
    /// Resumo consolidado + linha do tempo, gerado sob demanda.
    public var summary: String?
    public var summaryAt: Date?
    /// Reuniões sugeridas pelo índice semântico que o usuário recusou.
    public var dismissed: [String]?

    public init(name: String, description: String = "") {
        self.id = UUID().uuidString
        self.name = name
        self.description = description
        self.meetingIDs = []
        self.createdAt = Date()
    }
}

/// Persistência (`topicos.json` na raiz de dados) e geração sobre tópicos.
public enum Topics {
    public static var fileURL: URL { SeedPaths.dataDirectory.appendingPathComponent("topicos.json") }
    static var chatURL: URL { SeedPaths.dataDirectory.appendingPathComponent(".topicos-chat.json") }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public static func load() -> [Topic] {
        guard let data = try? Data(contentsOf: fileURL),
              let topics = try? decoder.decode([Topic].self, from: data)
        else { return [] }
        return topics
    }

    public static func save(_ topics: [Topic]) {
        guard let data = try? encoder.encode(topics) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Read-modify-write de um tópico; devolve a lista atualizada.
    @discardableResult
    public static func update(_ id: String, _ mutate: (inout Topic) -> Void) -> [Topic] {
        var topics = load()
        guard let index = topics.firstIndex(where: { $0.id == id }) else { return topics }
        mutate(&topics[index])
        save(topics)
        return topics
    }

    @discardableResult
    public static func create(name: String, description: String = "", meetingIDs: [String] = []) -> Topic {
        var topic = Topic(name: name, description: description)
        topic.meetingIDs = meetingIDs
        save(load() + [topic])
        return topic
    }

    public static func delete(_ id: String) {
        save(load().filter { $0.id != id })
        var chats = loadChats()
        chats[id] = nil
        saveChats(chats)
    }

    public static func link(_ meetingID: String, to topicID: String) {
        update(topicID) { topic in
            if !topic.meetingIDs.contains(meetingID) { topic.meetingIDs.append(meetingID) }
            topic.dismissed?.removeAll { $0 == meetingID }
        }
    }

    public static func unlink(_ meetingID: String, from topicID: String) {
        update(topicID) { $0.meetingIDs.removeAll { $0 == meetingID } }
    }

    /// Reuniões do tópico que ainda existem, da mais antiga para a mais nova.
    public static func meetings(of topic: Topic, in all: [Meeting]) -> [Meeting] {
        let ids = Set(topic.meetingIDs)
        return all.filter { ids.contains($0.id) }.sorted { $0.startedAt < $1.startedAt }
    }

    // MARK: - Material enviado ao motor de IA

    /// Resumos e notas das reuniões em ordem cronológica. A primeira versão
    /// dispensa embeddings: os resumos de 4 a 10 reuniões cabem no contexto.
    static func material(for topic: Topic, store: MeetingStore) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.dateFormat = "d 'de' MMMM 'de' yyyy"
        let meetings = meetings(of: topic, in: store.list())
        guard !meetings.isEmpty else { return "(o tópico ainda não tem reuniões)" }
        return meetings.map { meeting in
            let summary = store.readSummary(meeting) ?? "(sem resumo)"
            let notes = (store.readNotes(meeting) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var block = "=== \(meeting.title) · \(formatter.string(from: meeting.startedAt)) ===\n\(summary)"
            if !notes.isEmpty { block += "\n\n--- Notas do usuário ---\n\(notes)" }
            return block
        }.joined(separator: "\n\n")
    }

    // MARK: - Resumo consolidado e linha do tempo

    public static func consolidate(_ topic: Topic, store: MeetingStore) throws -> String {
        guard !meetings(of: topic, in: store.list()).isEmpty else {
            throw SeedError("vincule ao menos uma reunião ao tópico antes de gerar o resumo")
        }
        let prompt = """
        Você é o assistente do Seed. O material abaixo reúne, em ordem cronológica, os resumos \
        e as notas das reuniões do tópico "\(topic.name)"\
        \(topic.description.isEmpty ? "" : " (\(topic.description))"). Escreva em português \
        brasileiro, em markdown, com estas seções: ## Onde estamos (2-4 frases com o estado \
        atual do assunto), ## Linha do tempo (um bloco por reunião, na ordem, com a data e o \
        título em negrito e, em bullets, as decisões e as pendências daquela reunião), \
        ## Resolvido (pendências de reuniões anteriores que uma reunião posterior fechou, \
        citando as duas), ## Em aberto (o que segue pendente, com responsável quando houver), \
        ## Mudanças de rumo (decisões revistas ou contraditas entre reuniões; omita a seção \
        se não houver). Seja fiel ao material; não invente nem deduza o que não está escrito.
        """ + Glossary.promptBlock()
        let text = try LLM.generate(prompt: prompt, input: material(for: topic, store: store))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        update(topic.id) {
            $0.summary = text
            $0.summaryAt = Date()
        }
        return text
    }

    // MARK: - Chat do tópico

    static func loadChats() -> [String: [ChatMessage]] {
        guard let data = try? Data(contentsOf: chatURL),
              let chats = try? JSONDecoder().decode([String: [ChatMessage]].self, from: data)
        else { return [:] }
        return chats
    }

    static func saveChats(_ chats: [String: [ChatMessage]]) {
        guard let data = try? JSONEncoder().encode(chats) else { return }
        try? data.write(to: chatURL, options: .atomic)
    }

    public static func history(for topicID: String) -> [ChatMessage] {
        loadChats()[topicID] ?? []
    }

    public static func clearHistory(for topicID: String) {
        var chats = loadChats()
        chats[topicID] = nil
        saveChats(chats)
    }

    /// Pergunta sobre o tópico; persiste o par só em caso de sucesso. Com o
    /// índice semântico ativo, acrescenta os trechos de transcript mais
    /// próximos da pergunta — os resumos sozinhos perdem detalhe.
    @discardableResult
    public static func ask(
        _ question: String,
        topic: Topic,
        store: MeetingStore,
        onPartial: (@Sendable (String) -> Void)? = nil
    ) throws -> [ChatMessage] {
        var history = history(for: topic.id)
        let conversation = history.suffix(12)
            .map { "\($0.role == "user" ? "Você" : "Seed"): \($0.content)" }
            .joined(separator: "\n\n")

        let prompt = """
        Você é o assistente do Seed respondendo perguntas sobre o tópico "\(topic.name)", que \
        reúne várias reuniões sobre o mesmo assunto. Responda em português brasileiro, direto \
        e curto, fundamentado APENAS no material (resumos, notas e trechos de transcript). \
        Diga de qual reunião (título e data) vem cada informação. Se a resposta não estiver no \
        material, diga isso claramente — não invente. A pergunta atual está no final do material.
        """ + Glossary.promptBlock()

        var input = material(for: topic, store: store)
        let excerpts = SemanticIndex.excerpts(for: question, meetingIDs: topic.meetingIDs, store: store, limit: 8)
        if !excerpts.isEmpty {
            input += "\n\n=== TRECHOS DE TRANSCRIPT MAIS PRÓXIMOS DA PERGUNTA ===\n" + excerpts
        }
        input += """


        === CONVERSA ATÉ AGORA ===
        \(conversation.isEmpty ? "(primeira pergunta)" : conversation)

        === PERGUNTA ATUAL ===
        \(question)
        """

        let answer = try LLM.generate(prompt: prompt, input: input, onPartial: onPartial)
        history.append(ChatMessage(role: "user", content: question))
        history.append(ChatMessage(role: "assistant", content: answer))
        var chats = loadChats()
        chats[topic.id] = history
        saveChats(chats)
        return history
    }
}
