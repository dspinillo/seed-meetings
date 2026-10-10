import SeedKit
import SwiftUI

/// Tela de um tópico: as reuniões em ordem cronológica, o resumo consolidado
/// com linha do tempo (gerado sob demanda) e o chat sobre todas elas.
struct TopicDetailView: View {
    @EnvironmentObject var state: AppState
    let topic: Topic

    @State private var tab: Tab = .meetings
    @State private var editedName = ""
    @State private var editedDescription = ""
    @State private var excerpts: [String: String] = [:]
    @State private var temperatures: [String: MeetingClassification.Temperatura] = [:]
    @State private var confirmDelete = false

    enum Tab: String, CaseIterable {
        case meetings = "Reuniões"
        case summary = "Resumo e linha do tempo"
        case chat = "Chat"
    }

    private var meetings: [Meeting] { Topics.meetings(of: topic, in: state.meetings) }
    private var key: String { AppState.topicSelection(topic.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: "number")
                        .foregroundStyle(SeedTheme.accent)
                    TextField("Nome do tópico", text: $editedName)
                        .textFieldStyle(.plain)
                        .font(.title2.weight(.bold))
                        .onSubmit { commit() }
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Apagar o tópico (as reuniões continuam na biblioteca)")
                }
                TextField("Descrição (opcional) — ajuda a IA a entender o assunto", text: $editedDescription)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .onSubmit { commit() }
                Text(meetings.isEmpty ? "Nenhuma reunião vinculada" : "\(meetings.count) reunião(ões)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)

            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 430)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)

            Divider()

            switch tab {
            case .meetings: meetingList
            case .summary: summaryPane
            case .chat: ChatTab(topic: topic)
            }
        }
        .onAppear { reload() }
        .onChange(of: topic) { _, _ in reload() }
        .onChange(of: state.meetings) { _, _ in loadExcerpts() }
        .confirmationDialog("Apagar o tópico \"\(topic.name)\"?", isPresented: $confirmDelete) {
            Button("Apagar tópico", role: .destructive) { state.deleteTopic(topic) }
        } message: {
            Text("As reuniões continuam na biblioteca; só o vínculo, o resumo e o chat do tópico são removidos.")
        }
    }

    private func commit() {
        state.updateTopic(topic, name: editedName, description: editedDescription)
    }

    private func reload() {
        editedName = topic.name
        editedDescription = topic.description
        loadExcerpts()
    }

    /// Começo do resumo e temperatura de cada reunião, lidos fora do body.
    private func loadExcerpts() {
        let meetings = self.meetings
        let store = state.store
        Task.detached(priority: .userInitiated) {
            var texts: [String: String] = [:]
            var temps: [String: MeetingClassification.Temperatura] = [:]
            for meeting in meetings {
                texts[meeting.id] = Self.excerpt(store.readSummary(meeting) ?? "")
                temps[meeting.id] = Classifier.load(for: meeting)?.temperatura
            }
            let (loadedTexts, loadedTemps) = (texts, temps)
            await MainActor.run {
                excerpts = loadedTexts
                temperatures = loadedTemps
            }
        }
    }

    /// Primeiro parágrafo de conteúdo do resumo (pula títulos).
    nonisolated static func excerpt(_ summary: String) -> String {
        let lines = summary.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let body = lines.first { !$0.isEmpty && !$0.hasPrefix("#") } ?? ""
        return body.count > 320 ? String(body.prefix(320)) + "…" : body
    }

    private var meetingList: some View {
        ScrollView {
            if meetings.isEmpty {
                ContentUnavailableView(
                    "Tópico vazio",
                    systemImage: "number",
                    description: Text("Na biblioteca, clique com o botão direito numa reunião e escolha \"Vincular a tópico\".")
                )
                .padding(.top, 60)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(meetings) { meeting in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Text(Self.dateFormatter.string(from: meeting.startedAt))
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(SeedTheme.accent)
                                    if let temperature = temperatures[meeting.id] {
                                        TemperatureBadge(temperature: temperature)
                                    }
                                }
                                Button(meeting.title) { state.selectedMeetingID = meeting.id }
                                    .buttonStyle(.plain)
                                    .font(.body.weight(.semibold))
                                if let text = excerpts[meeting.id], !text.isEmpty {
                                    Text(text)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer()
                            Button {
                                state.setLinked(false, meeting: meeting, topic: topic)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Remover do tópico")
                        }
                        .padding(.vertical, 12)
                        Divider()
                    }
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: 760, alignment: .leading)
            }
        }
    }

    private var summaryPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if let stage = state.processingStage[key] {
                    ProgressView().controlSize(.small)
                    Text(stage).font(.callout).foregroundStyle(.secondary)
                } else {
                    Button(topic.summary == nil ? "Gerar resumo do tópico" : "Refazer") {
                        state.consolidate(topic)
                    }
                    .disabled(meetings.isEmpty)
                    if let date = topic.summaryAt {
                        Text("Gerado em \(Self.dateFormatter.string(from: date))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 10)

            ScrollView {
                if let summary = topic.summary {
                    MarkdownLite(text: summary)
                        .padding(24)
                        .frame(maxWidth: 700, alignment: .leading)
                } else {
                    Text("O resumo consolida as reuniões do tópico: onde o assunto está, a linha do tempo de decisões e pendências, o que foi resolvido e o que segue aberto.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(24)
                        .frame(maxWidth: 700, alignment: .leading)
                }
            }
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.dateFormat = "d MMM yyyy"
        return formatter
    }()
}

/// Selo de temperatura da reunião.
struct TemperatureBadge: View {
    let temperature: MeetingClassification.Temperatura

    var body: some View {
        Label(temperature.displayName, systemImage: icon)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
    }

    private var icon: String {
        switch temperature {
        case .tranquila: return "leaf"
        case .neutra: return "circle"
        case .tensa: return "exclamationmark.circle"
        case .conflituosa: return "flame"
        }
    }

    private var color: Color {
        switch temperature {
        case .tranquila: return .green
        case .neutra: return .secondary
        case .tensa: return .orange
        case .conflituosa: return .red
        }
    }
}
