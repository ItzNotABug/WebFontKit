import Foundation
import Testing
@testable import WebFontKit

@Suite(.timeLimit(.minutes(1)))
struct FontStyleTests {
    @Test("the named styles are regular, bold, italic and bold italic")
    func namedStyles() {
        #expect(FontStyle.regular == FontStyle(weight: 400, italic: false))
        #expect(FontStyle.bold == FontStyle(weight: 700))
        #expect(FontStyle.italic == FontStyle(weight: 400, italic: true))
        #expect(FontStyle.boldItalic == FontStyle(weight: 700, italic: true))
        #expect(FontStyle() == .regular)
        #expect(FontRequest(family: "Lobster").style == .regular)
        #expect(FontRequest(family: "lobster").family == "lobster")
    }

    @Test("weights from 100 to 900 in steps of 100 are valid", arguments: Array(stride(from: 100, through: 900, by: 100)))
    func validWeights(weight: Int) {
        #expect(FontStyle.isValidWeight(weight))
        #expect(FontStyle(weight: weight).weight == weight)
    }

    @Test("any other weight fails the check the precondition calls", arguments: [0, 50, 99, 150, 401, 450, 950, 1000, -100])
    func invalidWeights(weight: Int) {
        #expect(!FontStyle.isValidWeight(weight))
    }

    #if os(macOS)
    @Test("an invalid weight stops the program", arguments: [0, 450, 1000])
    func invalidWeightTraps(weight: Int) async {
        await #expect(processExitsWith: .failure) { [weight] in
            _ = FontStyle(weight: weight)
        }
    }
    #endif

    @Test("the canonical order puts upright before italic, then sorts by weight")
    func canonicalOrder() {
        let sorted = [FontStyle.boldItalic, .bold, .italic, FontStyle(weight: 100), .regular]
            .sorted(by: FontStyle.canonicalOrder)
        #expect(sorted == [FontStyle(weight: 100), .regular, .bold, .italic, .boldItalic])
    }
}
