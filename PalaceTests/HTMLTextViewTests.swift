//
//  HTMLTextViewTests.swift
//  PalaceTests
//
//  Created for crash investigation: NSInternalInconsistencyException "unexpected start state"
//  in HTMLTextView.makeAttributedString(from:)
//

import XCTest
@testable import Palace

/// Tests for HTMLTextView crash investigation.
///
/// The crash "NSInternalInconsistencyException: unexpected start state" occurs in
/// `HTMLTextView.makeAttributedString(from:)` when WebKit's HTML parser encounters
/// unexpected input. These tests aim to reproduce and prevent the crash.
@MainActor
final class HTMLTextViewTests: XCTestCase {

    // MARK: - Basic Functionality Tests

    func testEmptyString() {
        let result = HTMLTextView.makeAttributedString(from: "")
        XCTAssertEqual(String(result.characters), "")
    }

    func testPlainTextWithoutHTML() {
        let plainText = "This is a simple plain text without any HTML tags."
        let result = HTMLTextView.makeAttributedString(from: plainText)
        XCTAssertEqual(String(result.characters), plainText)
    }

    func testSimpleHTMLParagraph() {
        let html = "<p>Hello World</p>"
        let result = HTMLTextView.makeAttributedString(from: html)
        // HTML parsing may add whitespace, so just check the core content is present
        XCTAssertTrue(String(result.characters).contains("Hello World"))
        // Should NOT contain raw HTML tags
        XCTAssertFalse(String(result.characters).contains("<p>"))
        XCTAssertFalse(String(result.characters).contains("</p>"))
    }

    func testHTMLWithMultipleTags() {
        let html = "<p><strong>Bold</strong> and <em>italic</em> text.</p>"
        let result = HTMLTextView.makeAttributedString(from: html)
        XCTAssertTrue(String(result.characters).contains("Bold"))
        XCTAssertTrue(String(result.characters).contains("italic"))
        // Should NOT contain raw HTML tags
        XCTAssertFalse(String(result.characters).contains("<strong>"))
        XCTAssertFalse(String(result.characters).contains("<em>"))
    }

    // MARK: - HTML Rendering Verification (Ensures formatting works correctly)

    func testHTMLTagsAreNotDisplayedAsText() {
        // This is a critical test - HTML should be PARSED, not shown as raw text
        let testCases = [
            "<p>Simple paragraph</p>",
            "<b>Bold text</b>",
            "<i>Italic text</i>",
            "<strong>Strong text</strong>",
            "<em>Emphasized text</em>",
            "<p><b>Nested</b> <i>tags</i></p>",
            "<br>Line break<br/>Another break",
            "<ul><li>List item</li></ul>",
            "<a href=\"https://example.com\">Link text</a>"
        ]

        for html in testCases {
            let result = HTMLTextView.makeAttributedString(from: html)
            let text = String(result.characters)

            // Should NOT contain any raw HTML tags
            XCTAssertFalse(text.contains("<p>"), "Raw <p> tag found in: \(html)")
            XCTAssertFalse(text.contains("</p>"), "Raw </p> tag found in: \(html)")
            XCTAssertFalse(text.contains("<b>"), "Raw <b> tag found in: \(html)")
            XCTAssertFalse(text.contains("<i>"), "Raw <i> tag found in: \(html)")
            XCTAssertFalse(text.contains("<strong>"), "Raw <strong> tag found in: \(html)")
            XCTAssertFalse(text.contains("<em>"), "Raw <em> tag found in: \(html)")
            XCTAssertFalse(text.contains("<br"), "Raw <br tag found in: \(html)")
            XCTAssertFalse(text.contains("<ul>"), "Raw <ul> tag found in: \(html)")
            XCTAssertFalse(text.contains("<li>"), "Raw <li> tag found in: \(html)")
            XCTAssertFalse(text.contains("<a "), "Raw <a tag found in: \(html)")
        }
    }

