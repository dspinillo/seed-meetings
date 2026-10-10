import Foundation

/// Uma entrada do dicionário particular: a grafia certa, as variantes que o
/// ASR costuma ouvir e uma nota opcional (ex.: "nome de pessoa").
public struct GlossaryEntry: Codable, Identifiable, Sendable, Equatable {
    public var id: String { certo }
    public var certo: String
    public var variantes: [String]
    public var nota: String?

    public init(certo: String, variantes: [String] = [], nota: String? = nil) {
        self.certo = certo
        self.variantes = variantes
        self.nota = nota
    }
}

/// Dicionário particular (.glossario.json na pasta de dados): nomes de pessoas,
/// sistemas e termos que o ASR erra. Alimenta o prompt dos resumos/chat/follow-up
/// (camada A) e a correção determinística do transcript (camada C).
public enum Glossary {
    public static var fileURL: URL {
        SeedPaths.dataDirectory.appendingPathComponent(".glossario.json")
    }

    /// Uma instalação nova começa vazia. Nunca inclui termos de outra pessoa
    /// e não sobrescreve um arquivo existente que não pôde ser decodificado.
    public static func load(from url: URL = fileURL) -> [GlossaryEntry] {
        guard let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([GlossaryEntry].self, from: data)
        else { return [] }
        return entries
    }

    public static func save(_ entries: [GlossaryEntry]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Camada A: bloco injetado nos prompts (Summarizer/Chat/FollowUp).
    /// Vazio quando não há entradas.
    public static func promptBlock(_ entries: [GlossaryEntry]? = nil) -> String {
        let entries = entries ?? load()
        guard !entries.isEmpty else { return "" }
        let lines = entries.map { entry in
            var line = "- \(entry.certo)"
            if !entry.variantes.isEmpty {
                line += " (o ASR às vezes escreve: \(entry.variantes.joined(separator: ", ")))"
            }
            if let nota = entry.nota, !nota.isEmpty { line += " — \(nota)" }
            return line
        }
        return """


        GLOSSÁRIO DO USUÁRIO (grafias corretas de nomes, pessoas e sistemas):
        \(lines.joined(separator: "\n"))
        Use exatamente estas grafias. Corrija variações foneticamente próximas para a grafia \
        do glossário. Se um nome não bater com o material nem com o glossário, MANTENHA a \
        grafia do transcript e marque com (?) — nunca normalize para uma entidade que apenas \
        "pareça" familiar.
        """
    }

    /// Camada C aplicada às falas antes de gravar segments.json/transcript.md:
    /// devolve novas utterances com o texto corrigido (renames futuros
    /// reconstroem o transcript já corrigido).
    public static func apply(to utterances: [Utterance], entries: [GlossaryEntry]? = nil) -> [Utterance] {
        let entries = entries ?? load()
        guard !entries.isEmpty else { return utterances }
        return utterances.map { u in
            Utterance(
                start: u.start, end: u.end, track: u.track, speaker: u.speaker,
                cluster: u.cluster, text: apply(to: u.text, entries: entries)
            )
        }
    }

    /// Camada C: correção determinística variante→canônico em texto de
    /// transcript. Só variantes cadastradas, word boundary, case-insensitive.
    public static func apply(to text: String, entries: [GlossaryEntry]? = nil) -> String {
        let entries = entries ?? load()
        var result = text
        for entry in entries {
            let template = NSRegularExpression.escapedTemplate(for: entry.certo)
            for variant in entry.variantes
            where !variant.isEmpty && variant.lowercased() != entry.certo.lowercased() {
                let pattern = "\\b" + NSRegularExpression.escapedPattern(for: variant) + "\\b"
                guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
                else { continue }
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: template
                )
            }
        }
        return result
    }
}
