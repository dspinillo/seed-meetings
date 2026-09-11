import CoreAudio
import Foundation

/// Um dispositivo de entrada de áudio do Mac (mic embutido, headset, interface).
public struct AudioInputDevice: Identifiable, Sendable, Equatable {
    public let uid: String
    public let name: String
    public var id: String { uid }
}

/// Enumeração de microfones via Core Audio. O macOS troca o input PADRÃO
/// sozinho (AirPods conectam e viram o mic); o Seed permite fixar um
/// dispositivo preferido que ignora essa dança (Preferências → Transcrição).
public enum AudioInputDevices {
    /// Todos os dispositivos com canais de entrada, na ordem do sistema.
    public static func list() -> [AudioInputDevice] {
        allDeviceIDs().compactMap { deviceID in
            guard inputChannelCount(deviceID) > 0,
                  let uid = stringProperty(deviceID, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(deviceID, kAudioObjectPropertyName)
            else { return nil }
            return AudioInputDevice(uid: uid, name: name)
        }
    }

    /// Resolve o UID persistido para o AudioDeviceID atual (nil se desconectado).
    public static func deviceID(forUID uid: String) -> AudioDeviceID? {
        allDeviceIDs().first { stringProperty($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    /// UID do input padrão do sistema neste momento (nil se indisponível).
    public static func defaultInputUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr,
            deviceID != 0
        else { return nil }
        return stringProperty(deviceID, kAudioDevicePropertyDeviceUID)
    }

    /// Define o input padrão do sistema — é o que o usuário pediu ("setar como
    /// padrão o que eu uso, já que o mac não deixa"): o caminho padrão de
    /// captura convive bem com o Meet, ao contrário do bind direto no device
    /// (que nasce morto quando o Chrome segura o mic — caso real 10/07).
    @discardableResult
    public static func setDefaultInput(uid: String) -> Bool {
        guard var deviceID = deviceID(forUID: uid) else { return false }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &deviceID
        ) == noErr
    }

    // MARK: - Core Audio plumbing

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0
        else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr
        else { return [] }
        return devices
    }

    private static func inputChannelCount(_ deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0
        else { return 0 }
        let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(size))
        defer { bufferList.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, bufferList) == noErr
        else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(
        _ deviceID: AudioDeviceID, _ selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }
}
