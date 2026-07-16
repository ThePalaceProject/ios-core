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
final class RecordingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var _recorded: [URLRequest] = []

    static func reset() {
        lock.lock(); _recorded = []; lock.unlock()
    }

    static var recordedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _recorded.count
    }

    override class func canInit(with request: URLRequest) -> Bool {
        lock.lock(); _recorded.append(request); lock.unlock()
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

private func recordingSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [RecordingURLProtocol.self]
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
        URLProtocol.registerClass(RecordingURLProtocol.self)
        defer { URLProtocol.unregisterClass(RecordingURLProtocol.self) }
        RecordingURLProtocol.reset()

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

        XCTAssertEqual(RecordingURLProtocol.recordedCount, 0,
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
        RecordingURLProtocol.reset()
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

        XCTAssertEqual(RecordingURLProtocol.recordedCount, 0,
                       "Key guard must fire before any network call")
    }

    /// An empty-string key is treated the same as missing — still no network.
    func testClassify_withEmptyKey_throwsApiKeyMissing_beforeAnyRequest() async {
        RecordingURLProtocol.reset()
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

        XCTAssertEqual(RecordingURLProtocol.recordedCount, 0,
                       "Key guard must fire before any network call")
    }
}
#endif
