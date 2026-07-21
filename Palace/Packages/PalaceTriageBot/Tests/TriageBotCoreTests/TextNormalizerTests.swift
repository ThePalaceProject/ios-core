import XCTest
@testable import TriageBotCore

/// Guards the single comparison space patron text + KB keywords are folded into
/// before substring matching. The bugs these pin are invisible to the rest of
/// the suite because the benchmark corpus is authored in ASCII in a Swift file —
/// a real iPhone keyboard produces the curly/dash forms.
final class TextNormalizerTests: XCTestCase {

    // The full variant contract. Every one of these must fold, or a real-device
    // keystroke silently stops matching. Looping pins each fold independently
    // (a per-character test would let five of six survive a pruned fold list).
    private static let apostropheVariants: [Character] = ["\u{2019}", "\u{2018}", "\u{02BC}"]
    private static let hyphenVariants: [Character] = [
        "\u{2010}", "\u{2011}", "\u{2012}", "\u{2013}", "\u{2014}", "\u{2212}"
    ]

    func testEveryApostropheVariant_foldsToASCII() {
        for variant in Self.apostropheVariants {
            let input = "I won\(variant)t play it"
            XCTAssertTrue(
                TextNormalizer.normalize(input).contains("won't play"),
                "apostrophe variant U+\(String(variant.unicodeScalars.first!.value, radix: 16)) must fold to ASCII"
            )
        }
    }

    func testEveryHyphenVariant_foldsToASCII() {
        for variant in Self.hyphenVariants {
            let input = "grayed\(variant)out boxes"
            XCTAssertTrue(
                TextNormalizer.normalize(input).contains("grayed-out"),
                "hyphen variant U+\(String(variant.unicodeScalars.first!.value, radix: 16)) must fold to ASCII"
            )
        }
    }

    func testNormalize_lowercases() {
        XCTAssertEqual(TextNormalizer.normalize("WON'T Play"), "won't play")
    }

    func testNormalize_isIdempotent() {
        // Folding a folded string must be a no-op — otherwise repeated
        // application (keyword + user text both folded) could drift.
        let raw = "AUDIOBOOK won\u{2019}t play \u{2014} just hangs \u{1F620}"
        let once = TextNormalizer.normalize(raw)
        XCTAssertEqual(TextNormalizer.normalize(once), once)
    }

    func testNormalize_emptyAndWhitespace() {
        XCTAssertEqual(TextNormalizer.normalize(""), "")
        XCTAssertEqual(TextNormalizer.normalize("   "), "   ")
    }

    func testNormalize_passesThroughEmojiAndUnrelatedUnicode() {
        // Only apostrophes/hyphens fold; everything else survives untouched.
        let input = "caf\u{00E9} \u{1F4DA} book"   // café 📚 book
        XCTAssertEqual(TextNormalizer.normalize(input), "café 📚 book")
    }

    func testNormalize_multipleAndMixedApostrophes() {
        let mixed = "it won\u{2019}t open and doesn't start"  // curly + straight
        let out = TextNormalizer.normalize(mixed)
        XCTAssertTrue(out.contains("won't open"))
        XCTAssertTrue(out.contains("doesn't start"))
    }
}
