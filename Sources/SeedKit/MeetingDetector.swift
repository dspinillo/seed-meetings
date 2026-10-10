import AppKit
import CoreAudio
import Foundation

/// Uma reunião detectada em andamento no Mac.
public struct DetectedMeeting: Equatable, Sendable {
    public enum Source: String, Sendable {
        case meet = "Google Meet"
        case teams = "Microsoft Teams"
    }

    public let source: Source
    public let title: String
    public let viaBrowser: Bool

    public init(source: Source, title: String, viaBrowser: Bool = false) {
        self.source = source
        self.title = title
        self.viaBrowser = viaBrowser
    }

    /// Chave de cooldown: mesma reunião não re-notifica.
    public var key: String { "\(source.rawValue)|\(title)" }
}

/// Detecção local de reunião, conforme decidido no plano (sem calendário):
/// aba do meet.google.com no Chrome (Apple Events) OU processo do Teams,
/// sempre combinado com "microfone em uso" (CoreAudio).
public enum MeetingDetector {
    public static func detect(meetEnabled: Bool = true, teamsEnabled: Bool = true) -> DetectedMeeting? {
        guard meetEnabled || teamsEnabled, micInUse() else { return nil }
        // Meet e Teams no navegador (Chrome)
        if let browser = browserMeetingTab(meetEnabled: meetEnabled, teamsEnabled: teamsEnabled) {
            return browser
        }
        // Teams como app desktop
        if teamsEnabled, teamsRunning() {
            return DetectedMeeting(source: .teams, title: "Reunião no Teams")
        }
        return nil
    }

    /// Fragmentos de URL de reunião por fonte (cobre Meet e Teams no navegador).
    static let browserFragments: [(fragment: String, source: DetectedMeeting.Source)] = [
        ("meet.google.com", .meet),
        ("teams.microsoft.com", .teams),
        ("teams.live.com", .teams),
    ]

    /// Primeira aba do Chrome numa URL de reunião (Meet ou Teams web), com
    /// título limpo. Só consulta se o Chrome já estiver rodando.
    public static func browserMeetingTab(
        meetEnabled: Bool = true,
        teamsEnabled: Bool = true
    ) -> DetectedMeeting? {
        guard let raw = firstChromeTab(matchingAny: enabledFragments(meet: meetEnabled, teams: teamsEnabled)) else {
            return nil
        }
        let parts = raw.components(separatedBy: "|||")
        guard parts.count == 2 else { return nil }
        let url = parts[0]
        let title = parts[1]
        for (fragment, source) in browserFragments where url.contains(fragment) {
            switch source {
            case .meet:
                return DetectedMeeting(source: .meet, title: cleanMeetTitle(title), viaBrowser: true)
            case .teams:
                return DetectedMeeting(source: .teams, title: cleanTeamsTitle(title), viaBrowser: true)
            }
        }
        return nil
    }

    /// A aba da reunião (da fonte dada) ainda existe? — usado pelo auto-stop.
    public static func browserTabPresent(for source: DetectedMeeting.Source) -> Bool {
        let fragments = browserFragments.filter { $0.source == source }.map(\.fragment)
        return firstChromeTab(matchingAny: fragments) != nil
    }

    private static func enabledFragments(meet: Bool, teams: Bool) -> [String] {
        browserFragments
            .filter { ($0.source == .meet && meet) || ($0.source == .teams && teams) }
            .map(\.fragment)
    }

    /// Último problema visto ao consultar o Chrome (ex.: permissão de
    /// Automação negada) — exposto para a UI não falhar em silêncio.
    public private(set) nonisolated(unsafe) static var lastTabIssue: String?

