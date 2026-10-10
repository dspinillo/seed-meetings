import SeedKit
import ServiceManagement
import SwiftUI

/// Preferências no padrão do mockup 5: navegação lateral + linhas com o
/// controle à direita, aberta dentro da janela principal.
struct PreferencesView: View {
    @EnvironmentObject var state: AppState
    @State private var settings = SeedSettings.load()
    @State private var statuses: [LLMProviderStatus] = []
    @State private var checking = false
    @State private var section: PrefSection = .geral
    @State private var storageUsed = "…"
    @State private var diagnostics: MeetingDetector.Diagnostics?
    @State private var diagnosing = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var glossaryRows: [GlossaryRow] = []
    @State private var micDevices: [AudioInputDevice] = []

    enum PrefSection: String, CaseIterable, Identifiable {
        case geral = "Geral"
        case transcricao = "Transcrição"
        case resumos = "Resumos"
        case deteccao = "Detecção"
        case privacidade = "Privacidade"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Preferências")
                    .font(.title2.weight(.bold))
                Spacer()
                Button("Concluído") { state.showPreferences = false }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)

            Divider()

            HStack(spacing: 0) {
                List(selection: $section) {
                    ForEach(PrefSection.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .background(SeedTheme.panelBG)
                .frame(width: 170)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        sectionContent
                    }
                    .padding(24)
                    .frame(maxWidth: 640, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(SeedTheme.windowBG)
            }
        }
        .background(SeedTheme.windowBG)
        .onAppear {
            loadStatuses()
            computeStorage()
        }
        .onChange(of: settings.provider) { _, _ in settings.save() }
        .onChange(of: settings.ollamaModel) { _, _ in settings.save() }
        .onChange(of: settings.defaultTemplate) { _, _ in settings.save() }
        .onChange(of: settings.detectMeet) { _, _ in settings.save() }
        .onChange(of: settings.detectTeams) { _, _ in settings.save() }
        .onChange(of: settings.autoStop) { _, _ in settings.save() }
        .onChange(of: settings.retentionDays) { _, _ in settings.save() }
        .onChange(of: settings.refineProvider) { _, _ in settings.save() }
        .onChange(of: settings.codexModel) { _, _ in settings.save() }
        .onChange(of: settings.claudeModel) { _, _ in settings.save() }
        .onChange(of: settings.micDeviceUID) { _, _ in settings.save() }
        .onChange(of: settings.voiceNoteHotkey) { _, _ in
            settings.save()
            HotkeyManager.shared.apply(settings) // re-registro explícito
        }
        .onChange(of: settings.voiceNoteMode) { _, _ in settings.save() }
        .onChange(of: launchAtLogin) { _, enabled in
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch section {
        case .geral:
            row("Abrir no login", "O Seed precisa estar aberto para detectar suas reuniões") {
                Toggle("", isOn: $launchAtLogin).labelsHidden()
            }
            row("Modelo de transcrição", "Roda 100% no dispositivo (Neural Engine)") {
                valueChip("Parakeet v3 — recomendado, pt-BR")
            }
            row("Idioma das reuniões", "Usado pela transcrição e pelos resumos") {
                valueChip("Português (Brasil)")
            }
            row("Resumos e chat via", currentProviderDetail) {
                Picker("", selection: $settings.provider) {
                    ForEach(LLMProviderID.allCases, id: \.self) { provider in
                        Text(shortName(provider)).tag(provider)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            row("Template de resumo", "Padrão para novas reuniões") {
                Picker("", selection: $settings.defaultTemplate) {
                    ForEach(SummaryTemplate.allCases, id: \.rawValue) { template in
                        Text(template.displayName).tag(template.rawValue)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            row("Detecção de reunião", "Apps monitorados para sugerir gravação") {
                valueChip(detectionSummary)
            }
            row("Nota por voz (atalho global)", "Mute o mic na call, use o atalho e fale — vira nota da reunião (ou nota avulsa, sem reunião)") {
                Picker("", selection: $settings.voiceNoteHotkey) {
                    ForEach(HotkeyPreset.allCases) { preset in
                        Text(preset.display).tag(preset.rawValue)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            row("Modo do atalho", "Segurar para falar (solta = salva) ou apertar para começar/terminar") {
                Picker("", selection: $settings.voiceNoteMode) {
                    Text("Segurar").tag("hold")
                    Text("Apertar 2×").tag("toggle")
                }
                .labelsHidden()
                .fixedSize()
            }
            row("Armazenamento", "~/Library/Application Support/Seed · transcrições e resumos ficam para sempre", last: true) {
                valueChip(storageUsed)
            }
        case .transcricao:
            row("Microfone", "O macOS troca o mic padrão sozinho quando fones conectam; fixe aqui o que você usa — o Seed grava dele e volta pra ele se cair no meio da reunião") {
                Picker("", selection: $settings.micDeviceUID) {
                    Text("Padrão do sistema").tag("default")
                    ForEach(micDevices) { device in
                        Text(device.name).tag(device.uid)
                    }
                    if settings.micDeviceUID != "default",
                       !micDevices.contains(where: { $0.uid == settings.micDeviceUID }) {
                        Text("Mic salvo (desconectado)").tag(settings.micDeviceUID)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .onAppear { micDevices = AudioInputDevices.list() }
            }
            row("Modelo", "Parakeet TDT v3 via FluidAudio — transcrição no dispositivo") {
                valueChip("Parakeet v3")
            }
            row("Idioma", "Detecção automática entre os 25 idiomas do modelo") {
                valueChip("Português (Brasil)")
            }
            row("Privacidade do áudio", "O áudio nunca sai do Mac; a transcrição roda no Neural Engine", last: true) {
                Image(systemName: "lock.fill").foregroundStyle(.secondary)
            }
            glossarySection
        case .resumos:
            row("Gerar com", "A escolha vale para resumos e para o chat") {
                Picker("", selection: $settings.provider) {
                    ForEach(LLMProviderID.allCases, id: \.self) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            ForEach(statuses) { status in
                row(shortName(status.id), status.detail) {
                    Image(systemName: status.available ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(status.available ? Color.green : Color.secondary)
                }
            }
            if settings.provider == .ollama {
                row("Modelo do Ollama", "ex.: qwen3, glm-4.7, llama3.3 — ou um modelo cloud da sua conta") {
                    TextField("modelo", text: $settings.ollamaModel)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                }
            }
            if settings.provider == .claude || settings.refineProvider == LLMProviderID.claude.rawValue {
                row("Modelo do Claude", "Vale para resumos e chat. A disponibilidade depende da sua conta.") {
                    Picker("", selection: $settings.claudeModel) {
                        Text("Sonnet").tag("sonnet")
                        Text("Opus").tag("opus")
                        Text("Haiku").tag("haiku")
                        Text("Padrão da conta").tag("default")
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            if settings.provider == .codex || settings.refineProvider == LLMProviderID.codex.rawValue {
                row("Modelo do Codex", "Vale para resumos e chat. A disponibilidade depende da sua conta e versão do CLI.") {
                    Picker("Modelo do Codex", selection: $settings.codexModel) {
                        Text("Padrão do CLI").tag("default")
                        Text("GPT-5.6 Sol").tag("gpt-5.6-sol")
                        Text("GPT-5.6 Luna (Lua)").tag("gpt-5.6-luna")
                        Text("GPT-5.6 Terra").tag("gpt-5.6-terra")
                        Text("GPT-6 Astra").tag("gpt-6-astra")
                        if !["default", "gpt-5.6-sol", "gpt-5.6-luna", "gpt-5.6-terra", "gpt-6-astra"].contains(settings.codexModel) {
                            Text(settings.codexModel).tag(settings.codexModel)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            row("Refino em 2º plano re-resume com", "O resumo rápido sai na hora; o refinado pode usar outra IA (ou ser pulado) para poupar seu limite") {
                Picker("", selection: $settings.refineProvider) {
                    Text("Mesma IA").tag("same")
                    ForEach(LLMProviderID.allCases, id: \.self) { provider in
                        Text(shortName(provider)).tag(provider.rawValue)
                    }
                    Text("Não refazer o resumo").tag("skip")
                }
                .labelsHidden()
                .fixedSize()
            }
            row("Template padrão", "Novas reuniões nascem com este formato", last: true) {
                Picker("", selection: $settings.defaultTemplate) {
                    ForEach(SummaryTemplate.allCases, id: \.rawValue) { template in
                        Text(template.displayName).tag(template.rawValue)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            Button(checking ? "Verificando…" : "Verificar IAs de novo") { loadStatuses() }
                .disabled(checking)
                .padding(.top, 12)
        case .deteccao:
            row("Google Meet", "Aba do meet.google.com no Chrome + microfone em uso") {
                Toggle("", isOn: $settings.detectMeet).labelsHidden()
            }
            row("Microsoft Teams", "App do Teams aberto + microfone em uso") {
                Toggle("", isOn: $settings.detectTeams).labelsHidden()
            }
            row("Auto-stop", "Encerra sozinho quando a aba fecha ou o silêncio passa de ~2,5 min") {
                Toggle("", isOn: $settings.autoStop).labelsHidden()
            }
            row("Manter áudio bruto por", "Áudio .caf e .wav expira; os textos são preservados", last: true) {
                Picker("", selection: $settings.retentionDays) {
                    Text("7 dias").tag(7)
                    Text("30 dias").tag(30)
                    Text("90 dias").tag(90)
                    Text("Para sempre").tag(36500)
                }
                .labelsHidden()
                .fixedSize()
            }
            Text("A detecção nunca grava sozinha — sempre pergunta. A 1ª detecção do Meet pede permissão de Automação para o Chrome.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 12)

            Button(diagnosing ? "Testando…" : "Testar detecção agora") { runDiagnostics() }
                .disabled(diagnosing)
                .padding(.top, 8)

            if let diag = diagnostics {
                VStack(alignment: .leading, spacing: 6) {
                    diagLine(diag.chromeRunning, "Chrome aberto")
                    diagLine(diag.meetingTab != nil, diag.meetingTab.map { "Aba de reunião: \($0)" } ?? "Nenhuma aba de reunião (Meet/Teams) encontrada")
                    if let issue = diag.tabIssue {
                        diagLine(false, issue)
                    }
                    diagLine(diag.teamsAppRunning, "App do Teams aberto")
                    diagLine(diag.micInUse, "Microfone em uso (entre na sala com o mic ativo)")
                    Divider().padding(.vertical, 2)
                    diagLine(diag.result != nil, diag.result.map { "DETECTARIA: \($0.title) — \($0.source.rawValue)" } ?? "Nada seria detectado agora")
                }
                .font(.caption)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(SeedTheme.cardBG, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SeedTheme.border))
                .padding(.top, 8)
            }
        case .privacidade:
            row("Áudio", "Nunca sai do Mac — captura e transcrição são 100% locais") {
                Image(systemName: "lock.fill").foregroundStyle(.secondary)
            }
            row("Texto", "Transcrição, notas, glossário e contexto do chat vão ao motor escolhido. Modelos locais do Ollama processam no Mac.") {
                Image(systemName: "lock.fill").foregroundStyle(.secondary)
            }
            row("Credenciais", "O Seed não guarda chave nenhuma — usa o login que você já fez no CLI oficial de cada IA", last: true) {
                Image(systemName: "key.slash").foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Dicionário particular (glossário)

    private struct GlossaryRow: Identifiable, Equatable {
        let id = UUID()
        var certo: String
        var variantes: String  // separadas por vírgula, como o usuário digita
        var nota: String
    }

    private var glossarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Dicionário particular")
                .font(.body.weight(.semibold))
            Text("Nomes e sistemas que o ASR erra. As variantes são trocadas pela grafia certa no transcript, e a IA recebe o glossário ao resumir e conversar.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach($glossaryRows) { $row in
                HStack(spacing: 8) {
                    TextField("Grafia certa", text: $row.certo)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                    TextField("variantes que o ASR ouve, separadas por vírgula", text: $row.variantes)
                        .textFieldStyle(.roundedBorder)
                    TextField("nota (ex.: PESSOA)", text: $row.nota)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                    Button {
                        glossaryRows.removeAll { $0.id == row.id }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Remover termo")
                }
            }

            Button("Adicionar termo") {
                glossaryRows.append(GlossaryRow(certo: "", variantes: "", nota: ""))
            }
            .padding(.top, 2)
        }
        .padding(.top, 20)
        .onAppear { loadGlossary() }
        .onChange(of: glossaryRows) { _, _ in saveGlossary() }
    }

    private func loadGlossary() {
        guard glossaryRows.isEmpty else { return }
        glossaryRows = Glossary.load().map {
            GlossaryRow(certo: $0.certo, variantes: $0.variantes.joined(separator: ", "), nota: $0.nota ?? "")
        }
    }

    private func saveGlossary() {
        let entries = glossaryRows.compactMap { row -> GlossaryEntry? in
            let certo = row.certo.trimmingCharacters(in: .whitespaces)
            guard !certo.isEmpty else { return nil }
            let variantes = row.variantes
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let nota = row.nota.trimmingCharacters(in: .whitespaces)
            return GlossaryEntry(certo: certo, variantes: variantes, nota: nota.isEmpty ? nil : nota)
        }
        Glossary.save(entries)
    }

    // MARK: - Componentes no padrão do mockup

    private func row(
        _ title: String,
        _ description: String,
        last: Bool = false,
        @ViewBuilder control: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.semibold))
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                control()
            }
            .padding(.vertical, 12)
            if !last { Divider() }
        }
    }

    private func valueChip(_ text: String) -> some View {
        Text(text)
            .font(.callout.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(SeedTheme.cardBG, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SeedTheme.border))
    }

    private func shortName(_ provider: LLMProviderID) -> String {
        switch provider {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .antigravity: return "Antigravity"
        case .ollama: return "Ollama"
        }
    }

    private var currentProviderDetail: String {
        statuses.first { $0.id == settings.provider }.map(\.detail)
            ?? "Usa o CLI que você já tem logado"
    }

    private var detectionSummary: String {
        var parts: [String] = []
        if settings.detectMeet { parts.append("Meet (Chrome)") }
        if settings.detectTeams { parts.append("Teams") }
        return parts.isEmpty ? "Desligada" : parts.joined(separator: " + ")
    }

    private func diagLine(_ ok: Bool, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(ok ? Color.green : Color.secondary)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func runDiagnostics() {
        diagnosing = true
        let meet = settings.detectMeet
        let teams = settings.detectTeams
        Task.detached {
            let result = MeetingDetector.diagnose(meetEnabled: meet, teamsEnabled: teams)
            await MainActor.run {
                diagnostics = result
                diagnosing = false
            }
        }
    }

    private func loadStatuses() {
        checking = true
        Task.detached {
            let result = LLM.statuses()
            await MainActor.run {
                statuses = result
                checking = false
            }
        }
    }

    private func computeStorage() {
        Task.detached {
            let root = SeedPaths.dataDirectory
            var total: Int64 = 0
            if let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]
            ) {
                for case let url as URL in enumerator {
                    total += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?
                        .totalFileAllocatedSize ?? 0)
                }
            }
            let text = ByteCountFormatter.string(fromByteCount: total, countStyle: .file) + " usados"
            await MainActor.run { storageUsed = text }
        }
    }
}
