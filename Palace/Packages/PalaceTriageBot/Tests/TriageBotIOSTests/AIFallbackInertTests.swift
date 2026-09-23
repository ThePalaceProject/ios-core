import XCTest
@testable import TriageBotCore

// These tests exercise UIKit-gated code (ClaudeFallbackClassifier in TriageBotIOS,
// TriageBotViewModel in TriageBotUI). On macOS `swift test` both targets compile to
// empty modules (`#if canImport(UIKit)`), so this whole file compiles away there and
// the real assertions run only on an iOS simulator under CI.
#if canImport(UIKit)
@testable import TriageBotIOS
@testable import TriageBotUI

/// URLProtocol that records every request a session (or `URLSession.shared`,
/// when registered globally) attempts to send. Used to prove the AI fallback is
/// inert: zero recorded requests means nothing hit the network.
///
/// Recording is keyed by the **concrete subclass metatype**, not a single
/// shared array. Two test classes each register their own subclass
/// (``InertPathRecordingURLProtocol`` / ``GuardOrderRecordingURLProtocol``), so
/// their request logs are fully isolated even when Xcode runs the classes in
/// parallel. `reset()` / `recordedCount` are `class`-scoped so `self` resolves
/// to the concrete subclass at the call site — a shared `static` array (the
/// prior shape) let a `reset()` or a recorded request in one class bleed into
/// the other's count under concurrent execution.
class RecordingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var recordedByClass: [ObjectIdentifier: [URLRequest]] = [:]

    class func reset() {
        lock.lock(); recordedByClass[ObjectIdentifier(self)] = []; lock.unlock()
    }

    class var recordedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return recordedByClass[ObjectIdentifier(self)]?.count ?? 0
    }

    override class func canInit(with request: URLRequest) -> Bool {
        lock.lock(); recordedByClass[ObjectIdentifier(self), default: []].append(request); lock.unlock()
        // Handle the request so a would-be network call completes (and can't
        // leak to the real network) rather than hanging the test.
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.invalid")!,
            statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Per-test-class recorder for ``AIFallbackInertViewModelTests`` — registered
/// globally so it catches any stray `URLSession.shared` traffic.
final class InertPathRecordingURLProtocol: RecordingURLProtocol {}

/// Per-test-class recorder for ``ClaudeFallbackClassifierGuardOrderTests`` —
/// wired only into that class's ephemeral session.
final class GuardOrderRecordingURLProtocol: RecordingURLProtocol {}

private func recordingSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [GuardOrderRecordingURLProtocol.self]
    return URLSession(configuration: config)
}

private func emptyKnowledgeBase() -> KnowledgeBase {
    KnowledgeBase(catalog: KBCatalog(version: "test", updatedAt: "2026-05-28", entries: []))
}

// MARK: - Inert view-model path (flag off, no classifier wired)

private struct NoopContextProvider: ContextProvider {
    func captureSnapshot() async -> ContextSnapshot {
        ContextSnapshot(appVersion: "1", appBuild: "1", osVersion: "1", deviceModel: "sim")
    }
}

private struct NoopTicketGateway: TicketGateway {
    func submit(_ draft: TicketDraft) async throws -> TicketReceipt {
        TicketReceipt(ticketId: "noop", submittedAt: Date())
    }
}

private struct NoopTelemetrySink: TelemetrySink {
    func emit(_ event: TelemetryEvent) {}
}

final class AIFallbackInertViewModelTests: XCTestCase {

    /// Flag off → the factory wires `fallbackClassifier: nil`. Driving a whole
    /// conversation (including the escalate path) must never touch the network.
    @MainActor
    func testFlagOffConversation_makesZeroNetworkRequests() async {
        URLProtocol.registerClass(InertPathRecordingURLProtocol.self)
        defer { URLProtocol.unregisterClass(InertPathRecordingURLProtocol.self) }
        InertPathRecordingURLProtocol.reset()

        // aiFallbackEnabled: false mirrors the flag-off reducer the factory builds.
        let reducer = ConversationReducer(knowledgeBase: emptyKnowledgeBase(), aiFallbackEnabled: false)
        let viewModel = TriageBotViewModel(
            reducer: reducer,
            contextProvider: NoopContextProvider(),
            ticketGateway: NoopTicketGateway(),
            telemetry: NoopTelemetrySink(),
            fallbackClassifier: nil
        )

        viewModel.send(.start)
        viewModel.send(.userTappedCategory(.audiobook))
        viewModel.send(.inputChanged("some symptom text that will not match any known issue zzz"))
        viewModel.send(.userSubmittedDescription)
        // Drain any effect Tasks the view model may have spawned.
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(InertPathRecordingURLProtocol.recordedCount, 0,
                       "Flag-off conversation must make zero network requests")
    }
}

// MARK: - Classifier guard order (flag on, but no key)

final class ClaudeFallbackClassifierGuardOrderTests: XCTestCase {

    /// With the flag on but NO key present, `classify` must throw
    /// `.apiKeyMissing` BEFORE issuing any network request. This pins the guard
    /// order (rate-limit → key check → network): if a refactor moved the network
    /// call above the key guard, a request would be recorded and this fails.
    func testClassify_withNoKey_throwsApiKeyMissing_beforeAnyRequest() async {
        GuardOrderRecordingURLProtocol.reset()
        let classifier = ClaudeFallbackClassifier(
            keyProvider: { nil },
            session: recordingSession()
        )

        do {
            _ = try await classifier.classify(
                userText: "audiobook won't play",
                category: nil,
                context: nil,
                knowledgeBase: emptyKnowledgeBase()
            )
            XCTFail("Expected FallbackError.apiKeyMissing")
        } catch let error as FallbackError {
            XCTAssertEqual(error, .apiKeyMissing)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(GuardOrderRecordingURLProtocol.recordedCount, 0,
                       "Key guard must fire before any network call")
    }

    /// An empty-string key is treated the same as missing — still no network.
    func testClassify_withEmptyKey_throwsApiKeyMissing_beforeAnyRequest() async {
        GuardOrderRecordingURLProtocol.reset()
        let classifier = ClaudeFallbackClassifier(
            keyProvider: { "" },
            session: recordingSession()
        )

        do {
            _ = try await classifier.classify(
                userText: "audiobook won't play",
                category: nil,
                context: nil,
                knowledgeBase: emptyKnowledgeBase()
            )
            XCTFail("Expected FallbackError.apiKeyMissing")
        } catch let error as FallbackError {
            XCTAssertEqual(error, .apiKeyMissing)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(GuardOrderRecordingURLProtocol.recordedCount, 0,
                       "Key guard must fire before any network call")
    }
}
#endif
