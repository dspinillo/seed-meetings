import AppKit
import Carbon.HIToolbox
import SeedKit

/// Presets do atalho global da nota por voz — picker simples, sem UI de
/// gravação de atalho. Carbon não registra modificador sozinho (estilo Handy
/// com ⌥ direito), então os presets são sempre tecla+modificador ou F-keys.
enum HotkeyPreset: String, CaseIterable, Identifiable {
    case off, optSpace, ctrlOptSpace, optCmdSpace, cmdShiftV, f13, f14

    var id: String { rawValue }

    var display: String {
        switch self {
        case .off: return "Desligado"
        case .optSpace: return "⌥ Espaço"
        case .ctrlOptSpace: return "⌃⌥ Espaço"
        case .optCmdSpace: return "⌥⌘ Espaço"
        case .cmdShiftV: return "⌘⇧ V"
        case .f13: return "F13"
        case .f14: return "F14"
        }
    }

    var carbon: (keyCode: UInt32, modifiers: UInt32)? {
        switch self {
        case .off: return nil
        case .optSpace: return (UInt32(kVK_Space), UInt32(optionKey))
        case .ctrlOptSpace: return (UInt32(kVK_Space), UInt32(controlKey | optionKey))
        case .optCmdSpace: return (UInt32(kVK_Space), UInt32(optionKey | cmdKey))
        case .cmdShiftV: return (UInt32(kVK_ANSI_V), UInt32(cmdKey | shiftKey))
        case .f13: return (UInt32(kVK_F13), 0)
        case .f14: return (UInt32(kVK_F14), 0)
        }
    }
}

/// Atalho global via Carbon RegisterEventHotKey: funciona com o app em segundo
/// plano, entrega pressed E released (viável segurar-para-falar) e não exige
/// permissão de Acessibilidade/Monitoramento de Entrada — não mexe no TCC já
/// concedido à assinatura "Seed Dev".
@MainActor
final class HotkeyManager {
    static let shared = HotkeyManager()

    var onPressed: (() -> Void)?
    var onReleased: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerInstalled = false

    private init() {}

    /// Desregistra o atalho anterior e registra o do settings atual.
    /// Chamar no launch e sempre que as Preferências mudarem o preset.
    func apply(_ settings: SeedSettings) {
        installHandlerIfNeeded()
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        let preset = HotkeyPreset(rawValue: settings.voiceNoteHotkey) ?? .optSpace
        guard let combo = preset.carbon else { return }

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x5345_4544), id: 1) // "SEED"
        let status = RegisterEventHotKey(
            combo.keyCode, combo.modifiers, hotKeyID,
            GetEventDispatcherTarget(), 0, &ref
        )
        if status == noErr {
            hotKeyRef = ref
        } else {
            // atalho tomado por outro app (Raycast etc.) — o usuário troca o preset
            NSLog("Seed: falha ao registrar o atalho %@ (status %d)", preset.display, status)
        }
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, _ in
                let kind = GetEventKind(event)
                Task { @MainActor in
                    if kind == UInt32(kEventHotKeyPressed) {
                        HotkeyManager.shared.onPressed?()
                    } else if kind == UInt32(kEventHotKeyReleased) {
                        HotkeyManager.shared.onReleased?()
                    }
                }
                return noErr
            },
            eventTypes.count, &eventTypes, nil, nil
        )
    }
}