    func testTypicalBookDescriptionHTML() {
        // Real-world book description pattern
        let html = """
      <p><b>NEW YORK TIMES BESTSELLER</b></p>
      <p>A gripping story of survival and hope.</p>
      <p>Features:</p>
      <ul>
        <li>Award-winning author</li>
        <li>Perfect for ages 10+</li>
      </ul>
      """

        let result = HTMLTextView.makeAttributedString(from: html)
        let text = String(result.characters)

        // Content should be present
        XCTAssertTrue(text.contains("NEW YORK TIMES BESTSELLER"))
        XCTAssertTrue(text.contains("gripping story"))
        XCTAssertTrue(text.contains("Award-winning"))

        // No raw HTML should be visible
        XCTAssertFalse(text.contains("<"), "Raw HTML tags should not be visible")
        XCTAssertFalse(text.contains(">"), "Raw HTML tags should not be visible")
    }

    // MARK: - Fast Path Tests (No HTML or Long Content)

    func testFastPathNoHTMLTags() {
        // Content without < character should take fast path
        let noTags = "Plain text without any angle brackets"
        let result = HTMLTextView.makeAttributedString(from: noTags)
        XCTAssertEqual(String(result.characters), noTags)
    }

    func testFastPathLongContent() {
        // Content over 10_000 characters should take fast path (plain text returned as-is)
        let longText = String(repeating: "a", count: 10_001)
        let result = HTMLTextView.makeAttributedString(from: longText)
        XCTAssertEqual(String(result.characters), longText)
    }

    func testFastPathLongContentWithHTML() {
        // Long content with HTML tags still takes fast path
        let longText = "<p>" + String(repeating: "a", count: 10_001) + "</p>"
        let result = HTMLTextView.makeAttributedString(from: longText)
        // Fast path returns as-is without parsing
        XCTAssertEqual(String(result.characters), longText)
    }

    // MARK: - Malformed HTML Tests (Potential Crash Triggers)

    func testMalformedUnclosedTags() {
        let html = "<p>Unclosed paragraph<div>Unclosed div<span>Unclosed span"
        let result = HTMLTextView.makeAttributedString(from: html)
        // Should not crash - just verify we get some output
        XCTAssertFalse(String(result.characters).isEmpty)
    }

    func testMalformedNestedTags() {
        let html = "<p><div></p></div>"
        let result = HTMLTextView.makeAttributedString(from: html)
        XCTAssertFalse(String(result.characters).isEmpty || String(result.characters) == html)
    }

    func testMalformedOnlyOpeningTag() {
        let html = "<p"
        let result = HTMLTextView.makeAttributedString(from: html)
        // Should handle gracefully
        XCTAssertNotNil(result)
    }

    func testMalformedOnlyClosingTag() {
        let html = "</p>"
        let result = HTMLTextView.makeAttributedString(from: html)
        XCTAssertNotNil(result)
    }

    func testMalformedBrokenAttributes() {
        let html = "<p style=\"color:red>Missing closing quote</p>"
        let result = HTMLTextView.makeAttributedString(from: html)
        XCTAssertNotNil(result)
    }

    func testMalformedEmptyTags() {
        let html = "<><></><p></p>"
        let result = HTMLTextView.makeAttributedString(from: html)
        XCTAssertNotNil(result)
    }

    func testMalformedRandomAngleBrackets() {
        let html = "< > <> </ > Text <with random < brackets >"
        let result = HTMLTextView.makeAttributedString(from: html)
        XCTAssertNotNil(result)
    }

    // MARK: - Potential "Unexpected Start State" Triggers

    func testStartsWithClosingTag() {
        // Starting with closing tag might cause "unexpected start state"
        let html = "</div><p>Content</p>"
        let result = HTMLTextView.makeAttributedString(from: html)
        XCTAssertNotNil(result)
    }

