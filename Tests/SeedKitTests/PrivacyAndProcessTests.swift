import Foundation
import Testing
@testable import SeedKit

@Suite("Instalação limpa e CLIs")
struct PrivacyAndProcessTests {
    @Test("dicionário novo vazio; arquivo inválido não é sobrescrito")
    func cleanGlossary() throws {
        let root = try LLM.temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(".glossario.json")
        #expect(Glossary.load(from: file).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        try "invalid".write(to: file, atomically: true, encoding: .utf8)
        #expect(Glossary.load(from: file).isEmpty)
        #expect(try String(contentsOf: file, encoding: .utf8) == "invalid")
        #expect(MeetingStore(rootURL: root).list().isEmpty)
        #expect(VoiceprintStore(rootURL: root).all().isEmpty)
    }

    @Test("config antiga recebe padrão e modelo selecionado sobrevive ao roundtrip")
    func codexSettings() throws {
        #expect(try JSONDecoder().decode(SeedSettings.self, from: Data("{}".utf8)).codexModel == "default")
        for model in ["gpt-5.6-sol", "gpt-5.6-luna", "gpt-5.6-terra", "gpt-6-astra"] {
            let encoded = try JSONEncoder().encode(SeedSettings(codexModel: model))
            #expect(try JSONDecoder().decode(SeedSettings.self, from: encoded).codexModel == model)
            let args = LLM.codexArguments(model: model, outputURL: URL(fileURLWithPath: "/tmp/response.md"))
            #expect(args.contains(model))
            #expect(args.contains("--output-last-message"))
            #expect(args.last == "-")
        }
        #expect(!LLM.codexArguments(model: "default", outputURL: URL(fileURLWithPath: "/tmp/result")).contains("--model"))
    }

    @Test("stdout, stderr e stdin grandes não travam nem se misturam")
    func largeProcessOutput() throws {
        let input = String(repeating: "contexto ", count: 50000)
        let result = try LLM.runProcess("/bin/sh", arguments: ["-c", "dd if=/dev/zero bs=1024 count=512 >&2; cat"], stdin: input, timeout: 10)
        #expect(result == input)
    }

    @Test("timeout encerra processo que ignora SIGTERM")
    func timeout() {
        let start = Date()
        #expect(throws: (any Error).self) {
            try LLM.runProcess("/bin/sh", arguments: ["-c", "trap '' TERM; while :; do :; done"], stdin: nil, timeout: 0.1)
        }
        #expect(Date().timeIntervalSince(start) < 6)
    }

    @Test("Antigravity ignora progresso e exige exatamente um resultado final")
    func streamResponse() throws {
        let stream = #"{"event":"step_update","step_update":{"text_delta":"rascunho"}}"# + "\n" +
            #"{"event":"result","result":{"status":"SUCCESS","response":"Resposta final"}}"#
        #expect(try LLM.parseAntigravityStream(stream) == "Resposta final")
        #expect(throws: (any Error).self) { try LLM.parseAntigravityStream("{}") }
        #expect(throws: (any Error).self) { try LLM.parseAntigravityStream(stream + "\n" + stream) }
    }
}
