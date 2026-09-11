import AppKit
import SwiftUI

/// Renderer leve de markdown para os resumos/transcrições do Seed:
/// títulos (#, ##), bullets, checkboxes e formatação inline (negrito/itálico).
///
/// Backed por NSTextView: o conteúdo inteiro vira um único bloco de texto
/// contínuo, então a seleção funciona como num editor de verdade — dá para
/// arrastar por cima de vários parágrafos e copiar só o trecho que interessa
/// (a versão anterior, com um `Text` por linha, só permitia tudo-ou-nada).
struct MarkdownLite: NSViewRepresentable {
    let text: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastRenderedText: String?
    }

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        return view
    }

    func updateNSView(_ nsView: NSTextView, context: Context) {
        guard context.coordinator.lastRenderedText != text else { return }
        context.coordinator.lastRenderedText = text
        nsView.textStorage?.setAttributedString(Self.render(text))
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: NSTextView, context: Context
    ) -> CGSize? {
        guard let container = nsView.textContainer, let layout = nsView.layoutManager else {
            return nil
        }
        let width = proposal.width.map { max($0, 1) } ?? 10_000
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        return CGSize(width: min(width, ceil(used.width)), height: ceil(used.height))
    }

    // MARK: - Markdown → NSAttributedString

    static func render(_ text: String) -> NSAttributedString {
        let body = NSFont.preferredFont(forTextStyle: .body)
        let result = NSMutableAttributedString()
        var previousNewlineAttrs: [NSAttributedString.Key: Any]?
        var pendingExtraSpacing: CGFloat = 0

        for rawLine in text.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                pendingExtraSpacing += 12
                continue
            }

            let (paragraph, style) = renderLine(trimmed, body: body)
            style.paragraphSpacing = 6
            style.paragraphSpacingBefore += pendingExtraSpacing
            pendingExtraSpacing = 0
            paragraph.addAttribute(
                .paragraphStyle, value: style,
                range: NSRange(location: 0, length: paragraph.length)
            )

            // O "\n" pertence ao parágrafo anterior: precisa carregar o estilo
            // dele para o paragraphSpacing certo ser aplicado pelo TextKit.
            if let attrs = previousNewlineAttrs {
                result.append(NSAttributedString(string: "\n", attributes: attrs))
            }
            result.append(paragraph)
            previousNewlineAttrs = [.font: body, .paragraphStyle: style]
        }
        return result
    }

    /// Renderiza uma linha; o paragraphStyle retornado ainda recebe os
    /// spacings comuns em `render`.
    private static func renderLine(
        _ trimmed: String, body: NSFont
    ) -> (NSMutableAttributedString, NSMutableParagraphStyle) {
        let style = NSMutableParagraphStyle()

        if trimmed.hasPrefix("## ") {
            style.paragraphSpacingBefore = 10
            let caption = NSFont.preferredFont(forTextStyle: .caption1)
            let paragraph = NSMutableAttributedString(
                string: String(trimmed.dropFirst(3)).uppercased(),
                attributes: [
                    .font: NSFont.systemFont(ofSize: caption.pointSize, weight: .bold),
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .kern: 0.8,
                ]
            )
            return (paragraph, style)
        }

        if trimmed.hasPrefix("# ") {
            style.paragraphSpacingBefore = 4
            let title = NSFont.preferredFont(forTextStyle: .title3)
            let font = NSFont.systemFont(ofSize: title.pointSize, weight: .bold)
            return (inline(String(trimmed.dropFirst(2)), font: font), style)
        }

        if trimmed.hasPrefix("- [ ] ") || trimmed.hasPrefix("- [x] ") {
            let done = trimmed.hasPrefix("- [x] ")
            style.headIndent = 21
            style.tabStops = [NSTextTab(textAlignment: .left, location: 21)]
            let paragraph = NSMutableAttributedString()
            paragraph.append(checkbox(done: done, font: body))
            paragraph.append(NSAttributedString(string: "\t", attributes: [.font: body]))
            let content = inline(String(trimmed.dropFirst(6)), font: body)
            if done {
                content.addAttributes(
                    [
                        .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                        .strikethroughColor: NSColor.secondaryLabelColor,
                    ],
                    range: NSRange(location: 0, length: content.length)
                )
            }
            paragraph.append(content)
            return (paragraph, style)
        }

        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            style.headIndent = 13
            style.tabStops = [NSTextTab(textAlignment: .left, location: 13)]
            let paragraph = NSMutableAttributedString(
                string: "•\t",
                attributes: [.font: body, .foregroundColor: SeedTheme.accentNS]
            )
            paragraph.append(inline(String(trimmed.dropFirst(2)), font: body))
            return (paragraph, style)
        }

        return (inline(trimmed, font: body), style)
    }

    /// Formatação inline (negrito/itálico/código/links) via parser de
    /// markdown da Foundation, resolvida para atributos AppKit.
    private static func inline(
        _ string: String, font: NSFont, color: NSColor = .labelColor
    ) -> NSMutableAttributedString {
        let parsed = (try? AttributedString(
            markdown: string,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(string)

        let result = NSMutableAttributedString()
        for run in parsed.runs {
            let fragment = String(parsed.characters[run.range])
            var runFont = font
            var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: color]
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.stronglyEmphasized) {
                    runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .boldFontMask)
                }
                if intent.contains(.emphasized) {
                    runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .italicFontMask)
                }
                if intent.contains(.code) {
                    runFont = .monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular)
                }
                if intent.contains(.strikethrough) {
                    attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                }
            }
            attrs[.font] = runFont
            if let link = run.link { attrs[.link] = link }
            result.append(NSAttributedString(string: fragment, attributes: attrs))
        }
        return result
    }

    private static func checkbox(done: Bool, font: NSFont) -> NSAttributedString {
        let color: NSColor = done ? SeedTheme.accentNS : .secondaryLabelColor
        let config = NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .regular)
            .applying(.init(paletteColors: [color]))
        guard
            let image = NSImage(
                systemSymbolName: done ? "checkmark.square.fill" : "square",
                accessibilityDescription: nil
            )?.withSymbolConfiguration(config)
        else {
            return NSAttributedString(
                string: done ? "☑" : "☐",
                attributes: [.font: font, .foregroundColor: color]
            )
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(
            x: 0, y: font.descender + 1, width: image.size.width, height: image.size.height
        )
        return NSAttributedString(attachment: attachment)
    }
}
