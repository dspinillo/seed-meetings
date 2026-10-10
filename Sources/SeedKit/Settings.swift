import Foundation

/// Configuração do Seed, compartilhada entre o app e o CLI
/// (JSON transparente em .config.json na pasta de dados — ver SeedPaths).
/// Decodificação retrocompatível: chaves ausentes caem nos padrões.
public struct SeedSettings: Codable, Sendable {
    public var provider: LLMProviderID
    public var ollamaModel: String
    public var defaultTemplate: String
    public var retentionDays: Int      // 36500 = "para sempre"
    public var detectMeet: Bool
    public var detectTeams: Bool
    public var autoStop: Bool
    /// Com qual IA o refino em 2º plano re-resume: "same", um LLMProviderID
    /// rawValue, ou "skip" (mantém o resumo rápido — economiza o limite).
    public var refineProvider: String
    /// Modelo passado ao `claude -p --model`: alias ("sonnet", "opus", "haiku"),
    /// ID completo, ou "default" para herdar o modelo configurado na conta.
    /// Sonnet poupa o limite semanal do Max no volume de reuniões.
    public var codexModel: String
    public var claudeModel: String
    /// UID do microfone preferido ("default" = seguir o padrão do sistema).
    /// O macOS troca o input padrão sozinho (AirPods etc.); fixar aqui evita
    /// gravar do dispositivo errado quando fones conectam no meio da reunião.
    public var micDeviceUID: String
    /// Atalho global da nota por voz: rawValue de HotkeyPreset ("off" desliga).
    public var voiceNoteHotkey: String
    /// "hold" (segurar para falar) ou "toggle" (aperta para começar/terminar).
    public var voiceNoteMode: String
    /// Modelo do Claude para tarefas curtas (classificação, chat ao vivo):
    /// alias como em `claudeModel`. Só vale quando o motor é o Claude.
    public var fastClaudeModel: String
    /// Classifica cada reunião (temperatura, flags, ferramentas, temas) depois
    /// do resumo — uma chamada pequena a mais por resumo gerado.
    public var classifyMeetings: Bool
    /// Índice semântico local via Ollama (`/api/embed`). Desligado por padrão:
    /// exige o servidor rodando e o modelo baixado.
    public var semanticSearch: Bool
    public var embeddingModel: String

    public init(
        provider: LLMProviderID = .claude,
        ollamaModel: String = "qwen3",
        defaultTemplate: String = SummaryTemplate.trabalho.rawValue,
        retentionDays: Int = 30,
        detectMeet: Bool = true,
        detectTeams: Bool = true,
        autoStop: Bool = true,
        refineProvider: String = "same",
        claudeModel: String = "sonnet",
        codexModel: String = "default",
        micDeviceUID: String = "default",
        voiceNoteHotkey: String = "optSpace",
        voiceNoteMode: String = "hold",
        fastClaudeModel: String = "haiku",
        classifyMeetings: Bool = true,
        semanticSearch: Bool = false,
        embeddingModel: String = "embeddinggemma-2:270m"
    ) {
        self.provider = provider
        self.ollamaModel = ollamaModel
        self.defaultTemplate = defaultTemplate
        self.retentionDays = retentionDays
        self.detectMeet = detectMeet
        self.detectTeams = detectTeams
        self.autoStop = autoStop
        self.refineProvider = refineProvider
        self.claudeModel = claudeModel
        self.codexModel = codexModel
        self.micDeviceUID = micDeviceUID
        self.voiceNoteHotkey = voiceNoteHotkey
        self.voiceNoteMode = voiceNoteMode
        self.fastClaudeModel = fastClaudeModel
        self.classifyMeetings = classifyMeetings
        self.semanticSearch = semanticSearch
        self.embeddingModel = embeddingModel
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SeedSettings()
        provider = (try? container.decode(LLMProviderID.self, forKey: .provider)) ?? defaults.provider
        ollamaModel = (try? container.decode(String.self, forKey: .ollamaModel)) ?? defaults.ollamaModel
        defaultTemplate = (try? container.decode(String.self, forKey: .defaultTemplate)) ?? defaults.defaultTemplate
        retentionDays = (try? container.decode(Int.self, forKey: .retentionDays)) ?? defaults.retentionDays
        detectMeet = (try? container.decode(Bool.self, forKey: .detectMeet)) ?? defaults.detectMeet
        detectTeams = (try? container.decode(Bool.self, forKey: .detectTeams)) ?? defaults.detectTeams
        autoStop = (try? container.decode(Bool.self, forKey: .autoStop)) ?? defaults.autoStop
        refineProvider = (try? container.decode(String.self, forKey: .refineProvider)) ?? defaults.refineProvider
        codexModel = (try? container.decode(String.self, forKey: .codexModel)) ?? defaults.codexModel
        claudeModel = (try? container.decode(String.self, forKey: .claudeModel)) ?? defaults.claudeModel
        micDeviceUID = (try? container.decode(String.self, forKey: .micDeviceUID)) ?? defaults.micDeviceUID
        voiceNoteHotkey = (try? container.decode(String.self, forKey: .voiceNoteHotkey)) ?? defaults.voiceNoteHotkey
        voiceNoteMode = (try? container.decode(String.self, forKey: .voiceNoteMode)) ?? defaults.voiceNoteMode
        fastClaudeModel = (try? container.decode(String.self, forKey: .fastClaudeModel)) ?? defaults.fastClaudeModel
        classifyMeetings = (try? container.decode(Bool.self, forKey: .classifyMeetings)) ?? defaults.classifyMeetings
        semanticSearch = (try? container.decode(Bool.self, forKey: .semanticSearch)) ?? defaults.semanticSearch
        embeddingModel = (try? container.decode(String.self, forKey: .embeddingModel)) ?? defaults.embeddingModel
    }

    public var summaryTemplate: SummaryTemplate {
        SummaryTemplate(rawValue: defaultTemplate) ?? .trabalho
    }

    private static var fileURL: URL {
        SeedPaths.dataDirectory.appendingPathComponent(".config.json")
    }

    /// Cache em memória validado pelo mtime do arquivo: load() é chamado a
    /// cada tick do detector (5s, na main thread) — um stat é barato; reler e
    /// decodificar o JSON toda vez não. O mtime cobre edições de fora (CLI/MCP).
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: (path: String, modified: Date?, settings: SeedSettings)?

    public static func load() -> SeedSettings {
        let url = fileURL
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cache, cache.path == url.path, cache.modified == modified {
            return cache.settings
        }
        let settings = (try? Data(contentsOf: url))
            .flatMap { try? JSONDecoder().decode(SeedSettings.self, from: $0) } ?? SeedSettings()
        cache = (url.path, modified, settings)
        return settings
    }

    public func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? FileManager.default.createDirectory(
            at: Self.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}