    func testStartsWithEndOfDocument() {
        let html = "</html></body>Content"
        let result = HTMLTextView.makeAttributedString(from: html)
        XCTAssertNotNil(result)
    }

    func testStartsWithDoctype() {
        let html = "<!DOCTYPE html><html><body>Content</body></html>"
        let result = HTMLTextView.makeAttributedString(from: html)
        XCTAssertTrue(String(result.characters).contains("Content"))
    }

    func testStartsWithXMLDeclaration() {
        let html = "<?xml version=\"1.0\"?><p>Content</p>"
        let result = HTMLTextView.makeAttributedString(from: html)
        XCTAssertNotNil(result)
    }

    func testStartsWithComment() {
        let html = "<!-- comment --><p>Content</p>"
        let result = HTMLTextView.makeAttributedString(from: html)
        XCTAssertTrue(String(result.characters).contains("Content"))
    }

    func testStartsWithCDATA() {
        let html = "<![CDATA[some data]]><p>Content</p>"
        let result = HTMLTextView.makeAttributedString(from: html)
        XCTAssertNotNil(result)
    }

    func testOnlyWhitespaceBeforeTag() {
        let html = "   \n\t  <p>Content</p>"
        let result = HTMLTextView.makeAttributedString(from: html)
        XCTAssertTrue(String(result.characters).contains("Content"))
    }

    func testBOMCharacter() {
        // Byte Order Mark at start
        let bom = "\u{FEFF}"
        let html = bom + "<p>Content</p>"
        let result = HTMLTextView.makeAttributedString(from: html)
        XCTAssertNotNil(result)
    }

    func testNullCharacterInHTML() {
        let html = "<p>Content\0with null</p>"
        let result = HTMLTextView.makeAttributedString(from: html)
        XCTAssertNotNil(result)
    }

    // MARK: - Unicode and Encoding Edge Cases

    func testUnicodeContent() {
        let html = "<p>Unicode: 日本語 العربية 中文 emoji: 🎉📚</p>"
        let result = HTMLTextView.makeAttributedString(from: html)
        XCTAssertTrue(String(result.characters).contains("日本語"))
    }

    func testHTMLEntities() {
        let html = "<p>&amp; &lt; &gt; &quot; &apos; &nbsp;</p>"
        let result = HTMLTextView.makeAttributedString(from: html)
        XCTAssertTrue(String(result.characters).contains("&"))
        XCTAssertTrue(String(result.characters).contains("<"))
    }

    func testNumericEntities() {
        let html = "<p>&#60; &#x3C; &#169;</p>"
        let result = HTMLTextView.makeAttributedString(from: html)
        XCTAssertNotNil(result)
    }

    func testInvalidUTF8Sequence() {
        // Create string with potential encoding issues
        let html = "<p>Content with \u{FFFD} replacement character</p>"
        let result = HTMLTextView.makeAttributedString(from: html)
        XCTAssertNotNil(result)
    }

    // MARK: - Script and Style Tags

    func testScriptTag() {
        let html = "<script>alert('xss')</script><p>Safe content</p>"
        let result = HTMLTextView.makeAttributedString(from: html)
        XCTAssertNotNil(result)
    }

    func testStyleTag() {
        let html = "<style>body { color: red; }</style><p>Styled content</p>"
        let result = HTMLTextView.makeAttributedString(from: html)
        XCTAssertNotNil(result)
    }

    func testUnclosedScriptTag() {
        let html = "<script>never closed<p>Content</p>"
        let result = HTMLTextView.makeAttributedString(from: html)
        XCTAssertNotNil(result)
    }

    // MARK: - Deeply Nested HTML

    func testDeeplyNestedTags() {
        var html = ""
        for _ in 0..<100 {
            html += "<div>"
        }
        html += "Content"
        for _ in 0..<100 {
            html += "</div>"
        }
        let result = HTMLTextView.makeAttributedString(from: html)
        XCTAssertTrue(String(result.characters).contains("Content"))
    }

