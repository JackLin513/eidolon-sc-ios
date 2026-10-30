import SwiftUI
import UIKit

/// The bar's colours (upstream `ink.ts` `BAR_INK`): the 640×360 screen is drawn in these alone,
/// so the pictures and the text look of one piece.
enum BarInk {
    static let ground = BarInk.hex(0x1F1A2D)
    static let text = BarInk.hex(0xFFFFFF)
    static let sub = BarInk.hex(0xB9B3C9)
    static let producer = BarInk.hex(0x7FB2FF)
    static let pink = BarInk.hex(0xF72B62)
    static let pinkDim = BarInk.hex(0x7A1531)
    static let channel = BarInk.hex(0x24FF00)
    static let black = BarInk.hex(0x000000)
    static let veil = BarInk.hex(0x000000).opacity(0.6)
    static let button = BarInk.hex(0x111111)
    static let paper = BarInk.hex(0xFFFFFF)
    static let bookGrey = BarInk.hex(0x9B9B9B)
    static let lit = BarInk.hex(0xFFBB31)
    static let off = BarInk.hex(0x808080)
    static let jukeTitle = BarInk.hex(0x3C84CF)
    static let jukeSlot = BarInk.hex(0xA6023C)
    static let jukeHint = BarInk.hex(0xFC1783)

    static let uiText = UIColor(red: 1, green: 1, blue: 1, alpha: 1)
    static let uiSub = UIColor(red: 0xB9 / 255, green: 0xB3 / 255, blue: 0xC9 / 255, alpha: 1)
    static let uiProducer = UIColor(red: 0x7F / 255, green: 0xB2 / 255, blue: 1, alpha: 1)

    static func ui(_ color: Color) -> UIColor { UIColor(color) }

