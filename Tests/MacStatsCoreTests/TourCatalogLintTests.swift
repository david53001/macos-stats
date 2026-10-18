import AppKit
import Testing
@testable import MacStatsCore

@Suite @MainActor struct TourCatalogLintTests {
    private var steps: [TourStep] { TourCatalog.steps }
    private var allStrings: [String] {
        steps.flatMap { [$0.title, $0.body] } + TourCatalog.buttons + [
            TourCatalog.welcomeTitle, TourCatalog.welcomeBody, TourCatalog.alertsPermission,
            TourCatalog.finderPermission, TourCatalog.welcomeQuestion, TourCatalog.welcomeSubline,
            TourCatalog.helpRow,
        ]
    }

    private func words(_ s: String) -> Int { s.split(whereSeparator: \.isWhitespace).count }

    @Test func titlesAndBodiesAreShort() {
        for step in steps {
            #expect(words(step.title) <= 4, "\(step.title)")
            #expect(words(step.body) <= 20, "\(step.body)")
            let sentences = step.body.split(separator: ".", omittingEmptySubsequences: true)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            #expect((1...2).contains(sentences.count), "\(step.body)")
        }
    }

    @Test func typographicApostrophesOnly() {
        for s in allStrings { #expect(!s.contains("'"), "\(s)") }
    }

    @Test func stepsAreUniqueAndAnchored() {
        #expect(Set(steps.map(\.title)).count == steps.count)
        #expect(steps.map(\.id) == TourStepID.allCases)
        for step in steps { #expect(step.anchor == "overview.\(step.id.rawValue)") }
    }

    /// Apple's title style: every word capitalised except short articles and prepositions.
    @Test func buttonsAreTitleCase() {
        let minor: Set<Substring> = ["a", "an", "the", "and", "or", "of", "to", "in", "on"]
        for label in TourCatalog.buttons {
            for (i, word) in label.split(separator: " ").enumerated() where i == 0 || !minor.contains(word) {
                #expect(word.first?.isUppercase == true, "\(label)")
            }
        }
    }

    @Test func noLiveNumbers() {
        for s in allStrings {
            #expect(s.range(of: #"\d+\s*(%|GB)"#, options: .regularExpression) == nil, "\(s)")
        }
    }

    /// Each body fits the callout's two lines (304 pt wide, 12 pt padding) in its real font.
    @Test func bodiesFitTwoLines() {
        let font = NSFont.preferredFont(forTextStyle: .callout)
        for step in steps {
            let storage = NSTextStorage(string: step.body, attributes: [.font: font])
            let layout = NSLayoutManager()
            let container = NSTextContainer(size: CGSize(width: 280, height: CGFloat.greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            storage.addLayoutManager(layout)
            layout.ensureLayout(for: container)
            var lines = 0
            layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { _, _, _, _, _ in
                lines += 1
            }
            #expect(lines <= 2, "\(step.body): \(lines) lines")
        }
    }
}