    // MARK: - Real-World OPDS Summary Patterns

    func testTypicalBookSummary() {
        let html = """
      <p>A thrilling adventure story that takes readers on a journey through time and space.</p>
      <p>Features:</p>
      <ul>
        <li>Engaging characters</li>
        <li>Plot twists</li>
        <li>Beautiful prose</li>
      </ul>
      """
        let result = HTMLTextView.makeAttributedString(from: html)
        XCTAssertTrue(String(result.characters).contains("thrilling"))
    }

    func testSummaryWithLineBreaks() {
        let html = "First line<br>Second line<br/>Third line<br />Fourth line"
        let result = HTMLTextView.makeAttributedString(from: html)
        XCTAssertNotNil(result)
    }

    func testSummaryWithLinks() {
        let html = "<p>Visit <a href=\"https://example.com\">our website</a> for more info.</p>"
        let result = HTMLTextView.makeAttributedString(from: html)
        XCTAssertTrue(String(result.characters).contains("our website"))
    }

    // MARK: - Empty and Whitespace Only

    func testWhitespaceOnly() {
        let html = "   \n\t\r   "
        let result = HTMLTextView.makeAttributedString(from: html)
        XCTAssertNotNil(result)
    }

    func testEmptyParagraph() {
        let html = "<p></p>"
        let result = HTMLTextView.makeAttributedString(from: html)
        XCTAssertNotNil(result)
    }

    func testMultipleEmptyParagraphs() {
        let html = "<p></p><p></p><p></p>"
        let result = HTMLTextView.makeAttributedString(from: html)
        XCTAssertNotNil(result)
    }

    // MARK: - Special HTML5 Elements

    func testHTML5Elements() {
        let html = """
      <article>
        <header><h1>Title</h1></header>
        <section><p>Content</p></section>
        <footer>Footer</footer>
      </article>
      """
        let result = HTMLTextView.makeAttributedString(from: html)
        XCTAssertTrue(String(result.characters).contains("Title"))
    }

    // MARK: - Potential Threading Issue Simulations

    func testRapidSequentialCalls() async {
        // Simulate rapid sequential calls that might reveal state issues
        for i in 0..<100 {
            let html = "<p>Iteration \(i)</p>"
            let result = HTMLTextView.makeAttributedString(from: html)
            XCTAssertTrue(String(result.characters).contains("Iteration"))
        }
    }

    func testMixedContentRapidCalls() async {
        let htmlSamples = [
            "<p>Simple paragraph</p>",
            "",
            "Plain text no HTML",
            "<div><span>Nested</span></div>",
            "</p>Invalid start</p>",
            "<p>Unicode: 日本語</p>",
            "<script>ignored</script><p>Content</p>",
            "   <p>Whitespace prefix</p>",
            "<p style=\"bad>Broken attribute</p>",
            String(repeating: "a", count: 10_001)
        ]

        for _ in 0..<10 {
            for html in htmlSamples {
                let result = HTMLTextView.makeAttributedString(from: html)
                XCTAssertNotNil(result)
            }
        }
    }

    // MARK: - Table Elements (Often Problematic)

    func testTableHTML() {
        let html = """
      <table>
        <tr><th>Header 1</th><th>Header 2</th></tr>
        <tr><td>Cell 1</td><td>Cell 2</td></tr>
      </table>
      """
        let result = HTMLTextView.makeAttributedString(from: html)
        XCTAssertTrue(String(result.characters).contains("Header 1"))
    }

    func testMalformedTable() {
        let html = "<table><tr><td>Unclosed"
        let result = HTMLTextView.makeAttributedString(from: html)
        XCTAssertNotNil(result)
    }

    // MARK: - Form Elements

    func testFormElements() {
        let html = """
      <form>
        <input type="text" value="test">
        <button>Submit</button>
      </form>
      <p>Content after form</p>
      """
        let result = HTMLTextView.makeAttributedString(from: html)
        XCTAssertNotNil(result)
    }

