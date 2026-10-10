import Foundation
import Testing
@testable import SeedKit

@Suite("Integração real dos motores", .serialized)
struct ProviderIntegrationTests {
    @Test("resumo, chat ao vivo e continuidade", .enabled(if: ProcessInfo.processInfo.environment["SEED_LIVE_TESTS"] == "1"),
          arguments: ["gpt-5.6-sol", "gpt-5.6-luna", "gpt-5.6-terra", "gpt-6-astra", "antigravity"])
    func realProvider(_ model: String) throws {
        // Exige diretório isolado: nunca lê o glossário ou as reuniões reais.
        let path = try #require(ProcessInfo.processInfo.environment["SEED_DATA_DIR"])
        #expect(path != SeedPaths.legacyDirectory.path)
        #expect(path != FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Seed").path)
        let provider: LLMProviderID = model == "antigravity" ? .antigravity : .codex
        SeedSettings(provider: provider, codexModel: model).save()
        let root = SeedPaths.dataDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(rootURL: root)
        let meeting = try store.create(title: "Demonstração fictícia")
        let transcript = "[00:10] Ana: Aprovamos o Projeto Aurora. Entrego o orçamento na sexta-feira.\n[00:20] Você: Vou revisar o orçamento na segunda-feira."
        let summary = try Summarizer.summarize(transcript: transcript, meetingName: meeting.title, provider: provider)
        #expect(Summarizer.isInlineSummary(summary))
        #expect(summary.contains("Aurora"))
        try summary.write(to: meeting.summaryURL, atomically: true, encoding: .utf8)
        #expect(store.readSummary(meeting) == summary)
        try transcript.write(to: meeting.transcriptURL, atomically: true, encoding: .utf8)
        let live = try MeetingChat.askLive("Quem entrega o orçamento e quando?", meeting: meeting,
            liveTranscript: transcript, notes: "Prioridade: orçamento.", nowStamp: "[01:00]", provider: provider)
        let answer = try #require(live.last?.content)
        #expect(answer.contains("Ana"))
        #expect(answer.lowercased().contains("sexta"))
        #expect(!answer.contains("file://"))
        #expect(live.count == 2)
        let completed = try MeetingChat.ask("E qual é a minha tarefa?", meeting: meeting, store: store, provider: provider)
        #expect(completed.count == 4)
        #expect(completed.last?.content.lowercased().contains("revis") == true)
        #expect(MeetingChat.history(for: meeting).count == 4)
        print("VALIDADO: \(model) — resumo inline, chat ao vivo e continuidade persistida")
    }
}
