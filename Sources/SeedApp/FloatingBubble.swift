import AppKit
import SeedKit
import SwiftUI

/// A "bolha" flutuante de gravação: cápsula sempre-no-topo enquanto grava.
/// Clique abre o Seed na reunião em andamento; arraste para reposicionar.
@MainActor
final class FloatingBubble {
    static let shared = FloatingBubble()
    private var panel: NSPanel?
    private var moveObserver: NSObjectProtocol?

    /// Persistimos só o canto superior esquerdo, por conta própria. O
    /// setFrameAutosaveName regravava o frame a cada resize automático do
    /// conteúdo SwiftUI (inclusive o estado vazio de 38×28) e embutia a
    /// geometria da tela, que muda com Dock/monitores — resultado: a posição
    /// escolhida pelo usuário era corrompida entre um show() e outro.
    private static let topLeftKey = "SeedBubbleTopLeft"

    func show() {
        guard panel == nil else { return }
        let hosting = NSHostingView(
            rootView: BubbleView().environmentObject(AppState.shared)
        )
        hosting.frame = NSRect(x: 0, y: 0, width: 320, height: 56)

        let newPanel = NSPanel(
            contentRect: hosting.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        newPanel.isFloatingPanel = true
        newPanel.level = .floating
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        newPanel.backgroundColor = .clear
        newPanel.isOpaque = false
        newPanel.hasShadow = false
        newPanel.isMovableByWindowBackground = true
        newPanel.contentView = hosting

        newPanel.setFrameTopLeftPoint(Self.restoredTopLeft(panelSize: hosting.frame.size))
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: newPanel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveTopLeft() }
        }
        newPanel.orderFrontRegardless()
        panel = newPanel
    }

    func hide() {
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
        moveObserver = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func saveTopLeft() {
        guard let panel else { return }
        let frame = panel.frame
        UserDefaults.standard.set("\(frame.minX),\(frame.maxY)", forKey: Self.topLeftKey)
    }

    /// Canto superior esquerdo salvo, com clamp ao visibleFrame da tela que o
    /// contém (ou da principal, se aquela tela sumiu). Sem valor salvo: canto
    /// superior direito da tela principal.
    private static func restoredTopLeft(panelSize: NSSize) -> NSPoint {
        let fallbackScreen = NSScreen.main ?? NSScreen.screens.first
        guard let raw = UserDefaults.standard.string(forKey: topLeftKey) else {
            guard let visible = fallbackScreen?.visibleFrame else { return .zero }
            return NSPoint(x: visible.maxX - panelSize.width - 20, y: visible.maxY - 20)
        }
        let parts = raw.split(separator: ",").compactMap { Double($0) }
        let saved = parts.count == 2 ? NSPoint(x: parts[0], y: parts[1]) : .zero
        let screen = NSScreen.screens.first { $0.frame.contains(saved) } ?? fallbackScreen
        guard let visible = screen?.visibleFrame else { return saved }
        return NSPoint(
            x: min(max(saved.x, visible.minX), visible.maxX - panelSize.width),
            y: min(max(saved.y, visible.minY + panelSize.height), visible.maxY)
        )
    }
}

struct BubbleView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 10) {
            if state.session != nil {
                recordingContent
            } else if let detection = state.detected {
                detectionContent(detection)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
        .contentShape(Capsule())
        .tint(SeedTheme.accent)
        .padding(5)
    }

    /// Gravando: REC + tempo + nível + parar. Clique abre o Seed.
    @ViewBuilder
    private var recordingContent: some View {
        if let session = state.session {
            TimelineView(.periodic(from: .now, by: 0.4)) { _ in
                HStack(spacing: 8) {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                    Text(timeString(session.elapsedSeconds))
                        .font(.callout.monospacedDigit().weight(.semibold))
                    Capsule()
                        .fill(.quaternary)
                        .frame(width: 42, height: 5)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(SeedTheme.accent)
                                .frame(width: max(3, 42 * CGFloat(max(session.micLevel, session.systemLevel))))
                        }
                }
            }
            .onTapGesture { state.openLibrary() }
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 18, height: 18)
            Button {
                state.stopRecording()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help("Parar e resumir")
        }
    }

    /// Reunião detectada (de gravação): título + Gravar/Ignorar na hora.
    private func detectionContent(_ detection: DetectedMeeting) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text("Reunião detectada")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(detection.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
            }
            Button("Gravar") {
                state.acceptDetection(detection)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            Button {
                state.dismissDetection()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Ignorar esta reunião por 30 min")
        }
    }
}
