import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// Captura o áudio de saída do sistema (a voz dos outros participantes da call)
/// via Core Audio Process Tap (macOS 14.4+) — sem driver virtual, sem bot.
/// Adaptado da implementação de referência do OpenWhispr (MIT).
public final class TapRecorder {
    private let sink: ConvertingWavSink
    private let ioQueue = DispatchQueue(label: "ai.seed.spike.tap")
    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private var sourceFormat: AVAudioFormat?
    private var stopping = false

    public init(sink: ConvertingWavSink) {
        self.sink = sink
    }

    public func start() throws {
        let description = CATapDescription()
        description.name = "seed-spike-tap"
        description.uuid = UUID()
        description.processes = [] // vazio + exclusive = tap global (tudo que toca nos alto-falantes)
        description.isMono = true
        description.isExclusive = true
        description.isMixdown = true
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var newTapID = AudioObjectID()
        var status = AudioHardwareCreateProcessTap(description, &newTapID)
        guard status == noErr else {
            throw SeedError(
                "falha ao criar o process tap (status \(status)). "
                    + "Se apareceu um pedido de permissão de 'Gravação de áudio do sistema', aceite e rode de novo."
            )
        }
        tapID = newTapID

        var asbd = AudioStreamBasicDescription()
        var dataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        status = AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &dataSize, &asbd)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            throw SeedError("falha ao ler o formato do tap (status \(status))")
        }
        sourceFormat = format

        let tapUID = try readTapUID()

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Seed Spike Tap",
            kAudioAggregateDeviceUIDKey: "ai.seed.spike.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceSubDeviceListKey: [],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID]],
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
        ]
        var deviceID = AudioObjectID()
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &deviceID)
        guard status == noErr else {
            throw SeedError("falha ao criar o aggregate device (status \(status))")
        }
        aggregateID = deviceID

        try waitUntilDeviceAlive()

        var procID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { [weak self] _, inputData, _, _, _ in
            guard let self, !self.stopping, let sourceFormat = self.sourceFormat else { return }
            let bufferList = UnsafeMutablePointer(mutating: inputData)
            guard
                let buffer = AVAudioPCMBuffer(
                    pcmFormat: sourceFormat,
                    bufferListNoCopy: bufferList,
                    deallocator: nil
                )
            else { return }
            self.sink.write(buffer)
        }
        guard status == noErr, let procID else {
            throw SeedError("falha ao criar o IOProc (status \(status))")
        }
        ioProcID = procID

        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else {
            throw SeedError("falha ao iniciar a captura do sistema (status \(status))")
        }
    }

    public func stop() {
        if stopping { return }
        stopping = true

        if aggregateID != 0 {
            AudioDeviceStop(aggregateID, ioProcID)
        }
        if let ioProcID {
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = 0
        }
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
        }
    }

    private func readTapUID() throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var unmanagedUID: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &unmanagedUID) { pointer in
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &dataSize, pointer)
        }
        guard status == noErr, let unmanagedUID else {
            throw SeedError("falha ao ler o UID do tap (status \(status))")
        }
        return unmanagedUID.takeRetainedValue() as String
    }

    private func waitUntilDeviceAlive() throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        for _ in 0..<20 {
            var isAlive: UInt32 = 0
            var dataSize = UInt32(MemoryLayout<UInt32>.size)
            let status = AudioObjectGetPropertyData(aggregateID, &address, 0, nil, &dataSize, &isAlive)
            if status == noErr, isAlive != 0 { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw SeedError("o aggregate device não ficou pronto a tempo")
    }
}
