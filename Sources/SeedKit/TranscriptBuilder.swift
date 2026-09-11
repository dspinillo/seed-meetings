import FluidAudio
import Foundation

/// Uma fala contínua de um falante, com posição no tempo da reunião.
public struct Utterance: Codable, Sendable, Identifiable {
    public var id: String { "\(track)-\(start)" }
    public let start: Double
    public let end: Double
    public let track: String     // "mic" | "system"
    public var speaker: String   // "Você", "Falante 1" ou nome confirmado
    public var cluster: String?  // id do cluster da diarização (trilha system)
    public let text: String

    public init(start: Double, end: Double, track: String, speaker: String, cluster: String?, text: String) {
        self.start = start
        self.end = end
        self.track = track
        self.speaker = speaker
        self.cluster = cluster
        self.text = text
    }
}

/// Constrói o transcript intercalado por tempo (estilo diálogo) a partir dos
/// token timings do ASR + segmentos de diarização.
public enum TranscriptBuilder {
    /// Agrupa tokens em falas, quebrando em pausas maiores que `gap` segundos.
    public static func utterances(
        from timings: [TokenTiming],
        track: String,
        speaker: String,
        gap: Double = 0.9
    ) -> [Utterance] {
        var result: [Utterance] = []
        var currentText = ""
        var currentStart: Double = 0
        var currentEnd: Double = 0

        func flush() {
            let text = currentText
                .replacingOccurrences(of: "▁", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // descarta "falas" sem conteúdo real (pontuação órfã do ASR)
            // e cacos em inglês (interjeições que o Parakeet alucina)
            if text.rangeOfCharacter(from: .alphanumerics) != nil, !Self.isEnglishShard(text) {
                result.append(
                    Utterance(
                        start: currentStart, end: currentEnd, track: track,
                        speaker: speaker, cluster: nil, text: text
                    )
                )
            }
            currentText = ""
        }

        for timing in timings {
            let token = timing.token
            if token.isEmpty || token == "<blank>" || token == "<pad>" { continue }
            if currentText.isEmpty {
                currentStart = timing.startTime
            } else if timing.startTime - currentEnd > gap {
                flush()
                currentStart = timing.startTime
            }
            currentText += token
            currentEnd = timing.endTime
        }
        flush()
        return result
    }

    /// Interjeições curtas/abafadas viram tokens em INGLÊS no Parakeet
    /// ("of the", "Well that you'll go", "things.") — cacos de ≤5 palavras,
    /// todas stopwords EN e nenhuma PT, são ruído e caem. Fala real em inglês
    /// (mais longa ou com termos fora da lista) passa.
    public static func isEnglishShard(_ text: String) -> Bool {
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !words.isEmpty, words.count <= 5 else { return false }
        let en: Set<String> = [
            "the", "of", "that", "this", "you", "your", "well", "so", "things", "thing",
            "i", "to", "and", "it", "is", "was", "are", "we", "they", "what", "yeah",
            "yes", "no", "not", "but", "on", "in", "at", "go", "going", "get", "got",
            "like", "just", "know", "right", "don", "re", "ll", "ve",
            "s", "t", "a", "my", "me", "he", "she", "will", "would", "can", "here",
        ]
        let pt: Set<String> = [
            "de", "que", "não", "nao", "é", "e", "um", "uma", "para", "pra", "com",
            "os", "as", "do", "da", "no", "na", "se", "por", "mais", "como", "mas",
            "foi", "ele", "ela", "são", "sao", "tem", "já", "ja", "também", "tambem",
            "só", "pode", "isso", "essa", "esse", "está", "esta", "tá", "ta", "vou",
            "vai", "gente", "aqui", "bom", "então", "entao", "sim", "então",
        ]
        if words.contains(where: { pt.contains($0) }) { return false }
        return words.allSatisfy { en.contains($0) }
    }

    /// Atribui o falante de cada fala da trilha do sistema pelo maior overlap
    /// temporal com os segmentos de diarização; `labels` mapeia cluster → rótulo
    /// (nome reconhecido pela memória de vozes ou "Falante N"). Fala SEM overlap
    /// nenhum vai para o falante mais próximo no tempo (desempate: mais airtime)
    /// — nunca fica no rótulo genérico ("falante fantasma").
    public static func assignSpeakers(
        _ utterances: [Utterance],
        segments: [SpeakerSegment],
        labels: [String: String] = [:]
    ) -> [Utterance] {
        guard !segments.isEmpty else { return utterances }
        let airtimes = Speakers.airtimes(segments)
        return utterances.map { utterance in
            var best: (id: String, overlap: Double)?
            for segment in segments {
                let overlap = min(utterance.end, segment.end) - max(utterance.start, segment.start)
                if overlap > 0, overlap > (best?.overlap ?? 0) {
                    best = (segment.speakerId, overlap)
                }
            }
            var updated = utterance
            let chosen = best?.id ?? segments.min { a, b in
                let da = distance(from: utterance, to: a)
                let db = distance(from: utterance, to: b)
                if da != db { return da < db }
                return (airtimes[a.speakerId] ?? 0) > (airtimes[b.speakerId] ?? 0)
            }?.speakerId
            if let chosen {
                updated.cluster = chosen
                updated.speaker = labels[chosen] ?? "Falante \(chosen)"
            }
            return updated
        }
    }

    private static func distance(from utterance: Utterance, to segment: SpeakerSegment) -> Double {
        max(0, max(segment.start - utterance.end, utterance.start - segment.end))
    }

    /// Mescla as falas das duas trilhas em ordem cronológica.
    public static func merge(_ lists: [Utterance]...) -> [Utterance] {
        lists.flatMap { $0 }.sorted { $0.start < $1.start }
    }

    /// Renderiza o diálogo em markdown: `[mm:ss] Falante: texto`.
    public static func dialogue(_ utterances: [Utterance]) -> String {
        utterances.map { utterance in
            String(
                format: "[%02d:%02d] **%@:** %@",
                Int(utterance.start) / 60, Int(utterance.start) % 60,
                utterance.speaker, utterance.text
            )
        }.joined(separator: "\n\n")
    }

    /// Documento completo do transcript (título + participantes + diálogo).
    public static func render(title: String, utterances: [Utterance]) -> String {
        let others = Set(utterances.filter { $0.track == "system" }.map(\.speaker)).sorted()
        let participants = (["Você"] + others).joined(separator: ", ")
        return """
        # \(title)

        Participantes: \(participants)

        \(dialogue(utterances))
        """
    }
}