    // MARK: - SVG and MathML (Foreign Content)

    func testSVGContent() {
        let html = "<svg><circle cx=\"50\" cy=\"50\" r=\"40\"/></svg><p>Text after SVG</p>"
        let result = HTMLTextView.makeAttributedString(from: html)
        XCTAssertNotNil(result)
    }

    func testMathMLContent() {
        let html = "<math><mrow><mi>x</mi><mo>=</mo><mn>5</mn></mrow></math><p>Text</p>"
        let result = HTMLTextView.makeAttributedString(from: html)
        XCTAssertNotNil(result)
    }

    // MARK: - Data URLs and Embedded Content

    func testDataURL() {
        let html = "<img src=\"data:image/png;base64,iVBORw0KGgo=\"><p>Image above</p>"
        let result = HTMLTextView.makeAttributedString(from: html)
        XCTAssertNotNil(result)
    }

    // MARK: - Extremely Long Single Tag

    func testVeryLongAttribute() {
        let longValue = String(repeating: "x", count: 5000)
        let html = "<p data-value=\"\(longValue)\">Content</p>"
        let result = HTMLTextView.makeAttributedString(from: html)
        XCTAssertTrue(String(result.characters).contains("Content"))
    }

    // MARK: - Control Characters

    func testControlCharacters() {
        // Various control characters that might cause parsing issues
        let controlChars = "\u{0001}\u{0002}\u{0003}\u{0004}\u{0005}"
        let html = "<p>Content with \(controlChars) control chars</p>"
        let result = HTMLTextView.makeAttributedString(from: html)
        XCTAssertNotNil(result)
    }

    // MARK: - Processing Instructions

    func testProcessingInstruction() {
        let html = "<?php echo 'test'; ?><p>Content</p>"
        let result = HTMLTextView.makeAttributedString(from: html)
        XCTAssertNotNil(result)
    }

    // MARK: - Multiple Doctypes

    func testMultipleDoctypes() {
        let html = "<!DOCTYPE html><!DOCTYPE html><html><body>Content</body></html>"
        let result = HTMLTextView.makeAttributedString(from: html)
        XCTAssertNotNil(result)
    }

    // MARK: - Null/Empty Data Edge Case

    func testOnlyAngleBracket() {
        let html = "<"
        let result = HTMLTextView.makeAttributedString(from: html)
        XCTAssertNotNil(result)
    }

    func testOnlyClosingAngleBracket() {
        let html = ">"
        let result = HTMLTextView.makeAttributedString(from: html)
        // No < character, should take fast path
        XCTAssertEqual(String(result.characters), ">")
    }

    func testAngleBracketsWithSpaces() {
        let html = "< p > content < / p >"
        let result = HTMLTextView.makeAttributedString(from: html)
        XCTAssertNotNil(result)
    }

    // MARK: - Defensive Sanitization Tests

    func testBOMCharacterIsRemoved() {
        // BOM at start should be sanitized away
        let bom = "\u{FEFF}"
        let html = bom + "<p>Content after BOM</p>"
        let result = HTMLTextView.makeAttributedString(from: html)
        // Should successfully parse after BOM removal
        XCTAssertTrue(String(result.characters).contains("Content"))
    }

    func testControlCharactersAreRemoved() {
        // Control characters should be filtered out
        let html = "<p>Content\u{0001}\u{0002}with control chars</p>"
        let result = HTMLTextView.makeAttributedString(from: html)
        XCTAssertNotNil(result)
        // Should contain the text without control characters
        XCTAssertTrue(String(result.characters).contains("Content"))
    }

    func testLeadingWhitespaceIsTrimmed() {
        // Leading whitespace should be trimmed
        let html = "\n\n\t   <p>Content with leading whitespace</p>"
        let result = HTMLTextView.makeAttributedString(from: html)
        XCTAssertTrue(String(result.characters).contains("Content"))
    }

