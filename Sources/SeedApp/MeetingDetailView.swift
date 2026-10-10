import AppKit
import SeedKit
import SwiftUI

struct MeetingDetailView: View {
    @EnvironmentObject var state: AppState
    let meeting: Meeting

    @State private var tab: Tab = .summary
    @State private var editedTitle: String = ""
    @State private var notesText: String = ""
    @State private var summaryText: String?
    @State private var transcriptText: String?
    @State private var speakers: [MeetingSpeaker] = []
    @State private var renameTarget: MeetingSpeaker?
    @State private var customName: String = ""

    enum Tab: String, CaseIterable {
        case summary = "Resumo"
        case transcript = "Transcrição"
        case notes = "Minhas notas"
        case chat = "Chat"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 18)

            if meeting.status != .recording {
                speakersBar
                    .padding(.horizontal, 24)
                    .padding(.top, 10)

                MeetingInsightsBar(meeting: meeting)
                    .padding(.horizontal, 24)
                    .padding(.top, 8)

                HStack(spacing: 12) {
                    Picker("", selection: $tab) {
                        ForEach(Tab.allCases, id: \.self) { tab in
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 430)

                    Spacer()

                    Menu {
                        ForEach(SummaryTemplate.allCases, id: \.self) { template in
                            Button {
                                state.setTemplate(template, for: meeting)
                            } label: {
                                if meeting.summaryTemplate == template {
                                    Label(template.displayName, systemImage: "checkmark")
                                } else {
                                    Text(template.displayName)
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "doc.badge.gearshape")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Template do resumo (trocar refaz o resumo)")

                    Button {
                        showFollowUp = true
                    } label: {
                        Image(systemName: "paperplane")
                    }
                    .buttonStyle(.borderless)
                    .help("Gerar follow-up (rascunho de Slack para os participantes)")
                    .sheet(isPresented: $showFollowUp) {
                        TextResultSheet(
                            title: "Follow-up — \(meeting.title)",
                            subtitle: "Rascunho para colar no Slack · também salvo em followup.md",
                            generate: { [meeting, store = state.store] in
                                try FollowUp.generate(for: meeting, store: store)
                            },
                            isPresented: $showFollowUp
                        )
                    }

                    Button {
                        copySummary()
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copiar resumo")

                    Button {
                        state.resummarize(meeting)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refazer o resumo (usa as notas e nomes atuais)")

                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([meeting.folderURL])
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    .help("Mostrar no Finder")
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)

                Divider()
            }

            content

            if meeting.status == .ready {
                Divider()
                HStack(spacing: 16) {
                    Text("Resumo via \(providerName)")
                    Text("Transcrito no dispositivo · Parakeet v3")
                    Text("Áudio e dados 100% locais")
                    if meeting.refined == false {
                        Label("refinando transcript em 2º plano…", systemImage: "arrow.triangle.2.circlepath")
                            .foregroundStyle(SeedTheme.accent)
                    }
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 24)
                .padding(.vertical, 7)
            }
        }
        .onAppear { reload() }
        .onChange(of: meeting.id) { _, _ in
            tab = .summary
            reload()
        }
        .onChange(of: state.processingStage[meeting.id]) { _, stage in
            if stage == nil {
                speakers = Speakers.load(for: meeting)
                reloadTexts()
            }
        }
        .onChange(of: state.speakersTick) { _, _ in
            speakers = Speakers.load(for: meeting)
            reloadTexts()
        }
        .onChange(of: meeting) { _, _ in reloadTexts() }
        .onChange(of: state.notesTick) { _, _ in
            // nota por voz gravada em notas.md por fora do editor: recarrega
            // (só se mudou, para não resetar o cursor à toa)
            let fresh = state.store.readNotes(meeting) ?? ""
            if fresh != notesText { notesText = fresh }
        }
        .alert("Nomear falante", isPresented: showRenameAlert, presenting: renameTarget) { speaker in
            TextField("Nome", text: $customName)
            Button("Salvar") {
                state.renameSpeaker(meeting, cluster: speaker.cluster, to: customName)
                speakers = Speakers.load(for: meeting)
            }
            Button("Cancelar", role: .cancel) {}
        } message: { speaker in
            Text("O Seed vai memorizar esta voz — nas próximas reuniões, \(speaker.label == customName || customName.isEmpty ? "essa pessoa" : customName) será reconhecida sozinha.")
        }
    }

    private var showRenameAlert: Binding<Bool> {
        Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )
    }

    private func reload() {
        editedTitle = meeting.title
        notesText = state.store.readNotes(meeting) ?? ""
        speakers = Speakers.load(for: meeting)
        reloadTexts()
    }

    /// Resumo e transcript ficam em @State: lidos do disco dentro do body,
    /// eram relidos a cada re-render da janela.
    private func reloadTexts() {
        summaryText = state.store.readSummary(meeting)
        transcriptText = state.store.readTranscript(meeting)
    }

    private var providerName: String {
        switch SeedSettings.load().provider {
        case .claude: return "Claude (assinatura)"
        case .codex: return "Codex (ChatGPT)"
        case .antigravity: return "Antigravity (Google)"
        case .ollama: return "Ollama (local)"
        }
    }

    private func copySummary() {
        guard let summary = state.store.readSummary(meeting) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("# \(meeting.title)\n\n\(summary)", forType: .string)
    }

    // MARK: - Header

    @State private var showTagAlert = false
    @State private var newTagName = ""

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Título", text: $editedTitle)
                .textFieldStyle(.plain)
                .font(.title2.weight(.bold))
                .onSubmit { state.rename(meeting, to: editedTitle) }

            Text(dateLine)
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                // pasta
                Menu {
                    ForEach(state.allFolders, id: \.self) { folder in
                        Button(folder) { state.setFolder(folder, for: meeting) }
                    }
                    if meeting.folder != nil {
                        Divider()
                        Button("Remover da pasta") { state.setFolder(nil, for: meeting) }
                    }
                } label: {
                    Label(meeting.folder ?? "Sem pasta", systemImage: "folder")
                        .font(.caption)
                        .foregroundStyle(meeting.folder == nil ? .secondary : .primary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                // tags
                ForEach(meeting.tags, id: \.self) { tag in
                    Button {
                        state.removeTag(tag, from: meeting)
                    } label: {
                        Text("#\(tag)")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.14), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Clique para remover a tag")
                }
                Menu {
                    ForEach(state.allTags.filter { !meeting.tags.contains($0) }, id: \.self) { tag in
                        Button("#\(tag)") { state.addTag(tag, to: meeting) }
                    }
                    if !state.allTags.isEmpty { Divider() }
                    Button("Nova tag…") { showTagAlert = true }
                } label: {
                    Image(systemName: "tag")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Adicionar tag")
                Spacer()
            }
            .padding(.top, 2)
        }
        .alert("Nova tag", isPresented: $showTagAlert) {
            TextField("ex.: operações, tech, ba…", text: $newTagName)
            Button("Adicionar") {
                state.addTag(newTagName, to: meeting)
                newTagName = ""
            }
            Button("Cancelar", role: .cancel) { newTagName = "" }
        }
    }

    private var dateLine: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.dateFormat = "EEEE, d 'de' MMMM · HH:mm"
        var text = formatter.string(from: meeting.startedAt).capitalized
        if meeting.durationSeconds > 0 {
            text += " · \(max(1, Int(meeting.durationSeconds / 60))) min"
        }
        return text
    }

    // MARK: - Quem é quem

    @State private var showWhoIsWho = false
    @State private var showFollowUp = false

    @ViewBuilder
    private var speakersBar: some View {
        if !speakers.isEmpty {
            // scroll horizontal obrigatório: com ~20 falantes o HStack puro
            // explodia a largura intrínseca da janela e "quebrava" o layout
            // (conteúdo centrado empurrado para fora da tela)
            ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Button {
                    showWhoIsWho = true
                } label: {
                    Image(systemName: "person.2.badge.gearshape")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Quem é quem nesta reunião?")
                .sheet(isPresented: $showWhoIsWho, onDismiss: { speakers = Speakers.load(for: meeting) }) {
                    WhoIsWhoSheet(meeting: meeting, isPresented: $showWhoIsWho)
                        .environmentObject(state)
                }
                chip(label: "Você", confirmed: true)
                ForEach(speakers) { speaker in
                    Menu {
                        ForEach(speaker.suggestions, id: \.name) { suggestion in
                            Button("\(suggestion.name) · \(Int(suggestion.score * 100))% de certeza") {
                                state.renameSpeaker(meeting, cluster: speaker.cluster, to: suggestion.name)
                                speakers = Speakers.load(for: meeting)
                            }
                        }
                        if !speaker.suggestions.isEmpty { Divider() }
                        Button("Nomear…") {
                            customName = speaker.label.hasPrefix("Falante") ? "" : speaker.label
                            renameTarget = speaker
                        }
                    } label: {
                        chip(label: chipLabel(for: speaker), confirmed: speaker.confirmed)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            .font(.caption)
            }
        }
    }

    /// Rótulo do chip: nome auto-identificado por voz (não confirmado) mostra
    /// o índice de confiança — "Pessoa A · 74%" avisa que vale conferir.
    private func chipLabel(for speaker: MeetingSpeaker) -> String {
        guard !speaker.confirmed,
              let best = speaker.suggestions.first,
              speaker.label == best.name
        else { return speaker.label }
        return "\(speaker.label) · \(Int(best.score * 100))%"
    }

    private func chip(label: String, confirmed: Bool) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(confirmed ? Color.accentColor : Color.secondary.opacity(0.5))
                .frame(width: 6, height: 6)
            Text(label)
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.12), in: Capsule())
    }

    // MARK: - Conteúdo

    @ViewBuilder
    private var content: some View {
        if meeting.status == .recording {
            recordingView
        } else if let stage = state.processingStage[meeting.id] ?? processingFallback {
            VStack(spacing: 12) {
                ProgressView()
                Text(stage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if meeting.status == .failed {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                Text("O processamento falhou")
                    .font(.headline)
                if let message = meeting.errorMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 420)
                        .lineLimit(6)
                }
                Button("Tentar de novo") { state.process(meeting) }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch tab {
            case .notes:
                notesEditor(hint: "Suas notas entram no próximo resumo — use ↻ para refazê-lo.")
            case .chat:
                ChatTab(meeting: meeting)
            case .summary, .transcript:
                ScrollView {
                    MarkdownLite(text: bodyText)
                        .padding(24)
                        .frame(maxWidth: 700, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Durante a gravação (mockup 2): medidores + notas à esquerda,
    /// transcrição ao vivo à direita.
    private var recordingView: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let session = state.session, session.meeting.id == meeting.id {
                TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                    HStack(spacing: 18) {
                        HStack(spacing: 8) {
                            Circle().fill(.red).frame(width: 9, height: 9)
                            Text(timeString(session.elapsedSeconds))
                                .font(.headline.monospacedDigit())
                        }
                        LevelRow(label: "Você", level: session.micLevel).frame(width: 150)
                        LevelRow(label: "Outros", level: session.systemLevel).frame(width: 150)
                        Spacer()
                        Button {
                            state.stopRecording()
                        } label: {
                            Label("Parar e resumir", systemImage: "stop.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                Divider()
            }

            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    paneHeader("Minhas notas")
                    TextEditor(text: $notesText)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 16)
                        .onChange(of: notesText) { _, newValue in
                            state.store.writeNotes(newValue, for: meeting)
                        }
                }
                .frame(maxWidth: .infinity)

                Divider()

                VStack(alignment: .leading, spacing: 0) {
                    livePaneHeader
                    if livePane == .chat {
                        ChatTab(meeting: meeting)
                    } else {
                        liveTranscriptPane
                    }
                }
                .frame(maxWidth: .infinity)
            }

            Divider()
            Text("Ao parar, o Seed mescla suas notas com a transcrição e gera o resumo. O áudio é transcrito no seu Mac.")
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
        }
    }

    /// Pane direito da gravação: "Ao vivo" (transcrição) ou "Chat" (perguntas
    /// sobre a reunião em andamento — "o que eu perdi?").
    private enum LivePane { case transcript, chat }
    @State private var livePane: LivePane = .transcript

    private var livePaneHeader: some View {
        HStack(spacing: 8) {
            Picker("", selection: $livePane) {
                Text("Ao vivo").tag(LivePane.transcript)
                Text("Chat").tag(LivePane.chat)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 170)
            if livePane == .transcript {
                Text("pt-BR · no dispositivo")
                    .font(.caption2)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private var liveTranscriptPane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if state.liveLines.isEmpty {
                        Text("As falas aparecem aqui em blocos, alguns segundos depois de ditas…")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    ForEach(Array(state.liveLines.enumerated()), id: \.offset) { index, line in
                        Text(inlineMarkdown(line))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .id(index)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: state.liveLines.count) { _, count in
                if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
            }
        }
    }

    private func paneHeader(_ title: String, pill: String? = nil) -> some View {
        HStack(spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .kerning(0.8)
            if let pill {
                Text(pill)
                    .font(.caption2)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func inlineMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }

    private func notesEditor(hint: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            TextEditor(text: $notesText)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(20)
                .onChange(of: notesText) { _, newValue in
                    state.store.writeNotes(newValue, for: meeting)
                }
            Divider()
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
        }
    }

    private var processingFallback: String? {
        meeting.status == .processing ? "Processando…" : nil
    }

    private var bodyText: String {
        switch tab {
        case .summary:
            return summaryText ?? "Resumo ainda não disponível."
        case .transcript:
            return transcriptText ?? "Transcrição ainda não disponível."
        case .notes:
            return notesText
        case .chat:
            return ""
        }
    }
}
