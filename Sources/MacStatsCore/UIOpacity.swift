import Foundation

/// The "Opacity" appearance setting and how its value maps onto the popover's surfaces.
///
/// Shared spec (identical in MacStats, JVoice and BetterScreenshot):
/// `docs/design-language/opacity-setting.md` §2. The value is a `Double` in 0…1 stored under
/// `uiOpacity` in the standard defaults; 0.5 is the designed default look, 1.0 is solid, 0.0 is
/// as see-through as the surface can go while staying legible. Everything is piecewise-linear
/// through the default, so 0.5 always reproduces today's look exactly.
public enum UIOpacity {
    public static let key = "uiOpacity"
    public static let defaultValue = 0.5

    /// Lowest multiplier applied to the Liquid Glass tint at 0.0. Clamp: measured over a white
    /// page (dark mode) and a black one (light mode), primary text keeps ≥ 3:1 contrast here;
    /// below it the glass lets too much of a bright/dark backdrop through for the text
    /// (see `docs/superpowers/plans/2026-09-30-opacity-progress.md`).
    public static let minGlassTintScale = 0.25

    /// Card fill at 0.0, as a fraction of the designed fill (0.05 → 0.04).
    public static let minCardFillScale = 0.8

    public static func clamped(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : defaultValue
    }

    /// Close enough to the default that the "Default" button has nothing to reset
    /// (a continuous slider rarely lands exactly on 0.5).
    public static func isDefault(_ value: Double) -> Bool {
        abs(clamped(value) - defaultValue) < 0.005
    }

    /// Alpha of the solid window-background layer behind the cards: none up to the default,
    /// rising linearly to fully opaque at 1.0.
    public static func solidBackgroundAlpha(_ value: Double) -> Double {
        let v = clamped(value)
        return v <= defaultValue ? 0 : (v - defaultValue) / (1 - defaultValue)
    }

    /// Multiplier on the system glass tint: unchanged from the default up (the solid layer takes
    /// over there), thinning linearly to `minGlassTintScale` at 0.0.
    public static func glassTintScale(_ value: Double) -> Double {
        let v = clamped(value)
        guard v < defaultValue else { return 1 }
        return minGlassTintScale + (1 - minGlassTintScale) * (v / defaultValue)
    }

    /// Card fill for the setting: the designed fill from the default up, thinning gently
    /// (to 80 %) toward 0.0 so the cards stay faint over a more see-through panel.
    public static func cardFill(_ value: Double, designed: Double) -> Double {
        let v = clamped(value)
        guard v < defaultValue else { return designed }
        return designed * (minCardFillScale + (1 - minCardFillScale) * (v / defaultValue))
    }
}
