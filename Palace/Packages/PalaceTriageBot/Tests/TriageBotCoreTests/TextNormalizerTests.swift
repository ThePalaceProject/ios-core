import XCTest
@testable import TriageBotCore

/// Guards the single comparison space patron text + KB keywords are folded into
/// before substring matching. The bugs these pin are invisible to the rest of
/// the suite because the benchmark corpus is authored in ASCII in a Swift file —
/// a real iPhone keyboard produces the curly forms.
final class TextNormalizerTests: XCTestCase {

    func testNormalize_foldsSmartApostropheToASCII() {
        // iOS smart punctuation types U+2019, not the ASCII apostrophe the KB
        // keywords are written with. Without folding, "won't play" typed on a
        // stock keyboard matches neither "won't play" nor "wont play".
        let smart = "I won\u{2019}t play it"        // curly apostrophe
        let normalized = TextNormalizer.normalize(smart)
        XCTAssertTrue(normalized.contains("won't play"),
                      "Curly apostrophe must fold to ASCII so keyword substrings match")
    }

    func testNormalize_foldsHyphenVariantsToASCII() {
        let nonBreaking = "grayed\u{2011}out boxes"  // U+2011 non-breaking hyphen
        let enDash = "grayed\u{2013}out boxes"       // U+2013 en dash
        XCTAssertTrue(TextNormalizer.normalize(nonBreaking).contains("grayed-out"))
        XCTAssertTrue(TextNormalizer.normalize(enDash).contains("grayed-out"))
    }

    func testNormalize_lowercases() {
        XCTAssertEqual(TextNormalizer.normalize("WON'T Play"), "won't play")
    }

    func testNormalize_isIdempotentOnASCII() {
        let ascii = "audiobook won't play, just hangs"
        XCTAssertEqual(TextNormalizer.normalize(ascii), ascii)
    }
}
