import EidolonCore
import SwiftUI
import UIKit

/// The bar package's pictures, read once and kept (`frontend/public/bar/img/*.png`): every
/// `Sprite` names one. A missing one draws nothing, so the bar goes on without it.
@MainActor
final class BarImages {
    nonisolated static let none = BarImages(empty: ())

    let directory: URL?
    /// The type's cache, one set of images a package: a new package is a new directory.
    private var images: [String: UIImage] = [:]
    /// The pixel face from the same package, read and measured once.
    lazy var face = BarFont.Face(font: BarFont.load(in: directory))

    /// The pictures none: what the bar draws when no package is in.
    nonisolated init(empty: Void) {
        directory = nil
    }

    init(directory: URL?) {
        self.directory = directory
    }

    func image(_ name: String) -> UIImage? {
        if let image = images[name] { return image }
        guard let directory else { return nil }
        let url = directory.appending(path: "img/\(name).png")
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        images[name] = image
        return image
    }
}

/// The bar's drawing surface: the 640×360 logical screen, all at once, in the original's
/// coordinates (upstream `BarScreen.tsx`). Children are placed by `left`/`top` in those
/// coordinates and the whole is scaled to the screen's placement, nearest neighbour, so the
/// pictures stay hard pixels.
struct BarStage<Content: View>: View {
    @Environment(\.barImages) private var images
    let placement: BarScreen.Placement
    @ViewBuilder var content: Content

    var body: some View {
        ZStack(alignment: .topLeading) {
            content
        }
        .frame(
            width: CGFloat(BarScreen.width), height: CGFloat(BarScreen.height),
            alignment: .topLeading
        )
        .scaleEffect(
            x: CGFloat(placement.scale), y: CGFloat(placement.scale), anchor: .topLeading
        )
        .frame(
            width: CGFloat(Double(BarScreen.width) * placement.scale),
            height: CGFloat(Double(BarScreen.height) * placement.scale),
            alignment: .topLeading
        )
        .offset(x: CGFloat(placement.left), y: CGFloat(placement.top))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }
}

/// Places a view at `x`/`y` on the bar's screen at the size it takes up there, as a layout
/// container rather than a layer: the original's coordinates are absolute from the screen's
/// top-left corner, so everything the bar draws reads its place from here.
struct BarPlace<Content: View>: View {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    @ViewBuilder var content: Content

    var body: some View {
        // 占位要真的占住位置：`.offset` 不动布局，叠在 ZStack 里就会全挤到同一个角上。
        Color.clear
            .frame(width: CGFloat(max(width, 0)), height: CGFloat(max(height, 0)), alignment: .topLeading)
            .overlay(alignment: .topLeading) {
                content
                    .frame(width: CGFloat(max(width, 0)), height: CGFloat(max(height, 0)), alignment: .topLeading)
                    .clipped()
            }
            .padding(.top, CGFloat(max(y, 0)))
            .padding(.leading, CGFloat(max(x, 0)))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// One of the bar's pictures at its place, at its own size (upstream `Sprite.tsx`).
///
/// A picture never takes a touch: the frame covers the whole screen, and what is drawn under
/// it must be tapped through it (upstream `bar.css` `.bar-stage img, .bar-stage canvas` 的
/// `pointer-events: none`). A `BarHitArea` or a drag laid over a picture is what takes it.
struct BarSprite: View {
    @Environment(\.barImages) private var images
    let name: String
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    var opacity: Double = 1
    /// Turned over left to right (the book's page arrows).
    var flipped = false
    var rotation: Angle = .zero

    var body: some View {
        BarPlace(x: x, y: y, width: width, height: height) {
            if let image = images.image(name) {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.none)
                    .scaleEffect(x: flipped ? -1 : 1, y: 1)
                    .rotationEffect(rotation)
            } else {
                Color.clear
            }
        }
        .opacity(opacity)
        .allowsHitTesting(false)
    }
}

/// The bar's text: one or more runs in their colours, in the pixel font (upstream
/// `PixelText.tsx`). Buttons sit under text and take the touches; the text itself is never
/// tapped.
struct BarPixelText: View {
    @Environment(\.barImages) private var images
    let runs: [BarFont.Run]
    let x: Double
    let y: Double
    /// The width it is laid out in: centred in it when `align` is centred.
    var width: Double = 0
    var align: BarTextAlign = .left
    /// Every glyph in a fixed cell, as the original's `mono`: the counter's and the jukebox's
    /// labels, where the numbers must not jitter as they change.
    var mono = false

    init(_ text: String, x: Double, y: Double, color: UIColor = BarInk.uiText, width: Double = 0, align: BarTextAlign = .left, mono: Bool = false) {
        self.runs = [BarFont.Run(text: text, color: color)]
        self.x = x
        self.y = y
        self.width = width
        self.align = align
        self.mono = mono
    }

    init(runs: [BarFont.Run], x: Double, y: Double, width: Double = 0, align: BarTextAlign = .left, mono: Bool = false) {
        self.runs = runs
        self.x = x
        self.y = y
        self.width = width
        self.align = align
        self.mono = mono
    }

    var body: some View {
        let picture = BarFont.image(
            runs, width: width, align: align, mono: mono, face: images.face
        )
        // 图带着它自己的像素（一个逻辑像素 2 个）和 scale：逻辑尺寸 = 像素 / scale。
        // `UIImage.size` 与它用的 crImage 尺寸有时差一行，按像素和 scale 算才和 `.clipped()` 对得上。
        let size: CGSize = picture.map {
            guard let pixels = $0.cgImage else { return $0.size }
            return CGSize(width: Double(pixels.width) / $0.scale, height: Double(pixels.height) / $0.scale)
        } ?? .zero
        return BarPlace(
            x: x, y: y, width: Double(size.width), height: Double(size.height)
        ) {
            if let picture {
                Image(uiImage: picture).interpolation(.none)
            }
        }
        .allowsHitTesting(false)
    }
}

/// A place on the screen that takes taps and nothing else, a label for screen readers and no
/// sign of its own (upstream `HitArea`); `nil` does nothing and takes nothing.
struct BarHitArea: View {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let label: String
    var enabled = true
    let action: () -> Void

    var body: some View {
        BarPlace(x: x, y: y, width: width, height: height) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(perform: action)
                .accessibilityElement()
                .accessibilityLabel(label)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(.default, action)
        }
        .allowsHitTesting(enabled)
    }
}

/// A white frame with one centred word in it (upstream `BarButton.tsx`): the end card's
/// buttons and the text box's 「再试一次」.
struct BarButton: View {
    @Environment(\.barImages) private var images
    let x: Double
    let y: Double
    let label: String
    let action: () -> Void
    static let width = 72.0
    static let height = 22.0

    var body: some View {
        BarPlace(x: x, y: y, width: Self.width, height: Self.height) {
            Rectangle()
                .strokeBorder(BarInk.text, lineWidth: 1)
            BarPixelText(label, x: 0, y: 3, width: Self.width, align: .center)
            BarHitArea(x: 0, y: 0, width: Self.width, height: Self.height, label: label, action: action)
        }
    }
}

// MARK: - The images' environment

private struct BarImagesKey: EnvironmentKey {
    static let defaultValue = BarImages.none
}

extension EnvironmentValues {
    var barImages: BarImages {
        get { self[BarImagesKey.self] }
        set { self[BarImagesKey.self] = newValue }
    }
}
