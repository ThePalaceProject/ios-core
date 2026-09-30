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

  /// How a load ended. Only `.finished` means the document is there to probe.
  enum LoadOutcome: Equatable {
    case finished
    case failed
    case webContentProcessTerminated
    case notFinished(within: Duration)
  }

  /// Reports the navigation's outcome to one waiter. The navigation delegate is
  /// the join; `bound` is a backstop for the case in which WebKit never calls
  /// it at all. On CI runs 36764880844 and 36756983059 the simulator never
  /// finished launching the WebContent process (runningboardd logged the
  /// launch request, then nothing for two minutes; no WebContent process
  /// existed in the spindump), so no delegate method fired and the test sat
  /// until XCTest's 120 s allowance killed it. An allowance kill is not retried
  /// by `-retry-tests-on-failure` and fails the job; an ordinary failure is
  /// retried in seconds.
  @MainActor
  final class LoadWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<LoadOutcome, Never>?
    private var outcome: LoadOutcome?

    /// Suspends until the navigation reports an outcome, or until `bound`
    /// passes with none. Deliberately NOT spelled like the XCTest waiter,
    /// whose name the STARVE-001 lint matches.
    func awaitLoad(within bound: Duration) async -> LoadOutcome {
      let backstop = Task { @MainActor [weak self] in
        try? await Task.sleep(for: bound)
        guard !Task.isCancelled else { return }
        self?.complete(.notFinished(within: bound))
      }
      defer { backstop.cancel() }
      return await withCheckedContinuation { (c: CheckedContinuation<LoadOutcome, Never>) in
        if let outcome { c.resume(returning: outcome); return }
        continuation = c
      }
    }

    private func complete(_ result: LoadOutcome) {
      guard outcome == nil else { return }
      outcome = result
      continuation?.resume(returning: result)
      continuation = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { complete(.finished) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
      complete(.failed)
    }
    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) { complete(.failed) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
      complete(.webContentProcessTerminated)
    }
  }

  /// Well above a loaded runner's normal load time (the class's per-test median
  /// in CI is under a second), and well below the 120 s allowance.
  private static let loadBound: Duration = .seconds(30)

  /// One web view for the whole class. Every `WKWebView` that loads a document
  /// asks the simulator to launch a WebContent process, and that launch is the
  /// step that stalled on CI; reusing one view makes it once per test process
  /// instead of once per test. Each test still loads the fixture fresh, which
  /// replaces the previous document. Discarded after any load that did not
  /// finish, so a retry starts from a new process.
  private static var sharedWebView: WKWebView?

  private static func webViewForLoad() -> WKWebView {
    if let webView = sharedWebView { return webView }
    let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
    sharedWebView = webView
    return webView
  }

  /// Load the fixture under `mimeType`, run the PRODUCTION annotation script,
  /// and return the count it reports. Keeps the web view alive for follow-up
  /// `aria-label` probes.
  private func loadAndAnnotate(
    mimeType: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async throws -> (webView: WKWebView, labelled: Int) {
    let webView = Self.webViewForLoad()
    let waiter = LoadWaiter()
    webView.navigationDelegate = waiter
    defer { webView.navigationDelegate = nil }
    let data = Data(Self.fixture.utf8)
    webView.load(data,
                 mimeType: mimeType,
                 characterEncodingName: "utf-8",
                 baseURL: URL(fileURLWithPath: NSTemporaryDirectory()))
    let outcome = await waiter.awaitLoad(within: Self.loadBound)
    guard outcome == .finished else {
      Self.sharedWebView = nil
      XCTFail("fixture load as \(mimeType) ended \(outcome), not .finished", file: file, line: line)
      throw LoadDidNotFinish(outcome: outcome)
    }

    // The fixture must have parsed, or a "0 labelled" result below would be
    // meaningless rather than a finding.
    let truth = try await evalInt(webView, Self.groundTruthJS)
    XCTAssertEqual(truth, 5,
                   "fixture did not parse as \(mimeType) — 0 labels would be vacuous, not a defect",
                   file: file, line: line)

    let labelled = try await evalInt(webView, FA.annotationJavaScript())
    return (webView, labelled)
  }

  private struct LoadDidNotFinish: Error {
    let outcome: LoadOutcome
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

  // MARK: - The load harness fails instead of hanging

  /// The CI hang: WebKit never reports the navigation. The waiter must return
  /// at its bound so the test fails as an ordinary (retried) failure.
  func testLoadWaiter_whenNoNavigationOutcomeArrives_returnsNotFinishedAtItsBound() async {
    let waiter = LoadWaiter()
    let started = ContinuousClock.now

    let outcome = await waiter.awaitLoad(within: .milliseconds(200))

    XCTAssertEqual(outcome, .notFinished(within: .milliseconds(200)))
    XCTAssertLessThan(ContinuousClock.now - started, .seconds(20),
                      "the bound must end the wait, not the 120 s allowance")
  }

  func testLoadWaiter_whenNavigationFinishes_returnsFinishedWithoutWaitingForItsBound() async {
    let waiter = LoadWaiter()
    let started = ContinuousClock.now
    Task { @MainActor in waiter.webView(WKWebView(frame: .zero), didFinish: nil) }

    let outcome = await waiter.awaitLoad(within: .seconds(100))

    XCTAssertEqual(outcome, .finished)
    XCTAssertLessThan(ContinuousClock.now - started, .seconds(20))
  }

  func testLoadWaiter_whenWebContentProcessTerminates_reportsItInsteadOfWaiting() async {
    let waiter = LoadWaiter()
    Task { @MainActor in waiter.webViewWebContentProcessDidTerminate(WKWebView(frame: .zero)) }

    let outcome = await waiter.awaitLoad(within: .seconds(100))

    XCTAssertEqual(outcome, .webContentProcessTerminated)
  }
}
