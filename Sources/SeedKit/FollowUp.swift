import Foundation

/// Follow-ups: rascunho de mensagem pós-reunião e consolidação dos action
/// items do usuário — ambos via provider de LLM selecionado.
public enum FollowUp {
    /// Rascunho de mensagem de Slack para os participantes (salvo em followup.md).
    public static func generate(for meeting: Meeting, store: MeetingStore) throws -> String {
        guard let summary = store.readSummary(meeting) else {
            throw SeedError("a reunião ainda não tem resumo")
        }
        let speakers = Speakers.load(for: meeting)
        let names = speakers.map(\.label).filter { !$0.hasPrefix("Falante") }
        let recipients = names.isEmpty ? "o(s) participante(s)" : names.joined(separator: " e ")

        let prompt = """
        Escreva um rascunho de mensagem de Slack, em português brasileiro, do usuário para \
        \(recipients), como follow-up da reunião "\(meeting.title)". Base: o resumo abaixo. \
        Estrutura: 1 linha de contexto/agradecimento; bloco "Fico com:" (action items do \
        usuário, como bullets curtos); bloco "Com você:" (action items da outra pessoa); \
        1 linha de fechamento. Tom direto e cordial, sem formalidade excessiva, sem markdown \
        pesado (só bullets com "-"), pronto para colar no Slack. Não invente itens que não \
        estão no resumo.
        """ + Glossary.promptBlock()
        let message = try LLM.generate(prompt: prompt, input: summary)
        try? message.write(
            to: meeting.folderURL.appendingPathComponent("followup.md"),
            atomically: true,
            encoding: .utf8
        )
        return message
    }

    /// Consolida os action items do usuário das reuniões dos últimos `days` dias.
    public static func myActionItems(store: MeetingStore, days: Int = 7) throws -> String {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let ready = store.list().filter { $0.status == .ready && $0.startedAt >= cutoff }
        guard !ready.isEmpty else {
            return "Nenhuma reunião com resumo nos últimos \(days) dias."
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.dateFormat = "EEE, d MMM"

        var input = ""
        for meeting in ready {
            guard let summary = store.readSummary(meeting) else { continue }
            input += "=== \(meeting.title) (\(formatter.string(from: meeting.startedAt))) ===\n\(summary)\n\n"
        }

        let prompt = """
        Dos resumos de reuniões abaixo, extraia APENAS os action items que são do usuário \
        (aparecem como "Você" ou "Meus action items"). Consolide numa checklist \
        markdown: agrupe por reunião (### Título · data), cada item como "- [ ] ...". \
        Deduplique itens repetidos entre reuniões (cite as duas reuniões no item único). \
        Inclua prazos quando citados. No final, uma seção "### Sugestão de prioridade" com \
        os 3 itens mais urgentes e o porquê em uma linha cada. Não invente itens.
        """
        return try LLM.generate(prompt: prompt, input: input)
    }
}
