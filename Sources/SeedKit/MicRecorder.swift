import AVFoundation
import CoreAudio
import Foundation

/// Log persistente da captura de mic (.mic.log na pasta de dados) — o app GUI
/// não tem stderr visível e o bug de mic vazio de 10/07 só acontece em
/// reuniões reais; este log é a caixa-preta para diagnosticar.
enum MicLog {
    static let url = SeedPaths.dataDirectory.appendingPathComponent(".mic.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func log(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        fputs("[mic] \(message)\n", stderr)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8) ?? Data())
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

/// Captura o microfone (a voz do usuário) em trilha separada via AVAudioEngine.
///
/// O engine PARA EM SILÊNCIO quando o dispositivo de entrada muda (AirPods
/// caindo/conectando, headset plugado) — caso real 08/07: mic.caf morreu aos
/// 17min de uma reunião longa, causando perda de áudio.
/// Por isso: observa a mudança de configuração + watchdog, retoma a captura
/// sozinho e preenche o buraco com silêncio para a linha do tempo continuar
/// alinhada com a trilha do sistema.
public final class MicRecorder {
    private var engine = AVAudioEngine()
    private let sink: ConvertingWavSink
    private var running = false
    private var startedAt: Date?
    private var observer: NSObjectProtocol?
    private var watchdog: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "seed.mic.recover")
    /// UID do dispositivo efetivamente capturando ("default" = padrão do sistema).
    private var boundUID = "default"
    /// Contador de buffers recebidos do tap (diagnóstico da caixa-preta).
    private var buffersReceived = 0
    private var buffersAtLastTick = -1
    private let counterLock = NSLock()

    private func currentBuffers() -> Int {
        counterLock.lock()
        defer { counterLock.unlock() }
        return buffersReceived
    }

    public init(sink: ConvertingWavSink) {
        self.sink = sink
    }

    public static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    public func start() throws {
        MicLog.log("start: preferido=\(SeedSettings.load().micDeviceUID) · disponíveis=\(AudioInputDevices.list().map(\.name))")
        try attach()
        running = true
        startedAt = Date()
        observeEngine()

        // primeiro check em 2s: o bind pode nascer morto se outro app (Meet)
        // está renegociando a taxa do device na mesma hora — race reproduzida
        // em 10/07; o reattach do watchdog cura
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self, self.running else { return }
            if !self.engine.isRunning {
                MicLog.log("watchdog: engine parado (buffers=\(self.buffersReceived), gravados=\(Int(self.sink.seconds))s) — recuperando")
                self.recoverLocked()
                return
            }
            let buffers = self.currentBuffers()
            if buffers == self.buffersAtLastTick {
                MicLog.log("watchdog: engine rodando mas SEM buffers novos (total=\(buffers), gravados=\(Int(self.sink.seconds))s) — reatando")
                self.recoverLocked(force: true)
                self.buffersAtLastTick = self.currentBuffers()
                return
            }
            self.buffersAtLastTick = buffers
            // o macOS trocou o input padrão (AirPods roubaram) ou o preferido
            // voltou a existir? devolve o padrão pro mic preferido
            let preferred = SeedSettings.load().micDeviceUID
            if preferred != "default",
               AudioInputDevices.defaultInputUID() != preferred,
               AudioInputDevices.deviceID(forUID: preferred) != nil {
                MicLog.log("watchdog: input padrão fora do mic preferido — devolvendo")
                self.recoverLocked(force: true)
            }
        }
        timer.resume()
        watchdog = timer
    }

    public func stop() {
        queue.sync {
            guard running else { return }
            running = false
            watchdog?.cancel()
            watchdog = nil
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
    }

    // MARK: - Retomada

    private func attach() throws {
        // ESTRATÉGIA (10/07): capturar SEMPRE pelo input padrão do sistema —
        // o único caminho que convive com o Meet segurando o mesmo mic. O
        // "fixar o mic" vira: definir o preferido como padrão do sistema
        // (que é o que o usuário queria e o macOS não persiste sozinho).
        // NUNCA usar bind direto (kAudioOutputUnitProperty_CurrentDevice):
        // nasce morto quando outro app segura o device — loop real em call.
        boundUID = "default"
        let preferred = SeedSettings.load().micDeviceUID
        if preferred != "default" {
            if AudioInputDevices.defaultInputUID() == preferred {
                boundUID = preferred
            } else if AudioInputDevices.setDefaultInput(uid: preferred) {
                boundUID = preferred
                MicLog.log("input padrão do sistema apontado para o mic preferido")
            } else {
                MicLog.log("mic preferido indisponível — seguindo com o padrão atual do sistema")
            }
        }

        let input = engine.inputNode
        let hardwareFormat = input.outputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            throw SeedError(
                "microfone sem formato válido — permissão negada? "
                    + "Confira Ajustes > Privacidade e Segurança > Microfone para o seu terminal."
            )
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { [weak self, sink] buffer, _ in
            sink.write(buffer)
            guard let self else { return }
            self.counterLock.lock()
            self.buffersReceived += 1
            let count = self.buffersReceived
            self.counterLock.unlock()
            if count == 1 { MicLog.log("primeiro buffer recebido (formato \(buffer.format))") }
        }
        try engine.start()
        MicLog.log("attach ok: device=\(boundUID) · formato=\(hardwareFormat) · engine.isRunning=\(engine.isRunning)")
    }

    private func observeEngine() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.recoverLocked() }
        }
    }

    /// Sempre chamado na `queue`. Recria o engine (o formato do input pode ter
    /// mudado junto com o dispositivo), realinha a timeline e retoma. Se o novo
    /// dispositivo ainda não estiver pronto, o watchdog tenta de novo em 5s.
    /// `force` reata mesmo com o engine rodando (migração p/ o mic preferido).
    private func recoverLocked(force: Bool = false) {
        guard running, force || !engine.isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine = AVAudioEngine()

        if let startedAt {
            let gap = Date().timeIntervalSince(startedAt) - sink.seconds
            if gap > 0.5 {
                sink.padSilence(seconds: gap)
                MicLog.log("captura caiu por \(Int(gap))s (troca de dispositivo?) — retomando com silêncio no buraco")
            }
        }

        do {
            try attach()
            observeEngine()
            MicLog.log("captura retomada")
        } catch {
            MicLog.log("falha ao retomar captura (\(error)) — nova tentativa em 5s")
        }
    }
}
