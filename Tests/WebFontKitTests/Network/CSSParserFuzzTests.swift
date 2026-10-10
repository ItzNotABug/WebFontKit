import Foundation
import Testing
@testable import WebFontKit
import WebFontKitTestSupport

@Suite(.timeLimit(.minutes(1)))
struct CSSParserFuzzTests {
    static let captures = [
        "lobster", "inter-four-styles", "noto-sans-jp", "inter-450",
        "material-symbols-outlined", "nabla", "not-found", "invalid-selector",
    ]

    /// 10,000 seeded mutations of the real captures. Each must parse without
    /// crashing, and every URL the mapping hands out must be https.
    static func fuzz(seed: UInt64) {
        var random = SplitMix64(seed: seed)
        let sources = captures.map { Array(Fixtures.css2Text($0).unicodeScalars) }
        let junk: [Unicode.Scalar] = ["{", "}", ";", ":", "(", ")", "'", "\"", "/", "*", "@", ",", " ", "\n", "\\", "h", "😀"]
        let styles = [FontStyle.regular, .bold, .italic, .boldItalic, FontStyle(weight: 500)]
        for _ in 0..<10_000 {
            var text = sources[Int(random.next() % UInt64(sources.count))]
            for _ in 0..<(1 + Int(random.next() % 8)) {
                guard !text.isEmpty else { break }
                let position = Int(random.next() % UInt64(text.count))
                switch random.next() % 4 {
                case 0: text.remove(at: position)
                case 1: text.insert(junk[Int(random.next() % UInt64(junk.count))], at: position)
                case 2:
                    let other = Int(random.next() % UInt64(text.count))
                    text.swapAt(position, other)
                default:
                    let length = min(text.count - position, Int(random.next() % 40))
                    let slice = text[position..<(position + length)]
                    text.insert(contentsOf: slice, at: Int(random.next() % UInt64(text.count)))
                }
            }
            var css = String.UnicodeScalarView()
            css.append(contentsOf: text)
            let faces = CSS2.faces(in: String(css))
            if let urls = try? CSS2.urls(for: styles, in: faces) {
                precondition(urls.values.allSatisfy { $0.scheme == "https" }, "a non-https URL escaped the mapping")
            }
        }
    }

    @Test("10,000 seeded mutations of real answers never crash and never yield a non-https URL")
    func fuzz() async {
        let seed = SplitMix64.seed(default: 20_261_007, label: "CSS parser fuzz")
        #if os(macOS)
        await #expect(processExitsWith: .success) { [seed = seed as UInt64] in
            CSSParserFuzzTests.fuzz(seed: seed)
        }
        #else
        Self.fuzz(seed: seed)
        #endif
    }
}

/// A seeded generator for the fuzz test; the standard library has none.
struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    /// The seed from `WEBFONTKIT_SEED` when set, otherwise `fallback`. Printed before the
    /// first iteration, because a crash leaves no chance to print afterwards.
    static func seed(default fallback: UInt64, label: String) -> UInt64 {
        let seed = ProcessInfo.processInfo.environment["WEBFONTKIT_SEED"].flatMap(UInt64.init) ?? fallback
        print("\(label): seed \(seed) (replay with WEBFONTKIT_SEED=\(seed))")
        return seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
