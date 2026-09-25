//
//  TPPReaderFootnoteAccessibilityDOMTests.swift
//  PalaceTests
//
//  PP-4531 — the leg that was missing.
//
//  `TPPReaderFootnoteAccessibilityTests` covers the Swift classifier and label
//  composer. It cannot fail on a DOM defect, because the only thing it asserts
//  about `annotationJavaScript()` is that its SOURCE TEXT contains some
//  substrings. That is how the shipped build (480) reached QA labelling zero
//  elements: `querySelectorAll('[epub\:type]')` matches only attributes in NO
//  namespace, and Readium serves spine documents as `application/xhtml+xml`, so
//  WKWebView parses them as XML and `epub:type` is in the OPS namespace.
//
//  These tests EXECUTE the production script in a real `WKWebView` against both
//  parse modes and assert the `aria-label`s VoiceOver would actually read.
//

import WebKit
import XCTest
@testable import Palace

@MainActor
final class TPPReaderFootnoteAccessibilityDOMTests: XCTestCase {

  private typealias FA = TPPReaderFootnoteAccessibility

  /// Mirrors the shape of a real Readium spine resource: XML prolog, XHTML
  /// namespace, and `xmlns:epub` — copied from
  /// `readium-sdk/TestData/moby-dick-preview-collection.epub` `OPS/preface_001.xhtml`,
  /// which is the book QA reported against. Extended with a backlink, a
  /// `role`-only reference, and a mixed `epub:type` + `role` element that the
  /// pre-fix `||` chain classified as nothing.
  private static let fixture = """
  <?xml version="1.0" encoding="UTF-8"?>
  <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
  <head><title>Fixture</title><meta charset="utf-8"/></head>
  <body>
  <section epub:type="bodymatter">
  <p id="r1">A sentence with a note.<a epub:type="noteref" href="#n1">1</a></p>
  <p>Another, marked with ARIA only.<a role="doc-noteref" href="#n2">2</a></p>
  <p>And one carrying both.<span epub:type="chapter" role="doc-noteref">3</span></p>
  <aside epub:type="footnote" id="n1">
  <p>The note body.<a epub:type="doc-backlink" href="#r1">back</a></p>
  </aside>
  </section>
  </body>
  </html>
  """

  /// Every element in the document that carries a footnote semantic, counted
  /// WITHOUT the production selector. If this is zero the fixture failed to
  /// parse (malformed XML yields a `parsererror` document), which would
  /// otherwise be indistinguishable from the defect under test.
  private static let groundTruthJS = """
  (function() {
    var OPS = 'http://www.idpf.org/2007/ops';
    var all = document.getElementsByTagName('*'), n = 0;
    for (var i = 0; i < all.length; i++) {
      var el = all[i];
      var t = ((el.getAttributeNS(OPS,'type') || el.getAttribute('epub:type') || '') + ' ' +
               (el.getAttribute('role') || '')).toLowerCase();
      if (/(^|\\s)(doc-)?(noteref|footnote|endnote|rearnote|backlink)(\\s|$)/.test(t)) { n++; }
    }
    return n;
  })()
  """

  /// The `aria-label` on the first element matching a CSS selector, or "" when
  /// the element carries none. This is what VoiceOver reads.
  private static func labelJS(_ selector: String) -> String {
    """
    (function() {
      var el = document.querySelector(\(jsQuoted(selector)));
      if (!el) { return "<<no such element>>"; }
      return el.getAttribute('aria-label') || "";
    })()
    """
  }

  private static func jsQuoted(_ s: String) -> String {
    String(data: (try? JSONEncoder().encode(s)) ?? Data(), encoding: .utf8) ?? "\"\""
  }

  // MARK: - Harness

  @MainActor
  private final class LoadWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var finished = false

