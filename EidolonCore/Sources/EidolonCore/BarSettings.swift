import Foundation

/// The bar's settings (`.scratch/bar-room` 票 14; upstream `lib/barSettings.ts`): the original's
/// settings box, its 「全屏」 and 「窗口化」 left out. Two volumes, the music's (the jukebox's
/// tracks and previews) and the sound effects' (typing included), each in tenths, and the
/// original's scanlines over the screen, on or off. Kept on the device, as the jukebox is.
public struct BarSettings: Sendable, Hashable {
    /// A volume, in tenths: 0 (silent) to 10 (full, as the file is).
    public static let volumeSteps = 10

    public var music: Int
    public var sfx: Int
    public var scanlines: Bool

    public static let `default` = BarSettings(music: volumeSteps, sfx: volumeSteps, scanlines: false)

    public init(music: Int, sfx: Int, scanlines: Bool) {
        self.music = music
        self.sfx = sfx
        self.scanlines = scanlines
    }

    /// The original's slider sprite: how big it is, how wide the −/+ at either end are, where
    /// its groove is, and how big its knob is.
    public struct Slider: Sendable {
        public static let width = 140.0
        public static let height = 17.0
        public static let end = 18.0
        public static let groove = 19.0
        public static let grooveWidth = 102.0
        public static let knobWidth = 4.0
        public static let knobHeight = 19.0
    }

    static func isVolume(_ steps: Int) -> Bool { steps >= 0 && steps <= volumeSteps }
}

extension BarSettings {
    /// A volume as a gain, 0 to 1.
    public static func gain(of steps: Int) -> Double {
        Double(steps) / Double(volumeSteps)
    }

    /// A volume in percent, as it is read out.
    public static func percent(of steps: Int) -> Int {
        Int((gain(of: steps) * 100).rounded())
    }

    /// A volume `by` tenths up or down (the slider's −/+), no further than silent or full.
    public static func stepVolume(_ steps: Int, by: Int) -> Int {
        min(volumeSteps, max(0, steps + by))
    }

    /// The knob's left edge in the slider sprite, for a volume.
    public static func knobX(_ steps: Int) -> Double {
        Slider.groove + ((gain(of: steps) * (Slider.grooveWidth - Slider.knobWidth)).rounded())
    }

    /// The volume a point of the slider sprite (`x`, from its left) stands for, the knob centred
    /// on it: the nearest tenth, no further than the groove's ends.
    public static func volumeAt(x: Double) -> Int {
        let travel = Slider.grooveWidth - Slider.knobWidth
        let along = (x - Slider.groove - Slider.knobWidth / 2) / travel
        return min(volumeSteps, max(0, Int((along * Double(volumeSteps)).rounded())))
    }

    /// What is kept of it, for the app to record beside the bar's other preferences.
    public static func stored(_ settings: BarSettings) -> Stored {
        Stored(music: settings.music, sfx: settings.sfx, scanlines: settings.scanlines)
    }

    /// Recorded as kept, as the app keeps it beside the bar's other preferences.
    public struct Stored: Codable, Hashable {
        public var music: Int
        public var sfx: Int
        public var scanlines: Bool

        public init(music: Int, sfx: Int, scanlines: Bool) {
            self.music = music
            self.sfx = sfx
            self.scanlines = scanlines
        }
    }

    /// The settings a stored record says, each read as it should be: a volume not a whole tenth
    /// from 0 to 10 is full, the scanlines not true or false are off — what upstream's
    /// `storedSettings` does with what it reads.
    public init(stored: Stored?) {
        self.init(
            music: stored.map { Self.isVolume($0.music) ? $0.music : Self.volumeSteps }
                ?? Self.volumeSteps,
            sfx: stored.map { Self.isVolume($0.sfx) ? $0.sfx : Self.volumeSteps }
                ?? Self.volumeSteps,
            scanlines: stored?.scanlines ?? false
        )
    }
}
