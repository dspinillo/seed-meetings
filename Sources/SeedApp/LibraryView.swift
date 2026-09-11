import SeedKit
import SwiftUI

struct LibraryView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ZStack {
            splitView
            if state.showPreferences {
                PreferencesView()
                    .background(SeedTheme.windowBG)
            }
        }
        .tint(SeedTheme.accent)
        .background(LibraryWindowPlacement())
    }

    private var splitView: some View {
        NavigationSplitView {
            List(selection: $state.selectedMeetingID) {
                if !state.allFolders.isEmpty {
                    Picker("Pasta", selection: $state.folderFilter) {
                        Text("Todas as reuniões").tag(String?.none)
                        ForEach(state.allFolders, id: \.self) { folder in
                            Label(folder, systemImage: "folder").tag(String?.some(folder))
                        }
                        Text("Sem pasta").tag(String?.some(""))
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
                ForEach(daySections, id: \.title) { section in
                    Section(section.title) {
                        ForEach(section.meetings) { meeting in
                            MeetingRow(meeting: meeting)
                                .tag(meeting.id)
                                .contextMenu {
                                    folderMenu(for: meeting)
                                    if meeting.status == .failed || meeting.status == .ready {
                                        Button("Reprocessar") { state.process(meeting) }
                                    }
                                    Button("Apagar", role: .destructive) { state.delete(meeting) }
                                }
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            .searchable(text: $state.searchText, placement: .sidebar, prompt: "Buscar reuniões")
            .overlay {
                if state.meetings.isEmpty {
                    ContentUnavailableView(
                        "Nenhuma reunião",
                        systemImage: "leaf",
                        description: Text("Clique em Gravar para capturar a primeira.")
                    )
                }
            }
        } detail: {
            Group {
                if let meeting = state.meeting(id: state.selectedMeetingID) {
                    MeetingDetailView(meeting: meeting)
                } else {
                    ContentUnavailableView(
                        "Selecione uma reunião",
                        systemImage: "sidebar.left",
                        description: Text("Ou grave uma nova pela barra de menu 🌱")
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SeedTheme.windowBG)
        }
        .navigationTitle("Seed")
        .alert("Nova pasta", isPresented: $showNewFolderAlert) {
            TextField("Nome da pasta", text: $newFolderName)
            Button("Criar") {
                if let meeting = newFolderTarget {
                    state.setFolder(newFolderName, for: meeting)
                }
                newFolderName = ""
            }
            Button("Cancelar", role: .cancel) { newFolderName = "" }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    showActionItems = true
                } label: {
                    Image(systemName: "checklist")
                }
                .help("Meus action items da semana (todas as reuniões)")
                .sheet(isPresented: $showActionItems) {
                    TextResultSheet(
                        title: "Meus action items",
                        subtitle: "Consolidado das reuniões dos últimos 7 dias, só o que ficou com você",
                        generate: { [store = state.store] in
                            try FollowUp.myActionItems(store: store, days: 7)
                        },
                        isPresented: $showActionItems
                    )
                }
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    state.showPreferences.toggle()
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Preferências do Seed")
            }
            ToolbarItem(placement: .primaryAction) {
                if state.isRecording {
                    Button {
                        state.stopRecording()
                    } label: {
                        Label("Parar", systemImage: "stop.circle.fill")
                    }
                    .tint(.red)
                    .help("Parar a gravação e gerar o resumo")
                } else {
                    Button {
                        state.startRecording()
                    } label: {
                        Label("Gravar", systemImage: "record.circle")
                    }
                    .help("Gravar uma reunião agora")
                }
            }
        }
    }

    @State private var showNewFolderAlert = false
    @State private var newFolderName = ""
    @State private var newFolderTarget: Meeting?
    @State private var showActionItems = false

    @ViewBuilder
    private func folderMenu(for meeting: Meeting) -> some View {
        Menu("Mover para pasta") {
            ForEach(state.allFolders, id: \.self) { folder in
                Button {
                    state.setFolder(folder, for: meeting)
                } label: {
                    if meeting.folder == folder {
                        Label(folder, systemImage: "checkmark")
                    } else {
                        Text(folder)
                    }
                }
            }
            if !state.allFolders.isEmpty { Divider() }
            Button("Nova pasta…") {
                newFolderTarget = meeting
                showNewFolderAlert = true
            }
            if meeting.folder != nil {
                Divider()
                Button("Remover da pasta") { state.setFolder(nil, for: meeting) }
            }
        }
    }

    private struct DaySection {
        let title: String
        let meetings: [Meeting]
    }

    private var daySections: [DaySection] {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.dateFormat = "EEEE, d 'de' MMMM"

        var sections: [DaySection] = []
        for meeting in state.filteredMeetings {
            let title: String
            if calendar.isDateInToday(meeting.startedAt) {
                title = "Hoje"
            } else if calendar.isDateInYesterday(meeting.startedAt) {
                title = "Ontem"
            } else {
                title = formatter.string(from: meeting.startedAt).capitalized
            }
            if let index = sections.firstIndex(where: { $0.title == title }) {
                sections[index] = DaySection(title: title, meetings: sections[index].meetings + [meeting])
            } else {
                sections.append(DaySection(title: title, meetings: [meeting]))
            }
        }
        return sections
    }
}

struct MeetingRow: View {
    @EnvironmentObject var state: AppState
    let meeting: Meeting

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            trailing
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        var text = formatter.string(from: meeting.startedAt)
        if meeting.durationSeconds > 0 {
            text += " · \(max(1, Int(meeting.durationSeconds / 60))) min"
        }
        if let folder = meeting.folder {
            text += " · 📁 \(folder)"
        }
        if !meeting.tags.isEmpty {
            text += " · " + meeting.tags.map { "#\($0)" }.joined(separator: " ")
        }
        return text
    }

    @ViewBuilder
    private var trailing: some View {
        if let stage = state.processingStage[meeting.id] {
            ProgressView().controlSize(.small).help(stage)
        } else {
            switch meeting.status {
            case .recording:
                Circle().fill(.red).frame(width: 8, height: 8)
            case .processing:
                ProgressView().controlSize(.small)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            case .ready:
                EmptyView()
            }
        }
    }
}
