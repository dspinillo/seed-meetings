import Foundation

/// Storage file-based: cada reunião é uma pasta na pasta de dados (SeedPaths).
/// Transparente, sem banco — SQLite entra na Fase 3 junto com a busca.
public final class MeetingStore {
    public let rootURL: URL

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

    public init(rootURL: URL? = nil) {
        self.rootURL = rootURL
            ?? SeedPaths.dataDirectory
        try? FileManager.default.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
    }

    public func list() -> [Meeting] {
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else { return [] }

        var meetings: [Meeting] = []
        for folder in entries {
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let meeting = read(folderURL: folder)
            else { continue }
            meetings.append(meeting)
        }
        return meetings.sorted { $0.startedAt > $1.startedAt }
    }

    public func read(folderURL: URL) -> Meeting? {
        let metaURL = folderURL.appendingPathComponent("meta.json")
        guard
            let data = try? Data(contentsOf: metaURL),
            let meta = try? Self.decoder.decode(MeetingMeta.self, from: data)
        else { return nil }
        return Meeting(
            id: folderURL.lastPathComponent,
            title: meta.title,
            startedAt: meta.startedAt,
            durationSeconds: meta.durationSeconds,
            status: meta.status,
            errorMessage: meta.errorMessage,
            template: meta.template,
            tags: meta.tags ?? [],
            folder: meta.folder,
            refined: meta.refined,
            folderURL: folderURL
        )
    }

    public func create(title: String) throws -> Meeting {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let now = Date()
        let id = formatter.string(from: now)
        let folder = rootURL.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let meeting = Meeting(
            id: id,
            title: title,
            startedAt: now,
            durationSeconds: 0,
            status: .recording,
            errorMessage: nil,
            template: nil,
            tags: [],
            folder: nil,
            refined: nil,
            folderURL: folder
        )
        save(meeting)
        return meeting
    }

    public func save(_ meeting: Meeting) {
        let meta = MeetingMeta(
            title: meeting.title,
            startedAt: meeting.startedAt,
            durationSeconds: meeting.durationSeconds,
            status: meeting.status,
            errorMessage: meeting.errorMessage,
            template: meeting.template,
            tags: meeting.tags.isEmpty ? nil : meeting.tags,
            folder: meeting.folder,
            refined: meeting.refined
        )
        guard let data = try? Self.encoder.encode(meta) else { return }
        try? data.write(to: meeting.folderURL.appendingPathComponent("meta.json"), options: .atomic)
    }

    /// Read-modify-write: recarrega o meta.json do disco antes de aplicar a
    /// mutação, para escritas concorrentes (refino em 2º plano × ações da UI
    /// com cópias antigas do Meeting) não sobrescreverem campos umas das
    /// outras — ex.: um save stale voltando `refined` para false.
    @discardableResult
    public func update(_ meeting: Meeting, _ mutate: (inout Meeting) -> Void) -> Meeting {
        var fresh = read(folderURL: meeting.folderURL) ?? meeting
        mutate(&fresh)
        save(fresh)
        return fresh
    }

    public func delete(_ meeting: Meeting) {
        try? FileManager.default.removeItem(at: meeting.folderURL)
    }

    public func readSummary(_ meeting: Meeting) -> String? {
        try? String(contentsOf: meeting.summaryURL, encoding: .utf8)
    }

    public func readTranscript(_ meeting: Meeting) -> String? {
        try? String(contentsOf: meeting.transcriptURL, encoding: .utf8)
    }

    public func readNotes(_ meeting: Meeting) -> String? {
        try? String(contentsOf: meeting.notesURL, encoding: .utf8)
    }

    public func writeNotes(_ text: String, for meeting: Meeting) {
        try? text.write(to: meeting.notesURL, atomically: true, encoding: .utf8)
    }

    /// Memória de vozes compartilhada entre reuniões.
    public var voiceprints: VoiceprintStore { VoiceprintStore(rootURL: rootURL) }

    /// Retenção decidida no plano: áudio bruto expira em 30 dias; markdown fica.
    public func purgeAudio(olderThanDays days: Int = 30) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        for meeting in list() where meeting.startedAt < cutoff {
            for name in ["mic.caf", "mic.wav", "sistema.caf", "sistema.wav"] {
                try? FileManager.default.removeItem(at: meeting.folderURL.appendingPathComponent(name))
            }
        }
    }

    /// Reuniões presas em "recording"/"processing" — o app morreu no meio.
    public func orphans() -> [Meeting] {
        list().filter { $0.status == .recording || $0.status == .processing }
    }
}