    private static func firstChromeTab(matchingAny fragments: [String]) -> String? {
        guard !fragments.isEmpty, chromeRunning() else { return nil }
        let condition = fragments.map { "u contains \"\($0)\"" }.joined(separator: " or ")
        let script = """
        tell application "Google Chrome"
            repeat with w in windows
                repeat with t in tabs of w
                    set u to URL of t
                    if \(condition) then return u & "|||" & (title of t)
                end repeat
            end repeat
        end tell
        return ""
        """
        // osascript como subprocess: thread-safe (NSAppleScript exige main
        // thread) e o prompt de Automação do TCC é atribuído ao Seed.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        // fecha os pipes em todos os caminhos: sem isso cada ciclo (a cada 5s)
        // deixava 2 descritores abertos e, horas depois, o app esgotava o
        // limite — o osascript não rodava mais ("Bad file descriptor") e a
        // detecção morria em silêncio até reiniciar
        defer {
            for pipe in [stdout, stderr] {
                try? pipe.fileHandleForReading.close()
                try? pipe.fileHandleForWriting.close()
            }
        }
        do {
            try process.run()
        } catch {
            lastTabIssue = "não consegui rodar o osascript: \(error.localizedDescription)"
            return nil
        }
        // espera com teto: um osascript pendurado (Chrome com modal aberto,
        // prompt de TCC engolido) deixava o waitUntilExit preso para sempre —
        // e com ele o loop de detecção inteiro (auto-gravar + auto-stop mortos
        // até reiniciar o app; aconteceu em 10/08 às 13:30).
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.3)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            lastTabIssue = "osascript não respondeu em 10s (Chrome ocupado?) — pulei este ciclo"
            return nil
        }
        let errorText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            if errorText.contains("-1743") || errorText.lowercased().contains("not authoriz") {
                lastTabIssue = "permissão de Automação para o Chrome negada — libere em Ajustes > Privacidade e Segurança > Automação > Seed"
            } else {
                lastTabIssue = "erro ao consultar o Chrome: \(errorText.prefix(160))"
            }
            return nil
        }
        lastTabIssue = nil
        let value = (String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    // MARK: - Diagnóstico (botão "Testar detecção" e CLI)

    public struct Diagnostics: Sendable {
        public let chromeRunning: Bool
        public let meetingTab: String?
        public let tabIssue: String?
        public let teamsAppRunning: Bool
        public let micInUse: Bool
        public let result: DetectedMeeting?
    }

    public static func diagnose(meetEnabled: Bool = true, teamsEnabled: Bool = true) -> Diagnostics {
        let chrome = chromeRunning()
        let tab = browserMeetingTab(meetEnabled: meetEnabled, teamsEnabled: teamsEnabled)
        let teams = teamsRunning()
        let mic = micInUse()
        let result: DetectedMeeting? = {
            guard mic else { return nil }
            if let tab { return tab }
            if teamsEnabled, teams { return DetectedMeeting(source: .teams, title: "Reunião no Teams") }
            return nil
        }()
        return Diagnostics(
            chromeRunning: chrome,
            meetingTab: tab.map { "\($0.title) (\($0.source.rawValue))" },
            tabIssue: lastTabIssue,
            teamsAppRunning: teams,
            micInUse: mic,
            result: result
        )
    }

    /// "Reunião X | Microsoft Teams" → "Reunião X".
    static func cleanTeamsTitle(_ raw: String) -> String {
        var title = raw
        for suffix in [" | Microsoft Teams", "| Microsoft Teams", " - Microsoft Teams"] where title.hasSuffix(suffix) {
            title = String(title.dropLast(suffix.count))
        }
        title = title.replacingOccurrences(of: #"^\(\d+\)\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if title.isEmpty || title.lowercased().contains("microsoft teams") || title.lowercased() == "chat" {
            return "Reunião no Teams"
        }
        return title
    }

    // MARK: - Chrome / Meet

    public static func chromeRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").isEmpty
    }

    /// Título da primeira aba do Chrome em meet.google.com, ou nil.
    /// IMPORTANTE: só consulta se o Chrome já estiver rodando (Apple Events
    /// lançariam o app). Primeira chamada dispara o prompt de Automação do TCC.
    public static func meetTabTitle() -> String? {
        guard chromeRunning() else { return nil }
        let script = """
        tell application "Google Chrome"
            repeat with w in windows
                repeat with t in tabs of w
                    if URL of t contains "meet.google.com" then return title of t
                end repeat
            end repeat
        end tell
        return ""
        """
        var error: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else { return nil }
        let output = appleScript.executeAndReturnError(&error)
        if error != nil { return nil } // permissão negada ou Chrome ocupado — degrada em silêncio
        guard let title = output.stringValue, !title.isEmpty else { return nil }
        return title
    }

    /// "Meet – Weekly BA" → "Weekly BA"; título que é só o código da sala vira genérico.
    static func cleanMeetTitle(_ raw: String) -> String {
        var title = raw
        for prefix in ["Meet – ", "Meet - ", "Meet — "] where title.hasPrefix(prefix) {
            title = String(title.dropFirst(prefix.count))
        }
        title = title.trimmingCharacters(in: .whitespaces)
        // código de sala tipo "abc-defg-hij" não é um nome útil
        let roomCode = #"^[a-z]{3,4}-[a-z]{3,4}-[a-z]{3,4}$"#
        if title.isEmpty || title.range(of: roomCode, options: .regularExpression) != nil {
            return "Reunião no Meet"
        }
        return title
    }

    // MARK: - Teams

    public static func teamsRunning() -> Bool {
        let ids = ["com.microsoft.teams2", "com.microsoft.teams"]
        return ids.contains { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
    }

    // MARK: - Microfone em uso (nível de dispositivo)

    /// Algum dispositivo COM ENTRADA está ativo? Checa todos (não só o padrão):
    /// com fone/AirPods, o Chrome captura por um device que não é o default
    /// do sistema — foi exatamente o bug do teste de 07/07.
    public static func micInUse() -> Bool {
        var listAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var listSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &listSize
        ) == noErr, listSize > 0 else { return false }

        let count = Int(listSize) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &listSize, &devices
        ) == noErr else { return false }

        for device in devices {
            // considera só dispositivos que têm streams de ENTRADA
            var streamsAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamsSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &streamsAddress, 0, nil, &streamsSize) == noErr,
                  streamsSize > 0
            else { continue }

            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            var runningAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            if AudioObjectGetPropertyData(device, &runningAddress, 0, nil, &runningSize, &running) == noErr,
               running != 0 {
                return true
            }
        }
        return false
    }
}