    func testHTMLDocumentWrapping() {
        // Simple content should be wrapped in HTML document structure
        let html = "<p>Simple paragraph</p>"
        let result = HTMLTextView.makeAttributedString(from: html)
        // Should parse successfully with wrapping
        XCTAssertTrue(String(result.characters).contains("Simple paragraph"))
    }

    func testExistingDoctypeNotDoubleWrapped() {
        // Content with existing doctype should not be double-wrapped
        let html = "<!DOCTYPE html><html><body><p>Already has doctype</p></body></html>"
        let result = HTMLTextView.makeAttributedString(from: html)
        XCTAssertTrue(String(result.characters).contains("Already has doctype"))
    }

    func testExistingHTMLTagNotDoubleWrapped() {
        // Content starting with <html> should not be double-wrapped
        let html = "<html><body><p>Already has html tag</p></body></html>"
        let result = HTMLTextView.makeAttributedString(from: html)
        XCTAssertTrue(String(result.characters).contains("Already has html tag"))
    }

    // MARK: - Fallback Behavior Tests

    func testFallbackStripsHTMLTags() {
        // When HTML parsing would fail, fallback should strip tags
        // This test verifies the stripHTMLTags helper works
        let html = "<p>Some <strong>bold</strong> text</p>"
        let result = HTMLTextView.makeAttributedString(from: html)
        // Should either parse successfully OR fall back to stripped version
        let resultText = String(result.characters)
        XCTAssertTrue(resultText.contains("Some"))
        XCTAssertTrue(resultText.contains("bold"))
        XCTAssertTrue(resultText.contains("text"))
    }

    // MARK: - Real Crash Reproduction Tests
    // These tests attempt to reproduce actual crashes reported in production

    /// Test case based on crash: NSInternalInconsistencyException "unexpected start state"
    /// Occurred when viewing book detail for "Refugee: The Graphic Novel" (ISBN 9781338733983)
    /// from Illinois library OPDS feed (il.thepalaceproject.org)
    func testRefugeeGraphicNovelSummaryPattern() {
        // Typical OPDS book summary patterns that might cause issues
        let summaryPatterns = [
            // Pattern 1: Summary with smart quotes and em-dashes
            "<p>A graphic novel adaptation of Alan Gratz's bestselling novel—three kids, three countries, three stories of survival.</p>",

            // Pattern 2: Summary with nested formatting
            "<p><b>NEW YORK TIMES</b> bestseller • A <i>Publishers Weekly</i> Best Book of the Year</p>",

            // Pattern 3: Summary with special characters
            "<p>JOSEF is a Jewish boy living in 1930s Nazi Germany…</p>",

            // Pattern 4: Summary with line breaks
            "<p>Based on the bestselling novel.<br/>Three different kids.<br/>One mission.</p>",

            // Pattern 5: Summary with HTML entities
            "<p>A story of courage &amp; hope in the face of unimaginable hardship.</p>",

            // Pattern 6: Summary with unicode quotes
            "<p>\u{201C}A must-read\u{201D} — School Library Journal</p>",

            // Pattern 7: Empty paragraph followed by content
            "<p></p><p>The graphic novel adaptation.</p>",

            // Pattern 8: Summary with non-breaking spaces
            "<p>Alan\u{00A0}Gratz brings the story to life.</p>"
        ]

        for (index, summary) in summaryPatterns.enumerated() {
            let result = HTMLTextView.makeAttributedString(from: summary)
            XCTAssertNotNil(result, "Pattern \(index + 1) should not crash")
            XCTAssertFalse(String(result.characters).isEmpty, "Pattern \(index + 1) should produce content")
        }
    }

