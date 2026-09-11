import FluidAudio
import Foundation

/// Transcrição local via FluidAudio (Parakeet TDT v3, multilíngue com pt-BR),
/// rodando em CoreML/Neural Engine. Padrão de uso validado no Muesli (MIT).
public final class SpikeASR {
    public init() {}
    private var manager: AsrManager?

    public func load() async throws {
        if manager != nil { return }
        fputs("[asr] baixando/carregando Parakeet v3 (primeira vez baixa ~450 MB)...\n", stderr)
        var lastPercent = -1
        let models = try await AsrModels.downloadAndLoad(version: .v3) { progress in
            let percent = Int(progress.fractionCompleted * 100)
            if percent != lastPercent, percent % 10 == 0 {
                lastPercent = percent
                fputs("[asr] \(percent)%\n", stderr)
            }
        }
        let asrManager = AsrManager(config: .default)
        try await asrManager.loadModels(models)
        manager = asrManager
        fputs("[asr] modelos prontos\n", stderr)
    }

    public func transcribe(_ url: URL) async throws -> String {
        try await transcribeDetailed(url).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Resultado completo, com timestamps por token (base do transcript intercalado).
    /// O hint pt filtra tokens de outros alfabetos (cirílico/grego — a
    /// alucinação de reconhecimento de fala); inglês passa pelo filtro (mesmo
    /// alfabeto) e é tratado pelo descarte de cacos no TranscriptBuilder.
    public func transcribeDetailed(_ url: URL) async throws -> ASRResult {
        guard let manager else { throw SeedError("modelos de ASR não carregados") }
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        return try await manager.transcribe(url, decoderState: &decoderState, language: .portuguese)
    }
}

public struct SpeakerSegment: Codable, Sendable {
    public let speakerId: String
    public let start: Double
    public let end: Double
    public let embedding: [Float]

    public init(speakerId: String, start: Double, end: Double, embedding: [Float]) {
        self.speakerId = speakerId
        self.start = start
        self.end = end
        self.embedding = embedding
    }
}

/// Diarização local (pyannote em CoreML via FluidAudio) — separa as vozes
/// dentro da trilha do sistema ("quantas pessoas falaram e quando").
public final class SpikeDiarizer {
    public init() {}
    private var manager: DiarizerManager?

    public func load() async throws {
        if manager != nil { return }
        fputs("[diarizacao] baixando/carregando modelos...\n", stderr)
        let models = try await DiarizerModels.download()
        let diarizer = DiarizerManager()
        diarizer.initialize(models: models)
        manager = diarizer
        fputs("[diarizacao] modelos prontos\n", stderr)
    }

    public func diarize(_ url: URL) throws -> [SpeakerSegment] {
        guard let manager else { throw SeedError("modelos de diarização não carregados") }
        let converter = AudioConverter()
        let samples = try converter.resampleAudioFile(url)
        let result = try manager.performCompleteDiarization(samples, sampleRate: 16000)
        return result.segments.map {
            SpeakerSegment(
                speakerId: $0.speakerId,
                start: Double($0.startTimeSeconds),
                end: Double($0.endTimeSeconds),
                embedding: $0.embedding
            )
        }
    }
}

public func formatTimeline(_ segments: [SpeakerSegment], limit: Int = 80) -> String {
    guard !segments.isEmpty else { return "(nenhum segmento detectado)" }
    let speakers = Set(segments.map(\.speakerId)).sorted()
    var lines = ["\(speakers.count) voz(es) distintas detectadas: \(speakers.joined(separator: ", "))"]
    for segment in segments.prefix(limit) {
        lines.append(
            String(
                format: "Falante %@: %02d:%02d–%02d:%02d",
                segment.speakerId,
                Int(segment.start) / 60, Int(segment.start) % 60,
                Int(segment.end) / 60, Int(segment.end) % 60
            )
        )
    }
    if segments.count > limit {
        lines.append("… (+\(segments.count - limit) segmentos)")
    }
    return lines.joined(separator: "\n")
}
