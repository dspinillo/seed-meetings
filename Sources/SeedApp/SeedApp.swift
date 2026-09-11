import SeedKit
import SwiftUI

@main
struct SeedApp: App {
    @StateObject private var state = AppState.shared

    var body: some Scene {
        WindowGroup("Seed", id: "library") {
            LibraryView()
                .environmentObject(state)
                .frame(minWidth: 760, minHeight: 480)
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Preferências…") {
                    AppState.shared.showPreferences = true
                    AppState.shared.openLibrary()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }

        MenuBarExtra {
            MenuBarView()
                .environmentObject(state)
        } label: {
            MenuBarLabel()
                .environmentObject(state)
        }
        .menuBarExtraStyle(.window)
    }
}

/// O rótulo da menu bar também escuta o pedido de "abrir o Seed" vindo da
/// bolha flutuante — é o único ponto sempre vivo com acesso a openWindow.
struct MenuBarLabel: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: state.isRecording
            ? "record.circle.fill"
            : state.detected != nil ? "leaf.circle.fill" : "leaf.fill")
            .onChange(of: state.openLibraryTick) { _, _ in
                openWindow(id: "library")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
    }
}
