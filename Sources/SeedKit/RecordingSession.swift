import Foundation

/// Orquestra a gravação de uma reunião: mic + áudio do sistema em trilhas
/// separadas, com níveis ao vivo para a UI.
public final class RecordingSession {
    public let meeting: Meeting
    public let startedAt: Date

    private let micSink: ConvertingWavSink
    private let systemSink: ConvertingWavSink
    private let mic: MicRecorder
    private let tap: TapRecorder
    private var stopped = false

    public init(meeting: Meeting) throws {
        self.meeting = meeting
        self.startedAt = Date()
        micSink = try ConvertingWavSink(url: meeting.micURL)
        systemSink = try ConvertingWavSink(url: meeting.systemURL)
        mic = MicRecorder(sink: micSink)
        tap = TapRecorder(sink: systemSink)
    }

    /// Nível 0–1 aproximado para os medidores da UI (escala dB calibrada p/ voz).
    public var micLevel: Float { Self.normalizedLevel(micSink.lastRMS) }
    public var systemLevel: Float { Self.normalizedLevel(systemSink.lastRMS) }

    public var elapsedSeconds: Double { Date().timeIntervalSince(startedAt) }

    /// Relógio da trilha do mic (inclui padSilence) — é o tempo que casa com
    /// os timestamps [mm:ss] do transcript, ao contrário do wall clock.
    public var micClockSeconds: Double { micSink.seconds }

    /// Liga a captura lateral da nota por voz; devolve o relógio da trilha
    /// no instante do início (para carimbar a nota).
    public func beginVoiceNoteCapture() -> Double {
        micSink.startSideCapture()
        return micSink.seconds
    }

    /// Desliga a captura lateral e devolve os samples (16 kHz mono).
    public func endVoiceNoteCapture() -> [Float] {
        micSink.endSideCapture()
    }

    public static func normalizedLevel(_ rms: Float) -> Float {
        let db = 20 * log10(max(rms, 0.000_01))
        return max(0, min(1, (db + 52) / 32))
    }

    public func start() async throws {
        guard await MicRecorder.requestPermission() else {
            throw SeedError(
                "permissão de microfone negada. Libere em Ajustes > Privacidade e Segurança > Microfone."
            )
        }
        try tap.start()
        try mic.start()
    }

    /// Samples novos desde o último drain (p/ transcrição ao vivo).
    public func drainLive() -> (mic: [Float], system: [Float]) {
        (micSink.drainLiveSamples(), systemSink.drainLiveSamples())
    }

    /// Para tudo, fecha os arquivos e devolve os segundos gravados por trilha.
    @discardableResult
    public func stop() -> (micSeconds: Double, systemSeconds: Double) {
        guard !stopped else { return (micSink.seconds, systemSink.seconds) }
        stopped = true
        mic.stop()
        tap.stop()
        micSink.close()
        systemSink.close()
        return (micSink.seconds, systemSink.seconds)
    }
}
