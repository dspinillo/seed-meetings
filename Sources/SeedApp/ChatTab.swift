import SeedKit
import SwiftUI

/// Chat com uma reunião (resumo, notas e transcript) ou com um tópico (as
/// reuniões dele), via provider de LLM selecionado.
struct ChatTab: View {
    enum Subject {
        case meeting(Meeting)
        case topic(Topic)
    }

    @EnvironmentObject var state: AppState
    let subject: Subject

    init(meeting: Meeting) { subject = .meeting(meeting) }
    init(topic: Topic) { subject = .topic(topic) }

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
                                Text(emptyTitle)
                                    .font(.headline)
                                Text(emptyExamples)
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
                            // streaming: a resposta aparece enquanto chega
                            if let partial = state.chatPartial[key], !partial.isEmpty {
                                answerBubble(partial)
                                    .id("busy")
                            } else {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text("Pensando…")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }
                                .id("busy")
                            }
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
                .onChange(of: state.chatPartial[key]) { _, _ in
                    proxy.scrollTo("busy", anchor: .bottom)
                }
            }

            Divider()

            HStack(spacing: 8) {
                TextField(placeholder, text: $question)
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
        .onChange(of: key) { _, _ in reload() }
        .onChange(of: state.chatTick) { _, _ in history = loadHistory() }
    }

    /// Chave de ocupado/streaming: id da reunião ou seleção do tópico.
    private var key: String {
        switch subject {
        case .meeting(let meeting): return meeting.id
        case .topic(let topic): return AppState.topicSelection(topic.id)
        }
    }

    private var isBusy: Bool { state.chatBusy.contains(key) }

    /// Esta reunião está sendo gravada agora? → contexto vem do live.
    private var isLive: Bool {
        if case .meeting(let meeting) = subject { return state.session?.meeting.id == meeting.id }
        return false
    }

    private var emptyTitle: String {
        if case .topic = subject { return "Pergunte sobre as reuniões deste tópico" }
        return isLive ? "Pergunte sobre a reunião em andamento" : "Pergunte qualquer coisa sobre esta reunião"
    }

    private var emptyExamples: String {
        if case .topic = subject {
            return "Ex.: \"o que mudou desde a primeira reunião?\", \"o que continua em aberto?\", \"quem ficou de entregar o quê?\""
        }
        return isLive
            ? "Ex.: \"voltei do banheiro — o que perdi nos últimos 5 min?\", \"já decidiram o prazo?\", \"alguém me citou?\""
            : "Ex.: \"o que ficou pendente comigo?\", \"o que foi decidido sobre o painel?\", \"em que momento falamos de prazo?\""
    }

    private var placeholder: String {
        if case .topic = subject { return "Pergunte sobre o tópico…" }
        return "Pergunte sobre a reunião…"
    }

    private func loadHistory() -> [ChatMessage] {
        switch subject {
        case .meeting(let meeting): return MeetingChat.history(for: meeting)
        case .topic(let topic): return Topics.history(for: topic.id)
        }
    }

    private func reload() {
        history = loadHistory()
        inputFocused = true
    }

    private func send() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isBusy else { return }
        question = ""
        // eco imediato da pergunta na UI (persistência real acontece no sucesso)
        history.append(ChatMessage(role: "user", content: text))
        switch subject {
        case .meeting(let meeting):
            if isLive {
                state.askLive(text)
            } else {
                state.ask(text, about: meeting)
            }
        case .topic(let topic):
            state.ask(text, aboutTopic: topic)
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
            answerBubble(message.content)
        }
    }

    private func answerBubble(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("🌱")
                .font(.caption)
                .padding(.top, 6)
            MarkdownLite(text: text)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            Spacer(minLength: 40)
        }
    }
}
