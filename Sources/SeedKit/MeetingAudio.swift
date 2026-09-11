import AVFoundation
import Foundation

/// Trechos de áudio para clientes MCP. Nenhum arquivo exportado fica no disco.
public enum MeetingAudio {
    public struct Clip {
        public let wav: Data
        public let durationSeconds: Double
    }

    public static func duration(of url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }

    /// Produz WAV PCM mono, 16 kHz/16 bits; limita memória e tamanho da resposta.
    public static func clip(url: URL, start: Double, duration: Double) throws -> Clip {
        guard start.isFinite, start >= 0, duration.isFinite, duration > 0, duration <= 30 else {
            throw SeedError("Use início >= 0 e duração entre 0 e 30 segundos.")
        }
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        guard format.sampleRate > 0, format.sampleRate <= 192_000, format.channelCount <= 8,
              start < Double(file.length) / format.sampleRate else {
            throw SeedError("Início fora do áudio ou formato não suportado.")
        }
        file.framePosition = AVAudioFramePosition(start * format.sampleRate)
        let count = AVAudioFrameCount(min(Double(file.length - file.framePosition), ceil(duration * format.sampleRate)))
        guard let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count),
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: target),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(ceil(duration * 16_000)) + 64) else {
            throw SeedError("Não foi possível preparar o trecho de áudio.")
        }
        try file.read(into: input, frameCount: count)
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .endOfStream; return nil }
            supplied = true
            state.pointee = .haveData
            return input
        }
        guard status != .error, error == nil, output.frameLength > 0, let samples = output.floatChannelData?[0] else {
            throw SeedError("Não foi possível converter o trecho de áudio.")
        }
        let length = min(Int(output.frameLength), Int(ceil(duration * 16_000)))
        var wav = Data()
        func ascii(_ value: String) { wav.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) { var n = value.littleEndian; withUnsafeBytes(of: &n) { wav.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var n = value.littleEndian; withUnsafeBytes(of: &n) { wav.append(contentsOf: $0) } }
        ascii("RIFF"); u32(UInt32(36 + length * 2)); ascii("WAVEfmt ")
        u32(16); u16(1); u16(1); u32(16_000); u32(32_000); u16(2); u16(16)
        ascii("data"); u32(UInt32(length * 2))
        for index in 0..<length {
            let sample = samples[index].isFinite ? max(-1, min(1, samples[index])) : 0
            u16(UInt16(bitPattern: Int16(sample * 32767)))
        }
        return Clip(wav: wav, durationSeconds: Double(length) / 16_000)
    }
}