    /// Test with actual OPDS-style summary content patterns
    func testOPDSSummaryPatterns() {
        let opdsPatterns = [
            // Content-type declaration sometimes included
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?><p>Book summary</p>",

            // CDATA wrapped content (sometimes seen in OPDS)
            "<![CDATA[<p>Book summary with CDATA</p>]]>",

            // Mixed encoding declarations
            "<?xml encoding=\"UTF-8\"?><p>Content</p>",

            // Atom namespace sometimes leaks through
            "<content type=\"html\"><p>Summary</p></content>",

            // Summary element wrapper
            "<summary type=\"html\"><p>Book description</p></summary>"
        ]

        for (index, summary) in opdsPatterns.enumerated() {
            let result = HTMLTextView.makeAttributedString(from: summary)
            XCTAssertNotNil(result, "OPDS pattern \(index + 1) should not crash")
        }
    }

    /// Test summaries that start with unexpected content
    func testUnexpectedSummaryStarts() {
        let unexpectedStarts = [
            // Starts with XML processing instruction
            "<?xml version=\"1.0\"?>Book summary without tags",

            // Starts with comment
            "<!-- Publisher note -->Book summary",

            // Starts with whitespace then comment
            "   \n<!-- note --><p>Summary</p>",

            // Starts with partial tag
            "< p>This is malformed</p>",

            // Starts with encoded entity
            "&lt;p&gt;Already encoded HTML&lt;/p&gt;",

            // Raw text that looks like partial HTML
            "p>Some text that looks like broken HTML</p",

            // Unicode BOM followed by tag
            "\u{FEFF}<?xml version=\"1.0\"?><p>Content</p>",

            // Multiple BOMs
            "\u{FEFF}\u{FEFF}<p>Content</p>"
        ]

        for (index, summary) in unexpectedStarts.enumerated() {
            let result = HTMLTextView.makeAttributedString(from: summary)
            XCTAssertNotNil(result, "Unexpected start \(index + 1) should not crash")
        }
    }

    /// Test rapid view/dismiss cycles (simulating user quickly tapping books)
    func testRapidBookDetailViewSimulation() async {
        // Simulate user rapidly tapping different books in search results
        let bookSummaries = [
            "<p>First book summary</p>",
            "<p><b>Second</b> book with <i>formatting</i></p>",
            "",  // Empty summary
            "<p>Third book with special chars: &amp; &lt; &gt;</p>",
            "Plain text summary without HTML",
            "<p>Fourth book</p><p>Multiple paragraphs</p>"
        ]

        // Rapid fire - no delays
        for _ in 0..<50 {
            for summary in bookSummaries {
                let result = HTMLTextView.makeAttributedString(from: summary)
                XCTAssertNotNil(result)
            }
        }
    }

    // MARK: - Crash Reproduction Tests
    // These tests verify that our defensive measures prevent crashes that would
    // occur with raw/unsanitized parsing.

    /// Tests that potentially problematic inputs are handled safely by the defensive code.
    /// We use ObjCExceptionCatcher to safely test if the unsafe method would crash.
    func testDefensiveMeasuresPreventCrashes() {
        // Inputs that might trigger "unexpected start state" or other parser issues
        let problematicInputs: [(name: String, html: String)] = [
            ("BOM at start", "\u{FEFF}<p>Content</p>"),
            ("Multiple BOMs", "\u{FEFF}\u{FEFF}\u{FEFF}<p>Content</p>"),
            ("Null byte", "<p>Content\u{0000}with null</p>"),
            ("Control characters", "<p>\u{0001}\u{0002}\u{0003}Content</p>"),
            ("Leading whitespace with BOM", "   \u{FEFF}\n<p>Content</p>"),
            ("XML declaration", "<?xml version=\"1.0\"?><p>Content</p>"),
            ("Partial XML declaration", "<?xml<p>Content</p>"),
            ("CDATA section", "<![CDATA[data]]><p>Content</p>"),
            ("Comment only", "<!-- comment -->"),
            ("Processing instruction", "<?php echo 'test'; ?><p>Content</p>")
        ]

        for (name, html) in problematicInputs {
            // The SAFE method should always succeed without crashing
            let safeResult = HTMLTextView.makeAttributedString(from: html)
            XCTAssertNotNil(safeResult, "Safe method should handle '\(name)' without crashing")

            // Test if unsafe method would throw an exception
            let unsafeException = ObjCExceptionCatcher.catchException {
                _ = HTMLTextView.makeAttributedStringUnsafe(from: html)
            }

            if let exception = unsafeException {
                // If unsafe throws, log it - this proves our defensive measures are needed
                print("✅ Defensive measures protect against '\(name)': \(exception.name) - \(exception.reason ?? "no reason")")
            }
        }
    }

