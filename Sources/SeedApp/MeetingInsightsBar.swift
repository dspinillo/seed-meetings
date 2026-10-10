import SeedKit
import SwiftUI

/// Faixa abaixo do cabeçalho da reunião: temperatura, flags, ferramentas e
/// temas (classificação), mais os tópicos a que ela pertence e as sugestões.
struct MeetingInsightsBar: View {
    @EnvironmentObject var state: AppState
    let meeting: Meeting

    @State private var classification: MeetingClassification?
    @State private var suggestions: [Topic] = []
    @State private var showEvidence = false

    private var linkedTopics: [Topic] { state.topics(of: meeting) }
    private var isClassifying: Bool { state.processingStage["class:" + meeting.id] != nil }

    var body: some View {
        Group {
            if classification != nil || !linkedTopics.isEmpty || !suggestions.isEmpty || isClassifying {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if isClassifying {
                            ProgressView().controlSize(.small)
                        }
                        if let classification {
                            Button {
                                showEvidence = true
                            } label: {
                                TemperatureBadge(temperature: classification.temperatura)
                            }
                            .buttonStyle(.plain)
                            .help("Ver o motivo e as evidências; corrigir a classificação")
                            .popover(isPresented: $showEvidence, arrowEdge: .bottom) { evidencePopover(classification) }

                            ForEach(classification.flags, id: \.self) { flag in
                                chip(MeetingClassification.flagLabel(flag), systemImage: "flag", tint: .orange)
                            }
                            ForEach(suggestedTags(classification), id: \.self) { term in
                                Button {
                                    state.addTag(term, to: meeting)
                                } label: {
                                    chip(term, systemImage: "plus", tint: .secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Adicionar como tag")
                            }
                        }
                        ForEach(linkedTopics) { topic in
                            Button {
                                state.selectedMeetingID = AppState.topicSelection(topic.id)
                            } label: {
                                chip(topic.name, systemImage: "number", tint: SeedTheme.accent)
                            }
                            .buttonStyle(.plain)
                            .help("Abrir o tópico")
                        }
                        ForEach(suggestions) { topic in
                            HStack(spacing: 4) {
                                Text("Tópico sugerido: \(topic.name)")
                                Button("Vincular") { state.setLinked(true, meeting: meeting, topic: topic) }
                                    .buttonStyle(.link)
                                Button {
                                    state.dismissSuggestion(meeting: meeting, topic: topic)
                                } label: {
                                    Image(systemName: "xmark")
                                }
                                .buttonStyle(.borderless)
                                .help("Não é deste tópico")
                            }
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .overlay(Capsule().strokeBorder(SeedTheme.accent.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3])))
                        }
                    }
                }
            }
        }
        .onAppear { reload() }
        .onChange(of: meeting) { _, _ in reload() }
        .onChange(of: state.speakersTick) { _, _ in reload() }
        .onChange(of: state.processingStage[meeting.id]) { _, stage in
            if stage == nil { reload() }
        }
        .onChange(of: state.topics) { _, _ in loadSuggestions() }
    }

    private func reload() {
        classification = Classifier.load(for: meeting)
        loadSuggestions()
    }

    /// Sugestões vêm do índice semântico; calculadas fora da main thread.
    private func loadSuggestions() {
        let (meeting, topics, meetings) = (meeting, state.topics, state.meetings)
        guard meeting.status == .ready, !topics.isEmpty, SemanticIndex.enabled else {
            suggestions = []
            return
        }
        Task.detached(priority: .utility) {
            let found = SemanticIndex.suggestedTopics(for: meeting, topics: topics, meetings: meetings)
                .prefix(2).map(\.topic)
            await MainActor.run {
                if self.meeting.id == meeting.id { suggestions = Array(found) }
            }
        }
    }

    /// Ferramentas e temas que ainda não são tags da reunião.
    private func suggestedTags(_ classification: MeetingClassification) -> [String] {
        let existing = Set(meeting.tags.map { $0.lowercased() })
        return (classification.ferramentas + classification.temas).filter { !existing.contains($0.lowercased()) }
    }

    private func chip(_ text: String, systemImage: String, tint: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.12), in: Capsule())
    }

    private func save(_ mutate: (inout MeetingClassification) -> Void) {
        guard var updated = classification else { return }
        mutate(&updated)
        updated.editada = true
        Classifier.save(updated, for: meeting)
        classification = updated
    }

    private func evidencePopover(_ classification: MeetingClassification) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Temperatura", selection: Binding(
                get: { classification.temperatura },
                set: { value in save { $0.temperatura = value } }
            )) {
                ForEach(MeetingClassification.Temperatura.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)

            if !classification.temperaturaMotivo.isEmpty {
                Text(classification.temperaturaMotivo)
                    .font(.callout)
            }
            if !classification.evidencias.isEmpty {
                Divider()
                ForEach(Array(classification.evidencias.enumerated()), id: \.offset) { _, evidence in
                    HStack(alignment: .top, spacing: 8) {
                        Text("[\(evidence.momento)]")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(SeedTheme.accent)
                        Text("“\(evidence.trecho)”")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text("Flags").font(.caption).foregroundStyle(.tertiary)
                ForEach(MeetingClassification.allowedFlags, id: \.self) { flag in
                    Toggle(MeetingClassification.flagLabel(flag), isOn: Binding(
                        get: { classification.flags.contains(flag) },
                        set: { on in
                            save { $0.flags = MeetingClassification.allowedFlags.filter { $0 == flag ? on : classification.flags.contains($0) } }
                        }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.callout)
                }
            }
            Divider()
            HStack {
                Text(classification.editada == true
                    ? "Corrigida à mão — não é sobrescrita automaticamente."
                    : "Vem só do texto: tom de voz e ironia se perdem.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Classificar de novo") {
                    showEvidence = false
                    state.reclassify(meeting)
                }
            }
        }
        .padding(16)
        .frame(width: 440)
    }
}
