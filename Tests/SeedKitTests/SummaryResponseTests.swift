import Foundation
import Testing
@testable import SeedKit

@Suite("Respostas de resumo")
struct SummaryResponseTests {
    private let summary = "## TL;DR\nUma decisão foi tomada.\n\n## Decisões\n- Aprovar a proposta."
    private let artifactReply = "Pronto! Aqui está o arquivo:\n[Resumo da Reunião](file:///tmp/resumo.md)"

    @Test("extrai somente o conteúdo do envelope JSON do Antigravity")
    func jsonResponse() throws {
        let data = try JSONSerialization.data(withJSONObject: ["status": "SUCCESS", "response": summary])
        #expect(try LLM.parseAntigravityResponse(String(decoding: data, as: UTF8.self)) == summary)
    }

    @Test("rejeita JSON inválido, vazio e falha com conteúdo parcial")
    func invalidResponses() {
        for output in ["texto sem JSON", "{}", #"{"status":"SUCCESS","response":"  "}"#,
                       ###"{"status":"ERROR","response":"## TL;DR\nParcial","error":"timeout"}"###] {
            #expect(throws: (any Error).self) { try LLM.parseAntigravityResponse(output) }
        }
    }

    @Test("resumo inline é aceito sem gastar outra chamada")
    func inline() throws {
        var calls = 0
        let result = try Summarizer.generateValidatedSummary { correction in
            calls += 1
            #expect(correction.isEmpty)
            return summary
        }
        #expect(result == summary)
        #expect(calls == 1)
    }

    @Test("mensagem com link é corrigida em uma nova tentativa")
    func retryArtifact() throws {
        var calls = 0
        let result = try Summarizer.generateValidatedSummary { correction in
            calls += 1
            if calls == 1 { return artifactReply }
            #expect(correction.contains("diretamente na resposta"))
            return summary
        }
        #expect(result == summary)
        #expect(calls == 2)
    }

    @Test("duas respostas sem resumo falham sem salvar o recado")
    func invalidRetry() {
        var calls = 0
        #expect(throws: (any Error).self) {
            try Summarizer.generateValidatedSummary { _ in
                calls += 1
                return artifactReply
            }
        }
        #expect(calls == 2)
    }

    @Test("aceita título opcional e rejeita seções vazias ou recado com heading")
    func formatting() {
        #expect(Summarizer.isInlineSummary("# Reunião\n\n" + summary))
        for text in ["", "## TL;DR", "## TL;DR\n\n## Decisões", "Pronto!\n" + summary] {
            #expect(!Summarizer.isInlineSummary(text))
        }
    }
}
