//
//  LiveDownloadTaskBoxTests.swift
//  PalaceTests
//
//  PP-4997. `LiveDownloadTaskBox.capture(_:)` is the PRODUCER of the
//  `[Int: URL]` map that launch reconciliation adopts on. Every reconcile test
//  hand-builds that dictionary, which tests the consumer's handling of a map
//  and says nothing about whether the real thing is built correctly — and
//  PP-4997's root cause was precisely a URL that was present on the task and
//  never read. So these drive the producer with real `URLSessionDownloadTask`
//  objects rather than a fixture.
//
//  Tasks are created from a real session and deliberately NOT resumed: nothing
//  here needs a network, and `capture` only reads `originalRequest` /
//  `currentRequest` / `taskIdentifier`, all of which are populated at creation.
//

import XCTest
@testable import Palace

final class LiveDownloadTaskBoxTests: XCTestCase {

  private var session: URLSession!

  override func setUp() {
    super.setUp()
    // A local session rather than `fakeDownloadTask(url:)`, because that helper
    // builds a fresh URLSession per call and every task then reports identifier
    // 1 — which would make the multi-task tests below assert against a
    // collision they created themselves. One session gives distinct
    // identifiers. The stub protocol is the part worth borrowing: nothing here
    // should be able to reach the network even if a task were resumed.
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [NoNetworkURLProtocol.self]
    session = URLSession(configuration: config)
  }

  override func tearDown() {
    session.invalidateAndCancel()
    session = nil
    super.tearDown()
  }

  private func task(_ urlString: String) -> URLSessionDownloadTask {
    session.downloadTask(with: URL(string: urlString)!)
  }

  // MARK: - The ordinary case

  func testCapture_recordsTheTaskAndTheURLItIsFetching() {
    let box = LiveDownloadTaskBox()
    let t = task("https://example.org/book-A.epub")

    XCTAssertTrue(box.capture(t), "a task with a URL must report success")

    XCTAssertEqual(box.capturedURLs[t.taskIdentifier], URL(string: "https://example.org/book-A.epub"),
                   "the captured URL is not the one the task is fetching — "
                   + "reconciliation would adopt against the wrong discriminator")
    XCTAssertTrue(box.capturedTasks[t.taskIdentifier] === t,
                  "the task object itself must be retained for `apply` to adopt")
  }

  /// The identifier is the KEY both sides agree on. If capture keyed the map on
  /// anything else, adoption would hand `applyReconcileDecision` an id that is
  /// not in `box.capturedTasks` and the adopt would silently no-op.
  func testCapture_keysOnTheTaskIdentifier() {
    let box = LiveDownloadTaskBox()
    let t = task("https://example.org/book-A.epub")

    box.capture(t)

    XCTAssertEqual(Array(box.capturedURLs.keys), [t.taskIdentifier])
    XCTAssertEqual(Array(box.capturedTasks.keys), [t.taskIdentifier])
  }

  // MARK: - Several tasks

  func testCapture_severalTasks_keepsEachURLWithItsOwnIdentifier() {
    let box = LiveDownloadTaskBox()
    let a = task("https://example.org/book-A.epub")
    let b = task("https://example.org/book-B.epub")

    box.capture(a)
    box.capture(b)

    XCTAssertNotEqual(a.taskIdentifier, b.taskIdentifier, "precondition")
    XCTAssertEqual(box.capturedURLs[a.taskIdentifier], URL(string: "https://example.org/book-A.epub"))
    XCTAssertEqual(box.capturedURLs[b.taskIdentifier], URL(string: "https://example.org/book-B.epub"))
    XCTAssertEqual(box.capturedURLs.count, 2)
  }

  /// Two tasks fetching ONE url is the shape the contested-URL guard exists for.
  /// Capture must surface both rather than collapsing them, or reconcile can
  /// never see the ambiguity it is supposed to decline.
  func testCapture_twoTasksOnTheSameURL_bothAreRecorded() {
    let box = LiveDownloadTaskBox()
    let shared = "https://example.org/shared.epub"
    let a = task(shared)
    let b = task(shared)

    box.capture(a)
    box.capture(b)

    XCTAssertEqual(box.capturedURLs.count, 2,
                   "one of the two tasks was dropped — reconcile would see a "
                   + "unique URL and adopt an ambiguous download")
    XCTAssertEqual(box.capturedURLs[a.taskIdentifier], box.capturedURLs[b.taskIdentifier])
  }

  // MARK: - The producer's contract with its caller

  /// `capture` reports success so the caller can log the failure case rather
  /// than dropping it silently — a task with no URL can never be adopted and
  /// its book will restart, which is worth a line in the log.
  ///
  /// Only the success arm is reachable here: a task reporting no URL at all
  /// cannot be constructed. The failure arm is driven through
  /// `downloadURL(original:current:)` below, so this asserts what it can and
  /// says which half it is.
  func testCapture_reportsSuccess_whenTheTaskHasAURL() {
    let box = LiveDownloadTaskBox()
    XCTAssertTrue(box.capture(task("https://example.org/book-A.epub")))
    XCTAssertEqual(box.capturedURLs.count, 1)
  }

  // MARK: - The URL decision, driven exhaustively

  // `capture` cannot reach these branches: a URLSessionDownloadTask built from a
  // URL reports the same value for both requests, and one reporting neither
  // cannot be constructed. Mutating the fallback or the nil arm inside `capture`
  // left all six tests above green — which is the seam telling us where the
  // decision belongs, not a gap in diligence.

  func testDownloadURL_prefersOriginalOverCurrent_soARedirectStillMatchesItsRecord() {
    let started = URL(string: "https://example.org/book-A.epub")!
    let redirected = URL(string: "https://cdn.example.net/blob/xyz")!

    XCTAssertEqual(LiveDownloadTaskBox.downloadURL(original: started, current: redirected),
                   started,
                   "the redirected URL was chosen — a redirected download would "
                   + "no longer match the record that persisted its start URL")
  }

  func testDownloadURL_fallsBackToCurrent_whenOriginalIsAbsent() {
    let current = URL(string: "https://cdn.example.net/blob/xyz")!

    XCTAssertEqual(LiveDownloadTaskBox.downloadURL(original: nil, current: current),
                   current,
                   "dropping a task whose originalRequest is nil silently "
                   + "declines to adopt a download that is still running")
  }

  func testDownloadURL_usesOriginal_whenCurrentIsAbsent() {
    let started = URL(string: "https://example.org/book-A.epub")!

    XCTAssertEqual(LiveDownloadTaskBox.downloadURL(original: started, current: nil),
                   started,
                   "a task that reports only an originalRequest was dropped")
  }

  func testDownloadURL_isNil_whenNeitherRequestHasAURL() {
    XCTAssertNil(LiveDownloadTaskBox.downloadURL(original: nil, current: nil),
                 "a URL-less task must be reported, not captured under a bogus key")
  }

}
