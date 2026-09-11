import AppKit
import SwiftUI

/// Restaura e persiste o frame da janela principal por conta própria.
/// O restore nativo deixa a janela nascer na tela "ativa" do momento — com o
/// monitor em pé ao lado, ela abria lá, clampada em 1080pt e "esmagada".
/// Aqui o frame salvo manda: a cada abertura ele é reaplicado, com clamp ao
/// visibleFrame da tela que o contém (ou da principal, se aquela tela sumiu).
struct LibraryWindowPlacement: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            context.coordinator.attach(to: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in
            context.coordinator.attach(to: nsView?.window)
        }
    }

    @MainActor
    final class Coordinator {
        private static let frameKey = "SeedLibraryFrame"
        private weak var window: NSWindow?
        private var observers: [NSObjectProtocol] = []

        deinit {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
        }

        func attach(to window: NSWindow?) {
            guard let window, window !== self.window else { return }
            self.window = window
            restore(window)
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            let save: (Notification) -> Void = { [weak self] _ in
                MainActor.assumeIsolated { self?.save() }
            }
            observers = [
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didMoveNotification, object: window, queue: .main, using: save
                ),
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main, using: save
                ),
            ]
        }

        private func save() {
            guard let window else { return }
            let frame = window.frame
            UserDefaults.standard.set(
                "\(frame.minX),\(frame.minY),\(frame.width),\(frame.height)",
                forKey: Self.frameKey
            )
        }

        private func restore(_ window: NSWindow) {
            guard let raw = UserDefaults.standard.string(forKey: Self.frameKey) else { return }
            let parts = raw.split(separator: ",").compactMap { Double($0) }
            guard parts.count == 4 else { return }
            var frame = NSRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])

            func overlap(_ screen: NSScreen) -> CGFloat {
                let rect = screen.frame.intersection(frame)
                return rect.isNull ? 0 : rect.width * rect.height
            }
            let best = NSScreen.screens.max { overlap($0) < overlap($1) }
            let target = (best.map(overlap) ?? 0) > 0 ? best : NSScreen.main
            guard let visible = target?.visibleFrame else { return }

            frame.size.width = min(frame.width, visible.width)
            frame.size.height = min(frame.height, visible.height)
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
            window.setFrame(frame, display: true)
        }
    }
}
