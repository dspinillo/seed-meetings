import AVFoundation
import Foundation

public struct SeedError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Recebe buffers de áudio em qualquer formato, converte para Int16 mono 16 kHz
/// e grava num arquivo WAV. Thread-safe para leitura de nível (RMS) de fora.
public final class ConvertingWavSink {
    private let targetFormat: AVAudioFormat
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private let lock = NSLock()
    private var _lastRMS: Float = 0
    private var _framesWritten: AVAudioFramePosition = 0
    private var _liveSamples: [Float] = []
    // captura lateral da nota por voz (nil = desligada) — separada de
    // _liveSamples para não competir com o drain destrutivo do live loop
    private var _sideSamples: [Float]?
    private var loggedWriteError = false

    public let url: URL

    public init(url: URL, sampleRate: Double = 16_000) throws {
        self.url = url
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: true
            )
        else {
            throw SeedError("não consegui criar o formato de áudio alvo")
        }
        targetFormat = format
        file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
    }

    public var lastRMS: Float {
        lock.lock()
        defer { lock.unlock() }
        return _lastRMS
    }

    public var seconds: Double {
        lock.lock()
        defer { lock.unlock() }
        return Double(_framesWritten) / targetFormat.sampleRate
    }

    public func write(_ sourceBuffer: AVAudioPCMBuffer) {
        guard let file else { return }

        if converter == nil || sourceFormat != sourceBuffer.format {
            sourceFormat = sourceBuffer.format
            converter = AVAudioConverter(from: sourceBuffer.format, to: targetFormat)
        }
        guard let converter else { return }

        let sourceRate = max(sourceBuffer.format.sampleRate, 1)
        let capacity = AVAudioFrameCount(
            ceil(Double(sourceBuffer.frameLength) * targetFormat.sampleRate / sourceRate)
        ) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return
        }

        var didProvideInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            didProvideInput = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }

        guard conversionError == nil,
              status == .haveData || status == .inputRanDry,
              output.frameLength > 0
        else { return }

        // floats + RMS do áudio REAL, antes de eventualmente silenciar o buffer
        guard let channel = output.int16ChannelData?[0] else { return }
        let count = Int(output.frameLength)
        guard count > 0 else { return }
        var acc = 0.0
        var floats = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let v = Double(channel[i]) / 32768.0
            acc += v * v
            floats[i] = Float(channel[i]) / 32768.0
        }
        let rms = Float((acc / Double(count)).squareRoot())

        lock.lock()
        let sideActive = _sideSamples != nil
        if sideActive {
            _sideSamples!.append(contentsOf: floats)
            // teto de segurança (o controller auto-finaliza em 3 min)
            if _sideSamples!.count > 16_000 * 180 {
                _sideSamples!.removeFirst(_sideSamples!.count - 16_000 * 180)
            }
        }
        lock.unlock()

        // nota por voz ativa: o trecho pertence à NOTA, não à reunião — o
        // arquivo e a transcrição ao vivo recebem silêncio no lugar (evita a
        // fala da nota duplicada no transcript; a linha do tempo continua
        // andando e o RMS-gate do live descarta o silêncio sem gastar ASR)
        if sideActive {
            memset(channel, 0, count * MemoryLayout<Int16>.size)
        }

        do {
            try file.write(from: output)
        } catch {
            if !loggedWriteError {
                loggedWriteError = true
                fputs("\naviso: falha ao gravar em \(url.lastPathComponent): \(error)\n", stderr)
            }
            return
        }

        lock.lock()
        _lastRMS = rms // nível do áudio real mesmo durante a nota (barrinha do HUD)
        _framesWritten += AVAudioFramePosition(output.frameLength)
        // buffer para a transcrição ao vivo (limitado a ~90s por segurança)
        _liveSamples.append(contentsOf: sideActive ? [Float](repeating: 0, count: count) : floats)
        if _liveSamples.count > 16_000 * 90 {
            _liveSamples.removeFirst(_liveSamples.count - 16_000 * 90)
        }
        lock.unlock()
    }

    /// Liga a captura lateral (nota por voz): acumula os mesmos samples de
    /// 16 kHz num buffer próprio até endSideCapture().
    public func startSideCapture() {
        lock.lock()
        _sideSamples = []
        lock.unlock()
    }

    /// Desliga a captura lateral e devolve o que foi acumulado.
    public func endSideCapture() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let samples = _sideSamples ?? []
        _sideSamples = nil
        return samples
    }

    /// Preenche um buraco de captura com silêncio — mantém a linha do tempo
    /// alinhada com a outra trilha quando o mic cai e é retomado (troca de
    /// dispositivo de entrada). Não alimenta a transcrição ao vivo.
    public func padSilence(seconds: Double) {
        guard seconds > 0.05, let file else { return }
        var remaining = AVAudioFramePosition(seconds * targetFormat.sampleRate)
        while remaining > 0 {
            let n = AVAudioFrameCount(min(16_000, remaining))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: n) else { return }
            buffer.frameLength = n
            if let channel = buffer.int16ChannelData?[0] {
                memset(channel, 0, Int(n) * MemoryLayout<Int16>.size)
            }
            do {
                try file.write(from: buffer)
            } catch {
                return
            }
            lock.lock()
            _framesWritten += AVAudioFramePosition(n)
            lock.unlock()
            remaining -= AVAudioFramePosition(n)
        }
    }

    /// Devolve e limpa os samples acumulados desde o último drain
    /// (16 kHz mono Float) — usado pela transcrição ao vivo.
    public func drainLiveSamples() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let samples = _liveSamples
        _liveSamples.removeAll(keepingCapacity: true)
        return samples
    }

    /// Finaliza o arquivo (AVAudioFile fecha ao ser desalocado).
    public func close() {
        file = nil
        converter = nil
    }
}
