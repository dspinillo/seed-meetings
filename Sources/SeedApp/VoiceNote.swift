import AppKit
import AVFoundation
import SeedKit
import SwiftUI

/// Nota por voz (estilo Handy): segura o atalho global, fala, solta — o texto
/// transcrito entra nas "Minhas notas" da reunião em andamento (espinha dorsal
/// do resumo). Sem gravação ativa, vira nota avulsa na "reunião" de notas
/// soltas do dia.
@MainActor
final class VoiceNoteController: ObservableObject {
    static let shared = VoiceNoteController()

    enum Phase: Equatable {
        case idle, listening, transcribing, saved, failed(String)
    }

    @Published var phase: Phase = .idle
    /// true quando o modo atual é toggle (muda o hint do HUD).
    @Published var toggleMode = false

    /// Sessão da reunião no momento do begin — referência própria para a nota
    /// sobreviver a um stopRecording() no meio (o buffer lateral fica em memória).
    private var noteSession: RecordingSession?
    private var noteStartClock: Double = 0
    private var stray: StrayCapture?
    private var autoFinish: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?

    private init() {}

    /// Nível 0–1 do mic para a barrinha do HUD (sessão ou captura avulsa).
    var level: Float {
        if let noteSession { return noteSession.micLevel }
        return stray?.level ?? 0
    }

    func hotkeyPressed() {
        toggleMode = SeedSettings.load().voiceNoteMode == "toggle"
        if toggleMode {
            if phase == .listening { finish() } else { begin() }
        } else {
            begin()
        }
    }

    func hotkeyReleased() {
        guard !toggleMode else { return }
        finish()
    }

    private func begin() {
        guard phase != .listening, phase != .transcribing else { return }
        hideTask?.cancel()
        hideTask = nil

        if let session = AppState.shared.session {
            noteSession = session
            noteStartClock = session.beginVoiceNoteCapture()
        } else {
            // nota avulsa: captura efêmera própria (seguro — não há MicRecorder ativo)
            noteSession = nil
            phase = .listening
            VoiceNoteHUD.shared.show()
            Task {
                guard await MicRecorder.requestPermission() else {
                    fail("Sem permissão de microfone")
                    return
                }
                guard phase == .listening, stray == nil else { return }
                do {
                    let capture = try StrayCapture()
                    try capture.start()
                    stray = capture
                    armAutoFinish()
                } catch {
                    fail("Não consegui abrir o microfone")
                }
            }
            return
        }
        startListening()
    }

    private func startListening() {
        guard phase != .listening else {
            armAutoFinish()
            return
        }
        phase = .listening
        VoiceNoteHUD.shared.show()
        armAutoFinish()
    }

    /// Teto do modo toggle esquecido ligado (o buffer lateral também tem teto de 180s).
    private func armAutoFinish() {
        autoFinish?.cancel()
        autoFinish = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 180 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.finish()
        }
    }

    private func finish() {
        guard phase == .listening else { return }
        autoFinish?.cancel()
        autoFinish = nil

        let samples: [Float]
        let meeting: Meeting?
        let stamp: String
        if let session = noteSession {
            samples = session.endVoiceNoteCapture()
            meeting = session.meeting
            stamp = Self.mmss(noteStartClock)
            noteSession = nil
        } else if let stray {
            samples = stray.stop()
            self.stray = nil
            meeting = nil
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            stamp = formatter.string(from: Date())
        } else {
            // released antes da captura avulsa abrir (< meio segundo de fala)
            reset()
            return
        }

        guard samples.count >= 8_000 else { // <0,5s: toque acidental
            reset()
            return
        }

        phase = .transcribing
        Task {
            var text = (try? await Pipeline.shared.transcribeSamples(samples)) ?? ""
            if text.isEmpty {
                text = (try? await Pipeline.shared.transcribeSamples(samples)) ?? ""
            }
            guard let target = meeting ?? AppState.shared.strayNotesMeeting() else {
                fail("Não consegui criar a nota")
                return
            }
            if text.isEmpty {
                // nota perdida é inaceitável: guarda o áudio e avisa nas notas
                let name = "nota-voz-\(target.id)-\(Int(Date().timeIntervalSince1970)).wav"
                let wavURL = target.folderURL.appendingPathComponent(name)
                try? LiveWav.write(samples, to: wavURL)
                AppState.shared.appendVoiceNote(
                    "🎤 \(stamp) (falha ao transcrever — áudio salvo em \(name))", to: target
                )
                fail("Não transcreveu — áudio salvo nas notas")
            } else {
                AppState.shared.appendVoiceNote("🎤 \(stamp) \(text)", to: target)
                phase = .saved
                scheduleHide(after: 1.2)
            }
        }
    }

    private func fail(_ message: String) {
        stray = nil
        noteSession = nil
        phase = .failed(message)
        scheduleHide(after: 2.5)
    }

    private func reset() {
        stray = nil
        noteSession = nil
        phase = .idle
        VoiceNoteHUD.shared.hide()
    }

    private func scheduleHide(after seconds: Double) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.reset()
        }
    }

    private static func mmss(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return String(format: "[%02d:%02d]", total / 60, total % 60)
    }
}

