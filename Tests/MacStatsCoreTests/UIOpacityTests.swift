import Testing
@testable import MacStatsCore

/// The Opacity setting's value → surface mapping. The key property: 0.5 reproduces the designed
/// look exactly (no solid layer, untouched glass, designed card fill).
@Suite struct UIOpacityTests {
    @Test func defaultIsTheDesignedLook() {
        #expect(UIOpacity.defaultValue == 0.5)
        #expect(UIOpacity.solidBackgroundAlpha(0.5) == 0)
        #expect(UIOpacity.glassTintScale(0.5) == 1)
        #expect(UIOpacity.cardFill(0.5, designed: 0.05) == 0.05)
    }

    @Test func opaqueEndIsFullySolid() {
        #expect(UIOpacity.solidBackgroundAlpha(1) == 1)
        #expect(UIOpacity.solidBackgroundAlpha(0.75) == 0.5)
        #expect(UIOpacity.glassTintScale(1) == 1)
        #expect(UIOpacity.cardFill(1, designed: 0.05) == 0.05)
    }

    @Test func transparentEndThinsToTheClamp() {
        #expect(UIOpacity.solidBackgroundAlpha(0) == 0)
        #expect(UIOpacity.glassTintScale(0) == UIOpacity.minGlassTintScale)
        #expect(abs(UIOpacity.cardFill(0, designed: 0.05) - 0.04) < 1e-12)
        #expect(abs(UIOpacity.glassTintScale(0.25) - (UIOpacity.minGlassTintScale + 1) / 2) < 1e-12)
    }

    @Test func mappingIsMonotonic() {
        var lastSolid = -1.0, lastTint = -1.0, lastFill = -1.0
        for i in 0...100 {
            let v = Double(i) / 100
            let solid = UIOpacity.solidBackgroundAlpha(v)
            let tint = UIOpacity.glassTintScale(v)
            let fill = UIOpacity.cardFill(v, designed: 0.05)
            #expect(solid >= lastSolid && tint >= lastTint && fill >= lastFill)
            lastSolid = solid; lastTint = tint; lastFill = fill
        }
    }

    @Test func outOfRangeValuesAreClamped() {
        #expect(UIOpacity.clamped(-1) == 0)
        #expect(UIOpacity.clamped(2) == 1)
        #expect(UIOpacity.clamped(.nan) == UIOpacity.defaultValue)
        #expect(UIOpacity.solidBackgroundAlpha(5) == 1)
        #expect(UIOpacity.glassTintScale(-3) == UIOpacity.minGlassTintScale)
    }

    @Test func defaultButtonToleratesSliderImprecision() {
        #expect(UIOpacity.isDefault(0.5))
        #expect(UIOpacity.isDefault(0.502))
        #expect(!UIOpacity.isDefault(0.52))
        #expect(!UIOpacity.isDefault(0))
    }
}