    /// A colour from its 24-bit value, as the original writes them.
    static func hex(_ value: UInt32) -> Color {
        Color(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

/// The bar's pixel font, 「缝合像素」 (BarFusionPixel12), and its metrics (upstream
/// `PixelText.tsx`): a 12 px glyph, 16 px a row, drawn at twice the size and thresholded so the
/// edges stay hard.
///
/// The face is proportional — あ/中/♥ 12 px, 'A' 8, 'a'/'1'/' ' 6 — so how wide a text is, is
/// what the face itself measures, a character at a time, as the original measures it with
/// `ctx.measureText`. `mono` is the original's monospaced setting for the counter's labels and
/// the jukebox's titles, where every glyph takes a whole cell or half of one.
@MainActor
enum BarFont {
    static let name = "BarFusionPixel"
    static let size: Double = 12
    static let lineHeight: Double = 16
    /// Glyphs are drawn this much larger and then thresholded, so the edges stay hard pixels.
    static let oversample: Double = 2
    /// A score at or past this is a pixel of the glyph; the rest is empty.
    static let threshold: UInt8 = 128

    /// A face of the pixel font, with what it has measured of its characters so far. One per
    /// package (`BarImages`), so the font file is read once and no glyph is measured twice.
    final class Face {
        let font: UIFont
        /// How far above the baseline a CJK glyph's ink starts. The original draws with
        /// `textBaseline = "top"`, which puts that ink's top on the row's line; Core Text draws
        /// from the line box's top instead, so this is taken off to put the ink there too.
        let inkTop: Double
        private var advances: [Character: Double] = [:]

        init(font: UIFont) {
            self.font = font
            inkTop = Face.inkTop(of: font)
        }

        /// The system's face, for a screen with no package in it.
        static let fallback = Face(font: .monospacedSystemFont(ofSize: size, weight: .regular))

        /// How wide `text` is drawn: the sum of its glyphs' advances, a character at a time.
        func width(_ text: String, mono: Bool = false) -> Double {
            text.reduce(0) { $0 + advance($1, mono: mono) }
        }

        /// One glyph's advance: the face's own, or the original's fixed cell under `mono`.
        func advance(_ character: Character, mono: Bool = false) -> Double {
            if mono { return BarFont.monoAdvance(character) }
            if let known = advances[character] { return known }
            let measured = (String(character) as NSString).size(withAttributes: [.font: font]).width
            advances[character] = measured
            return measured
        }

        /// Where a row's glyphs are drawn from: the original's
        /// `cy = row * lineHeight + round((lineHeight - SIZE) / 2)` is where the ink's top goes,
        /// and Core Text starts from a line box whose ascent sits above the baseline.
        func drawTop(ofRow row: Int) -> Double {
            let cy = Double(row) * BarFont.lineHeight
                + ((BarFont.lineHeight - BarFont.size) / 2).rounded()
            return (cy + inkTop - Double(font.ascender)).rounded()
        }

        private static func inkTop(of font: UIFont) -> Double {
            let ctFont = font as CTFont
            var glyphs = [CGGlyph](repeating: 0, count: 1)
            let characters = Array("中".utf16)
            guard CTFontGetGlyphsForCharacters(ctFont, characters, &glyphs, 1), glyphs[0] != 0
            else { return Double(font.ascender) }
            let box = CTFontGetBoundingRectsForGlyphs(ctFont, .horizontal, glyphs, nil, 1)
            return box.isNull ? Double(font.ascender) : Double(box.maxY)
        }
    }

    /// The face in the installed bar package's `fonts/`, or the system's when none is in.
    static func load(in directory: URL?) -> UIFont {
        let fallback = UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        guard let directory else { return fallback }
        let fonts = (try? FileManager.default.contentsOfDirectory(
            at: directory.appending(path: "fonts"), includingPropertiesForKeys: nil
        )) ?? []
        for url in fonts.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let data = try? Data(contentsOf: url),
                  let provider = CGDataProvider(data: data as CFData),
                  let loaded = CGFont(provider)
            else { continue }
            // The package names the face its own way; what Core Text wants is the PostScript
            // name. A face that is not in yet has to be registered first: asking by name alone
            // can answer with a system face instead.
            let postScriptName = loaded.postScriptName as String? ?? name
            if UIFont(name: postScriptName, size: size) == nil {
                register(data)
            }
            if let font = UIFont(name: postScriptName, size: size) {
                return font
            }
        }
        return fallback
    }

    /// The face handed to the system. Best effort: one it will not take is simply not used, and
    /// the caller asks for it by name either way.
    private static func register(_ data: Data) {
        guard let provider = CGDataProvider(data: data as CFData),
              let font = CGFont(provider)
        else { return }
        CTFontManagerRegisterGraphicsFont(font, nil)
    }

    /// A run of the box's text in one colour.
    struct Run: Hashable {
        var text: String
        var color: UIColor
    }

    /// The original's fixed cell under `mono`: a whole one for CJK and other wide characters,
    /// half one for the rest.
    nonisolated static func monoAdvance(_ character: Character) -> Double {
        for scalar in character.unicodeScalars {
            let value = scalar.value
            // Upstream's `mono`: everything from the CJK block on is full width, but not
            // half-width katakana.
            if value >= 0x2E80, !(value >= 0xFF61 && value <= 0xFFDC) { return size }
        }
        return size / 2
    }

    /// Every line of `runs`, as the runs that are on it.
    static func lines(_ runs: [Run]) -> [[Run]] {
        var lines: [[Run]] = [[]]
        for run in runs {
            var text = ""
            for character in run.text {
                if character == "\n" {
                    if !text.isEmpty { lines[lines.count - 1].append(Run(text: text, color: run.color)) }
                    text = ""
                    lines.append([])
                    continue
                }
                text.append(character)
            }
            if !text.isEmpty { lines[lines.count - 1].append(Run(text: text, color: run.color)) }
        }
        return lines
    }

    /// `runs` drawn from the top, `align`ed in `width`: the image the screen shows at 1 px a
    /// logical pixel. Lines keep their colours; nothing is anti-aliased.
    ///
    /// `width` is the box the text has to fit, as the original's `width` is: given one, a line
    /// wider than it is cut off at its edge rather than the image growing. Given none, the image
    /// is as wide as the widest line.
    static func image(
        _ runs: [Run], width: Double = 0, align: BarTextAlign = .left, mono: Bool = false,
        face: Face
    ) -> UIImage? {
        let lines = lines(runs)
        let widths = lines.map { line in
            line.reduce(0) { $0 + face.width($1.text, mono: mono) }
        }
        // The original: `const w = width ?? Math.ceil(Math.max(...widths, 1))`.
        let widest = width > 0 ? width : max(widths.max() ?? 0, 1).rounded(.up)
        let height = Double(lines.count) * lineHeight
        guard widest > 0, height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = oversample
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: widest, height: height), format: format
        )
        let drawn = renderer.image { context in
            context.cgContext.textMatrix = .identity
            for (row, line) in lines.enumerated() {
                // The original rounds where the line starts and then adds the advances as they
                // come, a glyph at a time.
                var x = align == .center ? ((widest - widths[row]) / 2).rounded() : 0
                let y = face.drawTop(ofRow: row)
                for run in line {
                    let attributes: [NSAttributedString.Key: Any] = [
                        .font: face.font, .foregroundColor: run.color,
                    ]
                    for character in run.text {
                        (String(character) as NSString).draw(
                            at: CGPoint(x: x, y: y), withAttributes: attributes
                        )
                        x += face.advance(character, mono: mono)
                    }
                }
            }
        }
        return thresholded(drawn, width: Int(widest.rounded(.up)), height: Int(height))
    }

    /// `image` with every pixel of its glyphs solid (in the colour it was drawn in) and the
    /// rest empty.
    private static func thresholded(_ image: UIImage, width: Int, height: Int) -> UIImage? {
        guard let source = image.cgImage else { return nil }
        let pixelWidth = width * Int(oversample)
        let pixelHeight = height * Int(oversample)
        var bytes = [UInt8](repeating: 0, count: pixelWidth * pixelHeight * 4)
        guard let context = CGContext(
            data: &bytes, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
            bytesPerRow: pixelWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(source, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let covered = bytes[index + 3] >= threshold
            // Premultiplied: what is kept goes back to solid, in its own colour.
            let red = min(255, Int(bytes[index]) * 255 / max(Int(bytes[index + 3]), 1))
            let green = min(255, Int(bytes[index + 1]) * 255 / max(Int(bytes[index + 3]), 1))
            let blue = min(255, Int(bytes[index + 2]) * 255 / max(Int(bytes[index + 3]), 1))
            bytes[index] = covered ? UInt8(red) : 0
            bytes[index + 1] = covered ? UInt8(green) : 0
            bytes[index + 2] = covered ? UInt8(blue) : 0
            bytes[index + 3] = covered ? 255 : 0
        }
        guard let made = context.makeImage() else { return nil }
        return UIImage(cgImage: made, scale: oversample, orientation: .up)
    }
}

enum BarTextAlign {
    case left
    case center
}
