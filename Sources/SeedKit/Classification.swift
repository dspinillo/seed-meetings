import Foundation

/// Classificação da reunião (`classificacao.json` na pasta dela), gerada pelo
/// motor de IA atual numa chamada pequena depois do resumo. Classifica a
/// reunião, não as pessoas, e só a partir do texto: tom de voz e ironia se
/// perdem — por isso as evidências.
public struct MeetingClassification: Codable, Equatable, Sendable {
    public enum Temperatura: String, Codable, CaseIterable, Sendable {
        case tranquila, neutra, tensa, conflituosa

        public var displayName: String { rawValue.capitalized }
    }

    public struct Evidencia: Codable, Equatable, Sendable {
        public var momento: String
        public var trecho: String
    }

    public var temperatura: Temperatura
    public var temperaturaMotivo: String
    public var evidencias: [Evidencia]
    public var ferramentas: [String]
    public var temas: [String]
    public var flags: [String]
    /// true quando o usuário corrigiu à mão: reclassificações automáticas
    /// (refino, refazer resumo) não sobrescrevem.
    public var editada: Bool?

    enum CodingKeys: String, CodingKey {
        case temperatura
        case temperaturaMotivo = "temperatura_motivo"
        case evidencias, ferramentas, temas, flags, editada
    }

    /// Lista fechada, para filtros e comparação entre reuniões.
    public static let allowedFlags = [
        "cliente_insatisfeito", "risco_de_prazo", "decisao_pendente", "escalonamento",
    ]

    public static func flagLabel(_ flag: String) -> String {
        switch flag {
        case "cliente_insatisfeito": return "Cliente insatisfeito"
        case "risco_de_prazo": return "Risco de prazo"
        case "decisao_pendente": return "Decisão pendente"
        case "escalonamento": return "Escalonamento"
        default: return flag
        }
    }
}

public enum Classifier {
    static func fileURL(for meeting: Meeting) -> URL {
        meeting.folderURL.appendingPathComponent("classificacao.json")
    }

    public static func load(for meeting: Meeting) -> MeetingClassification? {
        guard let data = try? Data(contentsOf: fileURL(for: meeting)) else { return nil }
        return try? JSONDecoder().decode(MeetingClassification.self, from: data)
    }

    public static func save(_ classification: MeetingClassification, for meeting: Meeting) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(classification) else { return }
        try? data.write(to: fileURL(for: meeting), options: .atomic)
    }

    static let prompt = """
    Você classifica reuniões para o Seed. Receberá o resumo e o transcript de UMA reunião. \
    Devolva SOMENTE um objeto JSON, sem texto antes ou depois e sem bloco de código, neste formato:
    {"temperatura": "tranquila | neutra | tensa | conflituosa", "temperatura_motivo": "uma frase", \
    "evidencias": [{"momento": "mm:ss", "trecho": "citação curta do transcript"}], \
    "ferramentas": ["..."], "temas": ["..."], "flags": ["..."]}

    Regras:
    - "temperatura": exatamente um dos quatro valores. Classifique o clima da reunião, não as pessoas. \
    Você só tem o texto: na dúvida entre dois valores, escolha o mais brando.
    - "evidencias": de 1 a 4 trechos literais do transcript, com o momento [mm:ss] em que aparecem, \
    que sustentam a temperatura e as flags. Sem evidência, não marque tensa, conflituosa nem flags.
    - "ferramentas": sistemas, produtos e ferramentas citados pelo nome (ex.: Zendesk, Databricks). \
    Lista vazia se não houver.
    - "temas": de 1 a 6 assuntos tratados, em poucas palavras cada.
    - "flags": zero ou mais entre \(MeetingClassification.allowedFlags.joined(separator: ", ")). \
    Não crie outras.
    """

    /// Classifica e grava. Se a resposta não decodificar, tenta mais uma vez,
    /// como o validador do resumo. Preserva correções manuais.
    @discardableResult
    public static func classify(
        _ meeting: Meeting,
        store: MeetingStore,
        provider: LLMProviderID? = nil,
        force: Bool = false
    ) throws -> MeetingClassification {
        if !force, let existing = load(for: meeting), existing.editada == true { return existing }
        guard let transcript = store.readTranscript(meeting) else {
            throw SeedError("a reunião ainda não tem transcript")
        }
        let input = """
        === RESUMO ===
        \(store.readSummary(meeting) ?? "(sem resumo)")

        === TRANSCRIPT ===
        \(transcript)
        """
        let fullPrompt = prompt + Glossary.promptBlock()
        var lastError: Error = SeedError("classificação vazia")
        for attempt in 0..<2 {
            let correction = attempt == 0 ? "" :
                "\n\nA resposta anterior não era um JSON válido no formato pedido. Devolva só o objeto JSON."
            do {
                let answer = try LLM.generate(prompt: fullPrompt + correction, input: input,
                                              provider: provider, fast: true)
                let classification = try parse(answer)
                save(classification, for: meeting)
                return classification
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// Extrai o objeto JSON da resposta (tolerando cerca de código ou texto em
    /// volta), decodifica com `Codable` e aplica as listas fechadas.
    static func parse(_ text: String) throws -> MeetingClassification {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
            throw SeedError("a classificação não veio em JSON")
        }
        var result = try JSONDecoder().decode(MeetingClassification.self, from: Data(text[start...end].utf8))
        result.editada = nil
        result.temperaturaMotivo = result.temperaturaMotivo.trimmingCharacters(in: .whitespacesAndNewlines)
        result.evidencias = result.evidencias
            .map { .init(momento: $0.momento.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")),
                         trecho: $0.trecho.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.trecho.isEmpty }
        result.flags = unique(result.flags.map { $0.lowercased() })
            .filter(MeetingClassification.allowedFlags.contains)
        result.ferramentas = unique(result.ferramentas)
        result.temas = unique(result.temas)
        // evidências são obrigatórias para qualquer afirmação forte
        if result.evidencias.isEmpty {
            result.flags = []
            if result.temperatura == .tensa || result.temperatura == .conflituosa {
                throw SeedError("classificação sem evidências para a temperatura \(result.temperatura.rawValue)")
            }
        }
        return result
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
}

extension MeetingClassification {
    /// Só a temperatura é exigida; listas ausentes viram vazias (os motores
    /// costumam omitir chaves sem conteúdo).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        temperatura = try container.decode(Temperatura.self, forKey: .temperatura)
        temperaturaMotivo = (try? container.decode(String.self, forKey: .temperaturaMotivo)) ?? ""
        evidencias = (try? container.decode([Evidencia].self, forKey: .evidencias)) ?? []
        ferramentas = (try? container.decode([String].self, forKey: .ferramentas)) ?? []
        temas = (try? container.decode([String].self, forKey: .temas)) ?? []
        flags = (try? container.decode([String].self, forKey: .flags)) ?? []
        editada = try? container.decode(Bool.self, forKey: .editada)
    }
}
