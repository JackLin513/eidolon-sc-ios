import EidolonCore
import SwiftUI
import UIKit

/// 设置框 (upstream `BarSettingsBox.tsx`): the original's settings box with its 「全屏」 and
/// 「窗口化」 rows cut out, over the guest's window. 「背景音乐」 and 「音效」 are the original's
/// sliders — −/+ a step apiece, a tap on the groove, or the knob dragged; 「扫描线」 toggles.
/// A tap outside the box closes it.
struct BarSettingsBox: View {
    /// The original's box (`set_frame`), over the guest's window.
    static let frame = (x: 95.0, y: 47.0, width: 258.0, height: 200.0)
    /// Where the sliders start, from the box's left.
    static let slideX = frame.x + 39
    /// Each slider: its word over it, and where it is.
    static let sliders = (
        music: (label: "set_bgm", labelWidth: 55.0, labelY: frame.y + 42, slide: "set_bgm_slide", y: frame.y + 61),
        sfx: (label: "set_sfx", labelWidth: 27.0, labelY: frame.y + 88, slide: "set_sfx_slide", y: frame.y + 107)
    )
    static let labelHeight = 13.0
    /// The groove's tap area: from the end of 「−」 to the start of 「+」.
    static let grooveWidth = BarSettings.Slider.width - 2 * BarSettings.Slider.end
    /// 「扫描线 On/Off」 under 「图像」, and the white bar behind it.
    static let scan = (
        x: frame.x + 38, y: frame.y + 162, height: 14.0,
        width: (on: 98.0, off: 100.0),
        bar: (x: frame.x + 31, y: frame.y + 160, width: 174.0, height: 22.0)
    )
    /// A slider that cannot be set is drawn faint.
    static let faint = 0.35

    let settings: BarSettings.Stored
    let hasAudio: Bool
    let play: (String) -> Void
    let onChange: (BarSettings.Stored) -> Void
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            // 点框外关上；框里点空白处不关。
            BarHitArea(
                x: 0, y: 0, width: Double(BarScreen.width), height: Double(BarScreen.height),
                label: BarCopy.Settings.close, action: onClose
            )
            Color.clear
                .frame(width: Self.frame.width, height: Self.frame.height)
                .contentShape(Rectangle())
                .allowsHitTesting(false)
                .offset(x: Self.frame.x, y: Self.frame.y)
            BarSprite(
                name: "set_frame", x: Self.frame.x, y: Self.frame.y, width: Self.frame.width,
                height: Self.frame.height
            )
            slider(.music, settings.music, enabled: hasAudio)
            slider(.sfx, settings.sfx, enabled: hasAudio)
            BarSprite(
                name: "set_scan_\(settings.scanlines ? "on" : "off")",
                x: Self.scan.x, y: Self.scan.y,
                width: settings.scanlines ? Self.scan.width.on : Self.scan.width.off,
                height: Self.scan.height
            )
            BarHitArea(
                x: Self.scan.bar.x, y: Self.scan.bar.y, width: Self.scan.bar.width,
                height: Self.scan.bar.height, label: BarCopy.Settings.scanlines
            ) {
                var next = settings
                next.scanlines.toggle()
                play("buttonclick")
                onChange(next)
            }
        }
    }

    private enum Which {
        case music, sfx

        var name: String {
            self == .music ? BarCopy.Settings.music : BarCopy.Settings.sfx
        }

        var value: (label: String, labelWidth: Double, labelY: Double, slide: String, y: Double) {
            self == .music ? Self.musicValue : Self.sfxValue
        }

        static let musicValue = BarSettingsBox.sliders.music
        static let sfxValue = BarSettingsBox.sliders.sfx
    }

    private func slider(_ which: Which, _ value: Int, enabled: Bool) -> some View {
        let at = (label: which.value.label, labelWidth: which.value.labelWidth, labelY: which.value.labelY, slide: which.value.slide, y: which.value.y)
        let dim = enabled ? 1 : Self.faint
        return ZStack(alignment: .topLeading) {
            BarSprite(
                name: at.label, x: Self.slideX, y: at.labelY, width: at.labelWidth,
                height: Self.labelHeight, opacity: dim
            )
            BarSprite(
                name: at.slide, x: Self.slideX, y: at.y, width: BarSettings.Slider.width,
                height: BarSettings.Slider.height, opacity: dim
            )
            BarSprite(
                name: "set_knob", x: Self.slideX + BarSettings.knobX(value), y: at.y - 1,
                width: BarSettings.Slider.knobWidth, height: BarSettings.Slider.knobHeight, opacity: dim
            )
            if enabled {
                BarHitArea(
                    x: Self.slideX, y: at.y, width: BarSettings.Slider.end,
                    height: BarSettings.Slider.height, label: BarCopy.Settings.quieter(which.name)
                ) {
                    change(which, BarSettings.stepVolume(value, by: -1))
                }
                BarHitArea(
                    x: Self.slideX + BarSettings.Slider.width - BarSettings.Slider.end, y: at.y,
                    width: BarSettings.Slider.end, height: BarSettings.Slider.height,
                    label: BarCopy.Settings.louder(which.name)
                ) {
                    change(which, BarSettings.stepVolume(value, by: 1))
                }
                Color.clear
                    .frame(width: Self.grooveWidth, height: BarSettings.Slider.knobHeight)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { drag in
                                let ratio = min(max(Double(drag.location.x) / Self.grooveWidth, 0), 1)
                                change(
                                    which, BarSettings.volumeAt(x: BarSettings.Slider.end + ratio * Self.grooveWidth)
                                )
                            }
                    )
                    .offset(x: Self.slideX + BarSettings.Slider.end, y: at.y - 1)
                    .accessibilityElement()
                    .accessibilityLabel(BarCopy.Settings.volume(which.name, value))
                    .accessibilityValue(BarCopy.Settings.volume(which.name, value))
            }
        }
    }

    private func change(_ which: Which, _ value: Int) {
        var next = settings
        let current = which == .music ? settings.music : settings.sfx
        guard value != current else { return }
        if which == .music { next.music = value } else { next.sfx = value }
        // 音效调了响一声，听得出多响。
        if which == .sfx { play("buttonclick") }
        onChange(next)
    }
}
