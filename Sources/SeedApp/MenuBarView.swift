import SeedKit
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let session = state.session {
                recordingPanel(session)
            } else {
                idlePanel
            }

            Divider()

            recentSection

            Divider()

            HStack {
                Button("Abrir o Seed") { openLibrary() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Preferências") {
                    state.showPreferences = true
                    openLibrary()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Spacer()
                Button("Sair") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: 300)
        .tint(SeedTheme.accent)
    }

    private var idlePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Seed")
                .font(.headline)
            if let error = state.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
            if state.notificationsDenied {
                Text("Notificações do Seed desativadas — ative em Ajustes > Notificações. O aviso de reunião detectada aparece aqui no painel de qualquer forma.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let detection = state.detected {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Reunião detectada — \(detection.source.rawValue)", systemImage: "sparkles")
                        .font(.caption.weight(.bold))
                    Text(detection.title)
                        .font(.callout)
                        .lineLimit(1)
                    HStack {
                        Button("Gravar") { state.acceptDetection(detection) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        Button("Ignorar") { state.dismissDetection() }
                            .controlSize(.small)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
            Button {
                state.startRecording()
            } label: {
                Label("Gravar reunião", systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .keyboardShortcut("r")
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(SeedTheme.accent)
        }
        .padding(14)
    }

    private func recordingPanel(_ session: RecordingSession) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Circle().fill(.red).frame(width: 9, height: 9)
                        Text("Gravando · \(timeString(session.elapsedSeconds))")
                            .font(.headline.monospacedDigit())
                    }
                    LevelRow(label: "Você", level: session.micLevel)
                    LevelRow(label: "Outros", level: session.systemLevel)
                }
            }
            Text(session.meeting.title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                state.stopRecording()
            } label: {
                Label("Parar e resumir", systemImage: "stop.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .padding(14)
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Recentes")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 14)
                .padding(.top, 8)

            if state.meetings.isEmpty {
                Text("Nenhuma reunião ainda")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
            }

            ForEach(state.meetings.prefix(3)) { meeting in
                Button {
                    state.selectedMeetingID = meeting.id
                    openLibrary()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(meeting.title)
                                .font(.callout)
                                .lineLimit(1)
                            Text(subtitle(for: meeting))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        statusMark(for: meeting)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
            }
        }
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private func statusMark(for meeting: Meeting) -> some View {
        if let stage = state.processingStage[meeting.id] {
            ProgressView()
                .controlSize(.small)
                .help(stage)
        } else {
            switch meeting.status {
            case .ready:
                Image(systemName: "checkmark").font(.caption).foregroundStyle(.green)
            case .failed:
                Image(systemName: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            case .processing:
                ProgressView().controlSize(.small)
            case .recording:
                Circle().fill(.red).frame(width: 7, height: 7)
            }
        }
    }

    private func subtitle(for meeting: Meeting) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.dateFormat = "EEE d MMM, HH:mm"
        var text = formatter.string(from: meeting.startedAt)
        if meeting.durationSeconds > 0 {
            text += " · \(Int(meeting.durationSeconds / 60)) min"
        }
        return text
    }

    private func openLibrary() {
        openWindow(id: "library")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

struct LevelRow: View {
    let label: String
    let level: Float

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: max(3, geo.size.width * CGFloat(level)))
                }
            }
            .frame(height: 6)
        }
    }
}

func timeString(_ seconds: Double) -> String {
    let total = Int(seconds)
    return String(format: "%02d:%02d", total / 60, total % 60)
}
