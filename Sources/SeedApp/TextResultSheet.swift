import AppKit
import SeedKit
import SwiftUI

/// Sheet genérico para resultados de LLM (follow-up, action items):
/// gera ao abrir, mostra em markdown e copia com 1 clique.
struct TextResultSheet: View {
    let title: String
    let subtitle: String
    let generate: @Sendable () throws -> String
    @Binding var isPresented: Bool

    @State private var text: String?
    @State private var error: String?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title3.weight(.bold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)

            Divider()

            Group {
                if let error {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: 420)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let text {
                    ScrollView {
                        MarkdownLite(text: text)
                            .padding(20)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Gerando…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            Divider()

            HStack {
                Spacer()
                Button(copied ? "Copiado ✓" : "Copiar") {
                    guard let text else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                }
                .disabled(text == nil)
                Button("Fechar") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 560, height: 480)
        .background(SeedTheme.windowBG)
        .tint(SeedTheme.accent)
        .task {
            let work = generate
            let result: Result<String, Error> = await Task.detached { Result { try work() } }.value
            switch result {
            case .success(let value): text = value
            case .failure(let failure): error = "\(failure)"
            }
        }
    }
}