    /// Suspends until the navigation completes. Deliberately NOT spelled like
    /// the XCTest waiter: there is no wall-clock deadline here at all — the
    /// continuation is resumed by the navigation delegate itself, which is the
    /// deterministic join seam STARVE-001 asks for. The XCTest spelling would
    /// collide with that rule's pattern on the method name alone.
    func awaitLoad() async {
      await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        if finished { c.resume(); return }
        continuation = c
      }
    }

    private func complete() {
      guard !finished else { return }
      finished = true
      continuation?.resume()
      continuation = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { complete() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { complete() }
    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) { complete() }
  }

  /// Load the fixture under `mimeType`, run the PRODUCTION annotation script,
  /// and return the count it reports. Keeps the web view alive for follow-up
  /// `aria-label` probes.
  private func loadAndAnnotate(
    mimeType: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async throws -> (webView: WKWebView, labelled: Int) {
    let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
    let waiter = LoadWaiter()
    webView.navigationDelegate = waiter
    let data = Data(Self.fixture.utf8)
    webView.load(data,
                 mimeType: mimeType,
                 characterEncodingName: "utf-8",
                 baseURL: URL(fileURLWithPath: NSTemporaryDirectory()))
    await waiter.awaitLoad()

    // The fixture must have parsed, or a "0 labelled" result below would be
    // meaningless rather than a finding.
    let truth = try await evalInt(webView, Self.groundTruthJS)
    XCTAssertEqual(truth, 5,
                   "fixture did not parse as \(mimeType) — 0 labels would be vacuous, not a defect",
                   file: file, line: line)

    let labelled = try await evalInt(webView, FA.annotationJavaScript())
    return (webView, labelled)
  }

  private func evalInt(_ webView: WKWebView, _ js: String) async throws -> Int {
    let value = try await webView.evaluateJavaScript(js)
    if let n = value as? Int { return n }
    if let n = value as? NSNumber { return n.intValue }
    XCTFail("expected a number from JS, got \(String(describing: value))")
    return -1
  }

  private func label(_ webView: WKWebView, _ selector: String) async throws -> String {
    let value = try await webView.evaluateJavaScript(Self.labelJS(selector))
    return (value as? String) ?? "<<not a string>>"
  }

  // MARK: - The regression

  /// THE defect QA hit. Readium serves spine resources as
  /// `application/xhtml+xml`; before the fix this labelled 0 elements and
  /// VoiceOver read the raw link text ("1, link").
  func testAnnotate_whenParsedAsXHTML_labelsNamespacedEpubTypeElements() async throws {
    let (webView, labelled) = try await loadAndAnnotate(mimeType: "application/xhtml+xml")

    XCTAssertEqual(labelled, 5,
                   "namespaced epub:type went unlabelled — VoiceOver reads raw link text")
    let ref = try await label(webView, "a[href='#n1']")
    XCTAssertEqual(ref, "Footnote 1", "noteref must announce its marker, not just 'link'")
    let note = try await label(webView, "aside")
    XCTAssertEqual(note, "Footnote")
    let back = try await label(webView, "a[href='#r1']")
    XCTAssertEqual(back, "Back to reference")
  }

  /// The same script must keep working where the resource is HTML-parsed (the
  /// attribute is then a literal name in no namespace and `getAttributeNS`
  /// returns nil, so the `getAttribute` fallback carries it).
  func testAnnotate_whenParsedAsHTML_stillLabelsEpubTypeElements() async throws {
    let (webView, labelled) = try await loadAndAnnotate(mimeType: "text/html")

    XCTAssertEqual(labelled, 5)
    let ref = try await label(webView, "a[href='#n1']")
    XCTAssertEqual(ref, "Footnote 1")
    let back = try await label(webView, "a[href='#r1']")
    XCTAssertEqual(back, "Back to reference")
  }

  /// A reference marked only with the ARIA `role` — no `epub:type` at all.
  func testAnnotate_roleOnlyReference_isLabelled() async throws {
    let (webView, _) = try await loadAndAnnotate(mimeType: "application/xhtml+xml")
    let ref = try await label(webView, "a[href='#n2']")
    XCTAssertEqual(ref, "Footnote 2")
  }

  /// `epub:type` present but unrelated, `role` carrying the footnote semantic.
  /// The pre-fix `getAttribute('epub:type') || getAttribute('role')` chain
  /// short-circuited on the unrelated value and never consulted `role`.
  func testAnnotate_unrelatedEPUBTypeWithFootnoteRole_stillClassifies() async throws {
    let (webView, _) = try await loadAndAnnotate(mimeType: "application/xhtml+xml")
    let ref = try await label(webView, "span")
    XCTAssertEqual(ref, "Footnote 3",
                   "epub:type and role must be read as one token list, not ||-chained")
  }

  /// Negative control: walking every element must not label ordinary content.
  func testAnnotate_nonFootnoteElements_areNotLabelled() async throws {
    let (webView, _) = try await loadAndAnnotate(mimeType: "application/xhtml+xml")
    let section = try await label(webView, "section")
    XCTAssertEqual(section, "", "epub:type='bodymatter' is not a footnote semantic")
    let paragraph = try await label(webView, "p#r1")
    XCTAssertEqual(paragraph, "", "ordinary paragraphs must keep their own text as their label")
  }

  /// Re-running must not duplicate or drift the labels (the injection fires on
  /// every chapter render).
  func testAnnotate_isIdempotent() async throws {
    let (webView, first) = try await loadAndAnnotate(mimeType: "application/xhtml+xml")
    let second = try await evalInt(webView, FA.annotationJavaScript())
    XCTAssertEqual(second, first, "re-running must re-label the same set")
    let ref = try await label(webView, "a[href='#n1']")
    XCTAssertEqual(ref, "Footnote 1")
  }
}
