import SeedKit
import SwiftUI

/// Chat com a reunião: perguntas respondidas com base no resumo, notas e
/// transcript, via provider de LLM selecionado.
struct ChatTab: View {
    @EnvironmentObject var state: AppState
    let meeting: Meeting

    @State private var question = ""
    @State private var history: [ChatMessage] = []
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if history.isEmpty && !isBusy {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(isLive
                                    ? "Pergunte sobre a reunião em andamento"
                                    : "Pergunte qualquer coisa sobre esta reunião")
                                    .font(.headline)
                                Text(isLive
                                    ? "Ex.: \"voltei do banheiro — o que perdi nos últimos 5 min?\", \"já decidiram o prazo?\", \"alguém me citou?\""
                                    : "Ex.: \"o que ficou pendente comigo?\", \"o que foi decidido sobre o painel?\", \"em que momento falamos de prazo?\"")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.top, 24)
                        }
                        ForEach(history) { message in
                            bubble(message)
                                .id(message.id)
                        }
                        if isBusy {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Pensando…")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            .id("busy")
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 700, alignment: .leading)
                }
                .onChange(of: history.count) { _, _ in
                    if let last = history.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
                .onChange(of: isBusy) { _, busy in
                    if busy { proxy.scrollTo("busy", anchor: .bottom) }
                }
            }

            Divider()

            HStack(spacing: 8) {
                TextField("Pergunte sobre a reunião…", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .focused($inputFocused)
                    .onSubmit { send() }
                    .disabled(isBusy)
                Button {
                    send()
                } label: {
                    Image(systemName: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy || question.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
        .onAppear { reload() }
        .onChange(of: meeting.id) { _, _ in reload() }
        .onChange(of: state.chatTick) { _, _ in history = MeetingChat.history(for: meeting) }
    }

    private var isBusy: Bool { state.chatBusy.contains(meeting.id) }

    /// Esta reunião está sendo gravada agora? → contexto vem do live.
    private var isLive: Bool { state.session?.meeting.id == meeting.id }

    private func reload() {
        history = MeetingChat.history(for: meeting)
        inputFocused = true
    }

    private func send() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isBusy else { return }
        question = ""
        // eco imediato da pergunta na UI (persistência real acontece no sucesso)
        history.append(ChatMessage(role: "user", content: text))
        if isLive {
            state.askLive(text)
        } else {
            state.ask(text, about: meeting)
        }
    }

    @ViewBuilder
    private func bubble(_ message: ChatMessage) -> some View {
        if message.role == "user" {
            HStack {
                Spacer(minLength: 60)
                Text(message.content)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
            }
        } else {
            HStack(alignment: .top, spacing: 8) {
                Text("🌱")
                    .font(.caption)
                    .padding(.top, 6)
                MarkdownLite(text: message.content)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                Spacer(minLength: 40)
            }
        }
    }
}
