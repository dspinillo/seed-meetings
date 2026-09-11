import Foundation

/// Uma reunião gravada = uma pasta em disco com meta.json, áudio e markdown.
public struct Meeting: Identifiable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable {
        case recording   // gravação em andamento
        case processing  // transcrevendo/resumindo
        case ready       // resumo pronto
        case failed      // pipeline falhou (re-executável)
    }

    public let id: String        // nome da pasta
    public var title: String
    public var startedAt: Date
    public var durationSeconds: Double
    public var status: Status
    public var errorMessage: String?
    public var template: String? // SummaryTemplate.rawValue (nil = trabalho)
    public var tags: [String]
    public var folder: String?   // pasta lógica ("1:1", "Comitê Operacional"…)
    public var refined: Bool?    // false = transcript rápido, refino em 2º plano
    public var folderURL: URL

    public var summaryTemplate: SummaryTemplate {
        template.flatMap(SummaryTemplate.init(rawValue:)) ?? .trabalho
    }

    /// Novas gravações usam .caf (formato à prova de crash: legível mesmo se
    /// o app morrer no meio); reuniões antigas em .wav continuam resolvendo.
    public var micURL: URL { audioURL(base: "mic") }
    public var systemURL: URL { audioURL(base: "sistema") }

    private func audioURL(base: String) -> URL {
        let caf = folderURL.appendingPathComponent("\(base).caf")
        if FileManager.default.fileExists(atPath: caf.path) { return caf }
        let wav = folderURL.appendingPathComponent("\(base).wav")
        if FileManager.default.fileExists(atPath: wav.path) { return wav }
        return caf // padrão para gravações novas
    }
    public var transcriptURL: URL { folderURL.appendingPathComponent("transcript.md") }
    public var summaryURL: URL { folderURL.appendingPathComponent("resumo.md") }
    public var notesURL: URL { folderURL.appendingPathComponent("notas.md") }
}

/// Representação persistida (meta.json). Campos novos são opcionais para
/// manter compatibilidade com reuniões antigas.
struct MeetingMeta: Codable {
    var title: String
    var startedAt: Date
    var durationSeconds: Double
    var status: Meeting.Status
    var errorMessage: String?
    var template: String?
    var tags: [String]?
    var folder: String?
    var refined: Bool?
}