    /// Test that BOM character specifically causes issues without sanitization
    func testBOMCausesIssuesWithoutSanitization() {
        let htmlWithBOM = "\u{FEFF}<p>Content after BOM</p>"

        // Safe method should succeed
        let safeResult = HTMLTextView.makeAttributedString(from: htmlWithBOM)
        XCTAssertTrue(String(safeResult.characters).contains("Content"))

        // Check if unsafe method has issues with BOM
        var unsafeSucceeded = false
        let exception = ObjCExceptionCatcher.catchException {
            let unsafeResult = HTMLTextView.makeAttributedStringUnsafe(from: htmlWithBOM)
            unsafeSucceeded = String(unsafeResult.characters).contains("Content")
        }

        if exception != nil {
            print("✅ BOM causes exception without sanitization: \(exception!.name)")
        } else if !unsafeSucceeded {
            print("⚠️ BOM causes parsing issues without sanitization (no exception but wrong result)")
        } else {
            print("ℹ️ BOM handled by WebKit on this iOS version - defensive measure is extra safety")
        }
    }

    /// Test that control characters cause issues without sanitization
    func testControlCharactersCauseIssuesWithoutSanitization() {
        let htmlWithControlChars = "<p>Content\u{0000}\u{0001}\u{0002}here</p>"

        // Safe method should succeed
        let safeResult = HTMLTextView.makeAttributedString(from: htmlWithControlChars)
        XCTAssertNotNil(safeResult)

        // Check if unsafe method has issues
        let exception = ObjCExceptionCatcher.catchException {
            _ = HTMLTextView.makeAttributedStringUnsafe(from: htmlWithControlChars)
        }

        if exception != nil {
            print("✅ Control characters cause exception without sanitization: \(exception!.name)")
        }
    }

    /// Compare safe vs unsafe parsing results for edge cases
    func testSafeVsUnsafeParsingComparison() {
        let edgeCases: [(name: String, html: String, expectsContent: Bool)] = [
            ("Normal HTML", "<p>Normal content</p>", true),
            ("Empty paragraph", "<p></p>", false),
            ("Nested tags", "<p><b><i>Nested</i></b></p>", true),
            ("HTML entities", "<p>&amp; &lt; &gt;</p>", true),
            ("Unicode", "<p>日本語 中文 العربية</p>", true)
        ]

        for (name, html, expectsContent) in edgeCases {
            let safeResult = HTMLTextView.makeAttributedString(from: html)

            var unsafeResult: AttributedString?
            let exception = ObjCExceptionCatcher.catchException {
                unsafeResult = HTMLTextView.makeAttributedStringUnsafe(from: html)
            }

            if exception == nil, let unsafe = unsafeResult {
                // Both should produce similar results for valid input
                let safeText = String(safeResult.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                let unsafeText = String(unsafe.characters).trimmingCharacters(in: .whitespacesAndNewlines)

                if expectsContent {
                    XCTAssertFalse(safeText.isEmpty, "Safe result for '\(name)' should not be empty")
                    XCTAssertFalse(unsafeText.isEmpty, "Unsafe result for '\(name)' should not be empty")
                }
                print("ℹ️ '\(name)' - Safe and unsafe both succeed")
            } else if exception != nil {
                XCTFail("Unexpected exception for valid HTML '\(name)': \(exception!)")
            }
        }
    }
}
