import AVFoundation
import SeedKit
import SwiftUI

/// Toca um trecho curto do áudio gravado — ajuda a reconhecer de quem é a voz.
@MainActor
final class SnippetPlayer: ObservableObject {
    @Published var playingKey: String?
    private var player: AVAudioPlayer?
    private var stopTask: Task<Void, Never>?

    func toggle(key: String, url: URL, start: Double, duration: Double) {
        if playingKey == key {
            stop()
            return
        }
        stop()
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        self.player = player
        player.currentTime = start
        player.play()
        playingKey = key
        stopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            if !Task.isCancelled { self?.stop() }
        }
    }

    func stop() {
        stopTask?.cancel()
        stopTask = nil
        player?.stop()
        player = nil
        playingKey = nil
    }
}

/// A tela "Quem é quem nesta reunião?" do mockup 4: uma linha por voz, com
/// contagem de falas, origem da sugestão e confirmação em 1 clique.
struct WhoIsWhoSheet: View {
    @EnvironmentObject var state: AppState
    let meeting: Meeting
    @Binding var isPresented: Bool

    /// Trecho representativo de uma voz (a fala mais longa dela na reunião).
    private struct Snippet {
        let start: Double
        let duration: Double
    }

    @State private var speakers: [MeetingSpeaker] = []
    @State private var counts: [String: Int] = [:]
    @State private var micCount = 0
    @State private var renameTarget: MeetingSpeaker?
    @State private var customName = ""
    @State private var renamedAny = false
    @State private var snippets: [String: [Snippet]] = [:]
    @State private var snippetIndex: [String: Int] = [:]
    @StateObject private var snippet = SnippetPlayer()

    private let avatarColors: [Color] = [
        Color(red: 0.43, green: 0.50, blue: 0.62),
        Color(red: 0.62, green: 0.50, blue: 0.43),
        Color(red: 0.50, green: 0.43, blue: 0.62),
        Color(red: 0.62, green: 0.43, blue: 0.50),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Quem é quem nesta reunião?")
                    .font(.title3.weight(.bold))
                Text("\(speakers.count + 1) voz(es) detectadas · sugestões vêm de vozes já conhecidas e de nomes citados na conversa")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(spacing: 0) {
                    speakerRow(
                        avatar: avatar(initials: "DS", color: SeedTheme.accent),
                        title: "Você",
                        caption: "trilha do microfone" + (micCount > 0 ? " · \(micCount) falas" : ""),
                        snippetKey: "mic"
                    ) {
                        Label("automático", systemImage: "checkmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(SeedTheme.accent)
                    }
                    ForEach(Array(speakers.enumerated()), id: \.element.id) { index, speaker in
                        Divider().padding(.leading, 20)
                        speakerRow(
                            avatar: avatar(
                                initials: speaker.confirmed ? initials(of: speaker.label) : "?",
                                color: avatarColors[index % avatarColors.count]
                            ),
                            title: speaker.label,
                            caption: caption(for: speaker),
                            snippetKey: speaker.cluster
                        ) {
                            trailing(for: speaker)
                        }
                    }
                }
            }

            Divider()

            HStack {
                Text(renamedAny
                    ? "Nomes aplicados no transcript e no resumo, sem gastar tokens."
                    : "Confirmar um nome ensina a voz — nas próximas reuniões o Seed reconhece sozinho.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                if renamedAny {
                    Button("Refazer resumo") {
                        state.resummarize(meeting)
                        isPresented = false
                    }
                    .help("Opcional: regenera o resumo com o modelo já sabendo os nomes (1 chamada).")
                }
                Button("Concluído") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 640)
        .frame(minHeight: 260, maxHeight: 460)
        .background(SeedTheme.windowBG)
        .tint(SeedTheme.accent)
        .onAppear { load() }
        .onDisappear { snippet.stop() }
        .alert("Nomear falante", isPresented: showRenameAlert, presenting: renameTarget) { speaker in
            TextField("Nome", text: $customName)
            Button("Salvar") { confirm(speaker, as: customName) }
            Button("Cancelar", role: .cancel) {}
        } message: { _ in
            Text("O Seed vai memorizar esta voz para as próximas reuniões.")
        }
    }

    // MARK: - Linhas