/// Captura efêmera do mic para a nota avulsa (sem gravação em andamento não
/// existe MicRecorder ativo, então um engine próprio é seguro — precedente:
/// micTestCommand do seed-spike).
@MainActor
final class StrayCapture {
    private let engine = AVAudioEngine()
    private let sink: ConvertingWavSink

    init() throws {
        sink = try ConvertingWavSink(
            url: FileManager.default.temporaryDirectory
                .appendingPathComponent("seed-nota-\(UUID().uuidString).wav")
        )
    }

    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        sink.startSideCapture()
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [sink] buffer, _ in
            sink.write(buffer)
        }
        try engine.start()
    }

    func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let samples = sink.endSideCapture()
        sink.close()
        try? FileManager.default.removeItem(at: sink.url)
        return samples
    }

    var level: Float { RecordingSession.normalizedLevel(sink.lastRMS) }
}

/// HUD flutuante da nota por voz — molde da FloatingBubble, posicionado logo
/// abaixo da bolha (ou canto superior direito, sem bolha na tela).
@MainActor
final class VoiceNoteHUD {
    static let shared = VoiceNoteHUD()
    private var panel: NSPanel?

    func show() {
        guard panel == nil else { return }
        let hosting = NSHostingView(rootView: VoiceNoteHUDView())
        hosting.frame = NSRect(x: 0, y: 0, width: 300, height: 52)

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
        newPanel.contentView = hosting
        newPanel.setFrameTopLeftPoint(Self.topLeft(panelSize: hosting.frame.size))
        newPanel.orderFrontRegardless()
        panel = newPanel
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }

    /// Abaixo da bolha flutuante (mesma chave de posição), com clamp à tela.
    private static func topLeft(panelSize: NSSize) -> NSPoint {
        let fallbackScreen = NSScreen.main ?? NSScreen.screens.first
        var point: NSPoint
        if let raw = UserDefaults.standard.string(forKey: "SeedBubbleTopLeft") {
            let parts = raw.split(separator: ",").compactMap { Double($0) }
            point = parts.count == 2
                ? NSPoint(x: parts[0], y: parts[1] - 64)
                : .zero
        } else if let visible = fallbackScreen?.visibleFrame {
            point = NSPoint(x: visible.maxX - panelSize.width - 20, y: visible.maxY - 90)
        } else {
            point = .zero
        }
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? fallbackScreen
        guard let visible = screen?.visibleFrame else { return point }
        return NSPoint(
            x: min(max(point.x, visible.minX), visible.maxX - panelSize.width),
            y: min(max(point.y, visible.minY + panelSize.height), visible.maxY)
        )
    }
}

struct VoiceNoteHUDView: View {
    @ObservedObject var controller = VoiceNoteController.shared

    var body: some View {
        HStack(spacing: 10) {
            switch controller.phase {
            case .listening:
                listeningContent
            case .transcribing:
                ProgressView().controlSize(.small)
                Text("Transcrevendo…").font(.callout.weight(.medium))
            case .saved:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Nota salva").font(.callout.weight(.medium))
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text(message).font(.caption).lineLimit(2)
            case .idle:
                EmptyView()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
        .tint(SeedTheme.accent)
        .padding(5)
    }

    private var listeningContent: some View {
        TimelineView(.periodic(from: .now, by: 0.15)) { context in
            HStack(spacing: 8) {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                    .opacity(context.date.timeIntervalSince1970.truncatingRemainder(dividingBy: 1) < 0.5 ? 1 : 0.35)
                Capsule()
                    .fill(.quaternary)
                    .frame(width: 42, height: 5)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(SeedTheme.accent)
                            .frame(width: max(3, 42 * CGFloat(controller.level)))
                    }
                Text(controller.toggleMode
                    ? "Ouvindo… aperte de novo para salvar"
                    : "Ouvindo… solte para salvar")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
