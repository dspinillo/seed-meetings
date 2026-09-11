import Foundation

/// Segmentação da transcrição ao vivo: corta o buffer em PAUSAS da fala
/// (não no relógio) para não mutilar palavras na fronteira dos blocos.
public enum LiveSegmenter {
    /// Procura (do fim para o começo) uma janela de `pauseSeconds` de silêncio
    /// para cortar; sem pausa, só força o corte quando o buffer passa de
    /// `maxSeconds`. Devolve nil enquanto não há material suficiente.
    public static func splitAtPause(
        _ samples: [Float],
        sampleRate: Int = 16_000,
        minSeconds: Double = 2,
        maxSeconds: Double = 25,
        pauseSeconds: Double = 0.4,
        silenceRMS: Float = 0.004
    ) -> (head: [Float], tail: [Float])? {
        guard samples.count >= Int(minSeconds * Double(sampleRate)) else { return nil }
        let window = Int(pauseSeconds * Double(sampleRate))
        var index = samples.count - window
        let minIndex = sampleRate // não corta no primeiro segundo
        while index > minIndex {
            var acc: Float = 0
            for i in index..<(index + window) { acc += samples[i] * samples[i] }
            if (acc / Float(window)).squareRoot() < silenceRMS {
                return (Array(samples[..<index]), Array(samples[index...]))
            }
            index -= window / 2
        }
        if samples.count >= Int(maxSeconds * Double(sampleRate)) {
            return (samples, [])
        }
        return nil
    }
}
