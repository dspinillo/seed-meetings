import AppKit
import SwiftUI

/// Tons do mockup aprovado (claro/escuro) — em vez das cinzas padrão do sistema.
enum SeedTheme {
    static let accentNS = dynamicNS(light: 0x4E7A57, dark: 0x8FB496)  // verde-sálvia
    static let accent = Color(nsColor: accentNS)
    static let accentSoft = dynamic(light: 0xE3EDE5, dark: 0x263429)
    static let windowBG = dynamic(light: 0xF6F6F8, dark: 0x1E1E20)
    static let panelBG = dynamic(light: 0xECECEF, dark: 0x1C1C1F)     // sidebars/barras
    static let cardBG = dynamic(light: 0xFFFFFF, dark: 0x232326)      // chips/cartões
    static let border = dynamic(light: 0xD8D8DC, dark: 0x3A3A3D)

    static func dynamic(light: Int, dark: Int) -> Color {
        Color(nsColor: dynamicNS(light: light, dark: dark))
    }

    static func dynamicNS(light: Int, dark: Int) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(rgb: isDark ? dark : light)
        }
    }
}

extension NSColor {
    convenience init(rgb: Int) {
        self.init(
            calibratedRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}
