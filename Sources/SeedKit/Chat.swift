import Foundation

/// Uma mensagem do chat de uma reunião (persistida em chat.json na pasta dela).
public struct ChatMessage: Codable, Identifiable, Sendable {
    public let id: UUID
    public let role: String   // "user" | "assistant"
    public let content: String
    public let date: Date

    public init(role: String, content: String) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.date = Date()
    }
}

/// Chat com a reunião: responde perguntas fundamentado no resumo, nas notas e
/// no transcript, usando o provider de LLM selecionado.
public enum MeetingChat {
    static func chatURL(for meeting: Meeting) -> URL {
        meeting.folderURL.appendingPathComponent("chat.json")
    }

    public static func history(for meeting: Meeting) -> [ChatMessage] {
        guard let data = try? Data(contentsOf: chatURL(for: meeting)),
              let messages = try? JSONDecoder().decode([ChatMessage].self, from: data)
        else { return [] }
        return messages
    }

    static func save(_ messages: [ChatMessage], for meeting: Meeting) {
        guard let data = try? JSONEncoder().encode(messages) else { return }
        try? data.write(to: chatURL(for: meeting), options: .atomic)
    }

    public static func clear(for meeting: Meeting) {
        try? FileManager.default.removeItem(at: chatURL(for: meeting))
    }

    /// Pergunta e resposta; persiste o par no histórico apenas em caso de sucesso.
    @discardableResult
    public static func ask(
        _ question: String,
        meeting: Meeting,
        store: MeetingStore,
        provider: LLMProviderID? = nil,
        onPartial: (@Sendable (String) -> Void)? = nil
    ) throws -> [ChatMessage] {
        let summary = store.readSummary(meeting) ?? "(sem resumo)"
        let notes = store.readNotes(meeting) ?? ""
        let transcript = store.readTranscript(meeting) ?? "(sem transcript)"

        var history = history(for: meeting)
        let conversation = history.suffix(12)
            .map { "\($0.role == "user" ? "Você" : "Seed"): \($0.content)" }
            .joined(separator: "\n\n")

        let prompt = """
        Você é o assistente do Seed respondendo perguntas sobre a reunião "\(meeting.title)". \
        Responda em português brasileiro, direto e curto, fundamentado APENAS no material \
        (resumo, notas e transcript). Cite o momento ([mm:ss]) quando ajudar. Se a resposta \
        não estiver no material, diga isso claramente — não invente. A pergunta atual está \
        no final do material.
        """ + Glossary.promptBlock()

        let input = """
        === RESUMO ===
        \(summary)

        === NOTAS DO USUÁRIO ===
        \(notes.isEmpty ? "(sem notas)" : notes)

        === TRANSCRIPT ===
        \(transcript)

        === CONVERSA ATÉ AGORA ===
        \(conversation.isEmpty ? "(primeira pergunta)" : conversation)

        === PERGUNTA ATUAL ===
        \(question)
        """

        let answer = try LLM.generate(prompt: prompt, input: input, provider: provider, onPartial: onPartial)
        history.append(ChatMessage(role: "user", content: question))
        history.append(ChatMessage(role: "assistant", content: answer))
        save(history, for: meeting)
        return history
    }

    /// Chat DURANTE a gravação: o contexto é o transcript ao vivo (parcial)
    /// + as notas — resumo ainda não existe. Persiste no mesmo chat.json,
    /// então a conversa continua depois que a reunião acaba.
    @discardableResult
    public static func askLive(
        _ question: String,
        meeting: Meeting,
        liveTranscript: String,
        notes: String,
        nowStamp: String,
        provider: LLMProviderID? = nil,
        onPartial: (@Sendable (String) -> Void)? = nil
    ) throws -> [ChatMessage] {
        let liveTranscript = recentWindow(of: liveTranscript, question: question, nowStamp: nowStamp)
        var history = history(for: meeting)
        let conversation = history.suffix(12)
            .map { "\($0.role == "user" ? "Você" : "Seed"): \($0.content)" }
            .joined(separator: "\n\n")

        let prompt = """
        Você é o assistente do Seed. A reunião "\(meeting.title)" está EM ANDAMENTO — \
        sendo gravada agora; o momento atual é \(nowStamp). O transcript abaixo é parcial \
        e gerado ao vivo (pode conter pequenos erros e cortes). Responda em português \
        brasileiro, direto e curto, fundamentado APENAS no material (notas e transcript). \
        Perguntas como "o que perdi nos últimos 5 minutos" devem ser respondidas pelos \
        timestamps [mm:ss] relativos ao momento atual \(nowStamp). Cite o momento ([mm:ss]) \
        quando ajudar. Se a resposta não estiver no material, diga isso claramente — não \
        invente. A pergunta atual está no final do material.
        """ + Glossary.promptBlock()

        let input = """
        === NOTAS DO USUÁRIO ===
        \(notes.isEmpty ? "(sem notas)" : notes)

        === TRANSCRIPT AO VIVO (parcial, até \(nowStamp)) ===
        \(liveTranscript.isEmpty ? "(a transcrição ao vivo ainda não produziu falas)" : liveTranscript)

        === CONVERSA ATÉ AGORA ===
        \(conversation.isEmpty ? "(primeira pergunta)" : conversation)

        === PERGUNTA ATUAL ===
        \(question)
        """

        // chat ao vivo pede resposta em segundos: modelo rápido + streaming
        let answer = try LLM.generate(prompt: prompt, input: input, provider: provider,
                                      fast: true, onPartial: onPartial)
        history.append(ChatMessage(role: "user", content: question))
        history.append(ChatMessage(role: "assistant", content: answer))
        save(history, for: meeting)
        return history
    }

    /// Para perguntas sobre tempo ("o que perdi nos últimos 5 min?"), envia só
    /// a janela recente do transcript (com 1 min de folga), recortada pelos
    /// `[mm:ss]`. Outras perguntas recebem o transcript inteiro.
    static func recentWindow(of transcript: String, question: String, nowStamp: String) -> String {
        guard let match = question.range(
            of: #"[uú]ltim[oa]s?\s+(\d{1,3})\s*(min|minuto)"#, options: [.regularExpression, .caseInsensitive]),
              let minutes = Double(question[match].filter(\.isNumber)), minutes > 0,
              let now = seconds(fromStamp: nowStamp) else { return transcript }
        let cutoff = now - (minutes + 1) * 60
        guard cutoff > 0 else { return transcript }
        let kept = transcript.components(separatedBy: "\n\n").filter { block in
            guard let stamp = seconds(fromStamp: block) else { return true }
            return stamp >= cutoff
        }
        return kept.isEmpty ? transcript : kept.joined(separator: "\n\n")
    }

    /// Lê o `[mm:ss]` (ou `[hh:mm:ss]`) no início do texto.
    static func seconds(fromStamp text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") else { return nil }
        let parts = trimmed[trimmed.index(after: trimmed.startIndex)..<close].split(separator: ":").map { Double($0) }
        guard (2...3).contains(parts.count), !parts.contains(where: { $0 == nil }) else { return nil }
        return parts.reduce(0) { $0 * 60 + ($1 ?? 0) }
    }
}