    private func speakerRow(
        avatar: some View,
        title: String,
        caption: String,
        snippetKey: String? = nil,
        @ViewBuilder trailing: () -> some View
    ) -> some View {
        HStack(spacing: 12) {
            avatar
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let key = snippetKey, let list = snippets[key], !list.isEmpty, let url = audioURL(for: key) {
                Button {
                    if snippet.playingKey == key {
                        snippet.stop()
                    } else {
                        let index = snippetIndex[key, default: 0]
                        let info = list[index % list.count]
                        snippetIndex[key] = index + 1
                        snippet.toggle(key: key, url: url, start: info.start, duration: info.duration)
                    }
                } label: {
                    Image(systemName: snippet.playingKey == key ? "stop.circle.fill" : "play.circle")
                        .font(.system(size: 15))
                        .foregroundStyle(snippet.playingKey == key ? SeedTheme.accent : Color.secondary)
                }
                .buttonStyle(.plain)
                .help("Ouvir esta voz — cada clique toca um trecho diferente (\(list.count) amostras)")
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func trailing(for speaker: MeetingSpeaker) -> some View {
        HStack(spacing: 10) {
            if speaker.confirmed {
                Label("confirmado", systemImage: "checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SeedTheme.accent)
                    .fixedSize()
            } else if let best = speaker.suggestions.first {
                Text("\(best.name) · \(Int(best.score * 100))%")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(SeedTheme.accentSoft, in: Capsule())
                    .overlay(Capsule().strokeBorder(SeedTheme.accent.opacity(0.5)))
            }
            Menu {
                if !speaker.confirmed, let best = speaker.suggestions.first {
                    Button("✓ Confirmar \(best.name)") { confirm(speaker, as: best.name) }
                    Divider()
                }
                ForEach(nameIdeas(excluding: speaker), id: \.self) { name in
                    Button("É \(name)") { confirm(speaker, as: name) }
                }
                Button("Nomear outra pessoa…") {
                    customName = ""
                    renameTarget = speaker
                }
                if speaker.confirmed {
                    Button("Desfazer nome (voltar a Falante \(speaker.cluster))") {
                        state.unnameSpeaker(meeting, cluster: speaker.cluster)
                        renamedAny = true
                        load()
                    }
                }
                if speakers.count > 1 {
                    Divider()
                    Section("Mesclar: as falas passam para…") {
                        ForEach(speakers.filter { $0.cluster != speaker.cluster }) { other in
                            Button("É a mesma pessoa que \(other.label)") {
                                merge(speaker, into: other)
                            }
                        }
                    }
                }
            } label: {
                Text(speaker.confirmed ? "Corrigir" : "Identificar")
                    .font(.caption.weight(.semibold))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private func avatar(initials: String, color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 26, height: 26)
            .overlay(
                Text(initials)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
            )
    }

    // MARK: - Dados

    private func caption(for speaker: MeetingSpeaker) -> String {
        let falas = counts[speaker.cluster].map { "\($0) falas" } ?? ""
        let origem: String
        if speaker.confirmed {
            origem = "nome confirmado"
        } else if speaker.suggestions.isEmpty {
            origem = "voz nova"
        } else {
            origem = "voz reconhecida de reuniões anteriores"
        }
        return falas.isEmpty ? origem : "\(falas) · \(origem)"
    }

    /// Vozes sem sugestão ganham como atalho os nomes já conhecidos da memória.
    private func nameIdeas(excluding speaker: MeetingSpeaker) -> [String] {
        let taken = Set(speakers.filter(\.confirmed).map(\.label))
        return state.store.voiceprints.all()
            .map(\.name)
            .filter { !taken.contains($0) }
            .prefix(2)
            .map { $0 }
    }

    private func initials(of name: String) -> String {
        let parts = name.split(separator: " ")
        let first = parts.first?.prefix(1) ?? "?"
        let last = parts.count > 1 ? (parts.last?.prefix(1) ?? "") : ""
        return String(first + last).uppercased()
    }

    private func confirm(_ speaker: MeetingSpeaker, as name: String) {
        state.renameSpeaker(meeting, cluster: speaker.cluster, to: name)
        renamedAny = true
        load()
    }

    private func merge(_ speaker: MeetingSpeaker, into other: MeetingSpeaker) {
        state.mergeSpeakers(meeting, cluster: speaker.cluster, into: other.cluster)
        renamedAny = true
        load()
    }

    private func load() {
        speakers = Speakers.load(for: meeting)
        counts = [:]
        micCount = 0
        snippets = [:]
        var longest: [String: Double] = [:]
        let segmentsURL = meeting.folderURL.appendingPathComponent("segments.json")
        if let data = try? Data(contentsOf: segmentsURL),
           let utterances = try? JSONDecoder().decode([Utterance].self, from: data) {
            micCount = utterances.filter { $0.track == "mic" }.count
            for utterance in utterances where utterance.track == "system" {
                if let cluster = utterance.cluster {
                    counts[cluster, default: 0] += 1
                }
            }
            // trechos representativos por voz: falas CURTAS (2,5–8s ≈ um só
            // falante; as longas são conversa cruzada e enganam o ouvido),
            // espalhadas pela reunião — cada clique no ▶ toca a próxima
            var candidates: [String: [Utterance]] = [:]
            for utterance in utterances {
                guard let key = utterance.track == "mic" ? "mic" : utterance.cluster else { continue }
                let duration = utterance.end - utterance.start
                if (2.5...8).contains(duration) {
                    candidates[key, default: []].append(utterance)
                }
                if duration > (longest[key] ?? 0) { longest[key] = duration }
            }
            for (key, list) in candidates {
                let sorted = list.sorted { $0.start < $1.start }
                let step = max(1, sorted.count / 5)
                snippets[key] = stride(from: 0, to: sorted.count, by: step).prefix(5).map {
                    Snippet(start: sorted[$0].start, duration: sorted[$0].end - sorted[$0].start)
                }
            }
            // voz sem fala curta: cai na mais longa (recortada em 6s)
            for utterance in utterances {
                guard let key = utterance.track == "mic" ? "mic" : utterance.cluster else { continue }
                if snippets[key] == nil, utterance.end - utterance.start == longest[key] {
                    snippets[key] = [Snippet(start: utterance.start, duration: min(longest[key] ?? 6, 6))]
                }
            }
        }
    }

    /// Trilha de áudio da voz — nil se o arquivo já expirou (retenção).
    private func audioURL(for key: String) -> URL? {
        let url = key == "mic" ? meeting.micURL : meeting.systemURL
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private var showRenameAlert: Binding<Bool> {
        Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )
    }
}
