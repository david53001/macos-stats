import CoreGraphics
import Testing
@testable import MacStatsCore

@Suite struct TourLayoutTests {
    private let panel = CGRect(x: 0, y: 0, width: 320, height: 404)
    private let cardRadius: CGFloat = 8

    /// The overview's anchor rects in panel points, as the render probe resolved them
    /// (`docs/research/2026-10-06-probes/tour-render/out/insets.txt`).
    private let fixtures: [(id: TourStepID, rect: CGRect, below: Bool)] = [
        (.cpu, CGRect(x: 8, y: 36, width: 304, height: 67), true),
        (.memory, CGRect(x: 8, y: 109, width: 304, height: 67), true),
        (.network, CGRect(x: 8, y: 182, width: 304, height: 67), true),
        (.battery, CGRect(x: 8, y: 255, width: 304, height: 67), false),
        (.footer, CGRect(x: 234, y: 372, width: 78, height: 24), false),
    ]
    /// The callout's measured height (108 pt: title, two body lines' room, footer row), and some
    /// slack either side for other text sizes.
    private let calloutHeights: [CGFloat] = [96, 104.5, 108, 112]

    private func onGrid(_ v: CGFloat, _ scale: CGFloat) -> Bool {
        abs((v * scale).rounded() - v * scale) < 1e-9
    }

    @Test func marginsAreEqualOnFractionalInputs() {
        let targets = [CGRect(x: 8.3, y: 36.27, width: 303.4, height: 66.66),
                       CGRect(x: 8, y: 109.5, width: 304, height: 67.25),
                       CGRect(x: 100.17, y: 200.71, width: 50.33, height: 24.49)]
        for scale: CGFloat in [1, 2, 3] {
            for t in targets {
                let c = TourLayout.cutout(target: t, targetRadius: cardRadius, panel: panel, scale: scale).rect
                let l = t.minX - c.minX, r = c.maxX - t.maxX, top = t.minY - c.minY, b = c.maxY - t.maxY
                #expect(abs(l - r) <= 1 / scale + 1e-9)
                #expect(abs(top - b) <= 1 / scale + 1e-9)
                for m in [l, r, top, b] { #expect(abs(m - TourLayout.cutoutInset) <= 0.5 / scale + 1e-9) }
                for e in [c.minX, c.minY, c.maxX, c.maxY] { #expect(onGrid(e, scale)) }
            }
        }
    }

    @Test func cardOnTheGridIsExactlyCentred() {
        for f in fixtures {
            let c = TourLayout.cutout(target: f.rect, targetRadius: cardRadius, panel: panel, scale: 2).rect
            #expect(c == f.rect.insetBy(dx: -3, dy: -3))
        }
    }

    @Test func radiusIsConcentricWithCardAndPanel() {
        let card = fixtures[0].rect
        let c = TourLayout.cutout(target: card, targetRadius: cardRadius, panel: panel, scale: 2)
        #expect(c.radius == cardRadius + 3)
        // A full-width card: radius + the gap to the panel edge = the panel's 16 pt radius.
        #expect(c.radius + (c.rect.minX - panel.minX) == 16)
        #expect(c.radius + (panel.maxX - c.rect.maxX) == 16)
    }

    @Test func cutoutStaysInsideThePanel() {
        let edge = CGRect(x: 1, y: 0.5, width: 318.5, height: 403)
        let c = TourLayout.cutout(target: edge, targetRadius: cardRadius, panel: panel, scale: 2).rect
        #expect(panel.contains(c))
    }

    @Test func calloutPlacement() {
        for scale: CGFloat in [1, 2, 3] {
            for h in calloutHeights {
                for f in fixtures {
                    let cut = TourLayout.cutout(target: f.rect, targetRadius: cardRadius, panel: panel, scale: scale).rect
                    let co = TourLayout.callout(cutout: cut, height: h, panel: panel, scale: scale)
                    #expect(!co.intersects(cut), "\(f.id)")
                    #expect(panel.insetBy(dx: 8, dy: 8).contains(co), "\(f.id)")
                    #expect(co.minX == 8 && co.width == 304)
                    if f.below {
                        #expect(co.minY - cut.maxY == 6, "\(f.id) below")
                    } else {
                        #expect(cut.minY - co.maxY == 6, "\(f.id) above")
                    }
                    #expect(abs(co.height - h) <= 1 / scale + 1e-9)
                }
            }
        }
    }

    @Test func fallbackWhenNeitherSideFits() {
        // A tall target leaves 60 pt above and 30 pt below: the callout goes above, clamped.
        let cut = CGRect(x: 5, y: 74, width: 310, height: 286)
        let co = TourLayout.callout(cutout: cut, height: 100, panel: panel, scale: 2)
        #expect(co.maxY == cut.minY - 6)
        #expect(co.minY == 8)
        #expect(!co.intersects(cut))
        // More room below than above: below, clamped to the panel margin.
        let low = CGRect(x: 5, y: 20, width: 310, height: 300)
        let co2 = TourLayout.callout(cutout: low, height: 100, panel: panel, scale: 2)
        #expect(co2.minY == low.maxY + 6)
        #expect(co2.maxY == 396)
    }

    @Test func welcomeIsCentred() {
        for scale: CGFloat in [1, 2, 3] {
            for h: CGFloat in [250, 263.3] {
                let w = TourLayout.welcome(height: h, panel: panel, scale: scale)
                #expect(w.minX == 8 && panel.maxX - w.maxX == 8)
                #expect(abs((w.minY - panel.minY) - (panel.maxY - w.maxY)) <= 1 / scale + 1e-9)
            }
        }
    }
}
