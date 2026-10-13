//
//  MockBackendURLProtocol.swift
//  Palace
//
//  URLProtocol subclass that intercepts ALL network requests when active.
//  Routes requests to fixture files based on the active MockScenario.
//  Covers both legacy TPPNetworkExecutor and modern NetworkClient layers.
//

#if DEBUG

import Foundation
import PalaceLogging
import PalaceNetwork

/// Lock-backed holder for `MockBackendURLProtocol`'s cross-thread configuration.
///
/// `URLProtocol` hooks (`canInit`, `startLoading`, the swizzled getter) run on
/// the URL loading system's threads, so this state genuinely lives off the main
/// actor. `@unchecked Sendable` is safe because every stored property is only
/// read or written while holding `lock` — never touched concurrently unguarded.
private final class MockBackendConfigStore: @unchecked Sendable {
    private let lock = NSLock()
    private var _activeScenario: MockScenario?
    private var _scopedHost: String?
    private var _fixtureBundle: Bundle = .main
    private var _fixtureDirectoryPath: String?
    private var _requestCount = 0
    private var _flags: Set<String> = []
    private var _flagsDidChange: (@Sendable (Set<String>) -> Void)?

    /// Changing the scenario clears its flags: they belong to one scenario run.
    var activeScenario: MockScenario? {
        get { lock.lock(); defer { lock.unlock() }; return _activeScenario }
        set {
            lock.lock(); defer { lock.unlock() }
            _activeScenario = newValue
            _flags = []
        }
    }
    var flags: Set<String> {
        get { lock.lock(); defer { lock.unlock() }; return _flags }
        set { lock.lock(); defer { lock.unlock() }; _flags = newValue }
    }
    var flagsDidChange: (@Sendable (Set<String>) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _flagsDidChange }
        set { lock.lock(); defer { lock.unlock() }; _flagsDidChange = newValue }
    }
    /// Raises `flag` and reports the new set outside the lock.
    func raise(_ flag: String) {
        lock.lock()
        let inserted = _flags.insert(flag).inserted
        let snapshot = _flags
        let observer = _flagsDidChange
        lock.unlock()
        if inserted { observer?(snapshot) }
    }
    var scopedHost: String? {
        get { lock.lock(); defer { lock.unlock() }; return _scopedHost }
        set { lock.lock(); defer { lock.unlock() }; _scopedHost = newValue }
    }
    var fixtureBundle: Bundle {
        get { lock.lock(); defer { lock.unlock() }; return _fixtureBundle }
        set { lock.lock(); defer { lock.unlock() }; _fixtureBundle = newValue }
    }
    var fixtureDirectoryPath: String? {
        get { lock.lock(); defer { lock.unlock() }; return _fixtureDirectoryPath }
        set { lock.lock(); defer { lock.unlock() }; _fixtureDirectoryPath = newValue }
    }
    func nextRequestCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        _requestCount += 1
        return _requestCount
    }
}

/// The thread that called `startLoading` and the run loop modes it was running.
///
/// The URL loading system expects every client callback on that thread, which
/// runs its run loop (Apple's CustomHTTPProtocol sample, "Threading Notes":
/// https://developer.apple.com/library/archive/samplecode/CustomHTTPProtocol/Listings/Read_Me_About_CustomHTTPProtocol_txt.html).
/// `@unchecked Sendable`: `CFRunLoop` is thread-safe for `CFRunLoopPerformBlock`
/// and `CFRunLoopWakeUp`, and both stored properties are immutable.
private struct MockClientThread: @unchecked Sendable {
    private let runLoop: CFRunLoop
    private let modes: CFArray

    /// Captures the calling thread. Call from `startLoading`.
    static func current() -> MockClientThread {
        let runLoop = CFRunLoopGetCurrent()!
        var modes: [CFString] = [CFRunLoopMode.defaultMode.rawValue]
        if let mode = CFRunLoopCopyCurrentMode(runLoop), mode != .defaultMode {
            modes.append(mode.rawValue)
        }
        return MockClientThread(runLoop: runLoop, modes: modes as CFArray)
    }

    /// Runs `block` on the client thread's next run loop pass.
    func perform(_ block: @escaping () -> Void) {
        CFRunLoopPerformBlock(runLoop, modes, block)
        CFRunLoopWakeUp(runLoop)
    }
}

// Swift 6 `complete` — `@unchecked Sendable` invariant: this `URLProtocol` subclass
// has NO instance stored properties of its own — all configuration lives in the
// lock-backed `static let config` (`MockBackendConfigStore`, itself
// `@unchecked Sendable`), and `client`/`request` are per-instance state owned and
// serialized by the URL Loading System. `self` is captured only into the deferred
// response-delivery closures below, which run on the thread that called
// `startLoading`. Documented invariant, not a bare waiver.
final class MockBackendURLProtocol: URLProtocol, @unchecked Sendable {

    // MARK: - Static Configuration

    private static let config = MockBackendConfigStore()

    /// The active scenario. When nil, this protocol does not intercept.
    static var activeScenario: MockScenario? {
        get { config.activeScenario }
        set { config.activeScenario = newValue }
    }

    /// Host to scope interception to. When set, only requests to this host
    /// are considered for mocking — requests to other hosts pass through.
    /// Set automatically from the current library's catalog URL on activation.
    static var scopedHost: String? {
        get { config.scopedHost }
        set { config.scopedHost = newValue }
    }

    /// Bundle containing fixture files. Override for test bundles.
    static var fixtureBundle: Bundle {
        get { config.fixtureBundle }
        set { config.fixtureBundle = newValue }
    }

    /// Direct file system path to fixtures directory. When set, bypasses bundle lookup.
    /// Set this in tests where fixtures aren't bundled.
    static var fixtureDirectoryPath: String? {
        get { config.fixtureDirectoryPath }
        set { config.fixtureDirectoryPath = newValue }
    }

    /// Flags raised by routes with `setsFlag` during the active scenario.
    static var flags: Set<String> {
        get { config.flags }
        set { config.flags = newValue }
    }

    /// Called with the full flag set whenever a route raises a new flag, so a
    /// launch-time activation can carry the flags across an app relaunch.
    static var flagsDidChange: (@Sendable (Set<String>) -> Void)? {
        get { config.flagsDidChange }
        set { config.flagsDidChange = newValue }
    }

    // MARK: - URLProtocol Overrides

    override class func canInit(with request: URLRequest) -> Bool {
        // Only intercept when a scenario is active
        guard let scenario = activeScenario else { return false }
        // Don't intercept our own marked requests (prevent infinite recursion)
        guard URLProtocol.property(forKey: "MockBackendHandled", in: request) == nil else {
            return false
        }
        // Only intercept requests to the scoped library host (if set).
        // This prevents the mock from interfering with other libraries
        // when the user switches accounts.
        if let host = scopedHost, request.url?.host != host {
            return false
        }
        // Only intercept requests that match an explicit route.
        // Unmatched requests pass through to the real server so the
        // catalog, cover images, and other non-mocked endpoints work normally.
        let flags = config.flags
        let matched = scenario.routes.contains { $0.matches(request, flags: flags) }
        if !matched, let url = request.url?.absoluteString {
            Log.debug(#file, "MockBackend: pass-through (no route matched) \(request.httpMethod ?? "?") \(url)")
        }
        return matched
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        let requestNum = Self.config.nextRequestCount()
        let clientThread = MockClientThread.current()

        guard let scenario = Self.activeScenario,
              let url = request.url else {
            deliverError(NSError(domain: "MockBackend", code: -1,
                                 userInfo: [NSLocalizedDescriptionKey: "No active scenario or URL"]))
            return
        }

        let method = request.httpMethod ?? "GET"
        Log.info(#file, "MockBackend [\(requestNum)] \(method) \(url.absoluteString)")

        // Find matching route
        let flags = Self.config.flags
        guard let route = scenario.routes.first(where: { $0.matches(request, flags: flags) }) else {
            Log.warn(#file, "MockBackend [\(requestNum)] No route matched, returning 404")
            deliverResponse(on: clientThread,
                           statusCode: 404,
                           contentType: "application/problem+json",
                           data: makeProblemDocument(title: "Not Found",
                                                     detail: "MockBackend: no route matched \(url.path)",
                                                     status: 404))
            return
        }

        Log.info(#file, "MockBackend [\(requestNum)] Matched route: \(route.fixtureName) → \(route.statusCode)")

        if let flag = route.setsFlag {
            Self.config.raise(flag)
        }

        // Load fixture data
        guard let fixtureData = loadFixture(route: route) else {
            deliverError(NSError(domain: "MockBackend", code: -2,
                                 userInfo: [NSLocalizedDescriptionKey: "Fixture \(route.fixtureName) not found"]))
            return
        }

        // Deliver with optional delay
        let delay = route.delayMs.map { Double($0) / 1000.0 } ?? 0

        if delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
                clientThread.perform {
                    self?.deliverResponse(on: clientThread,
                                          statusCode: route.statusCode,
                                          contentType: route.contentType,
                                          data: fixtureData,
                                          additionalHeaders: route.headers)
                }
            }
        } else {
            deliverResponse(on: clientThread,
                           statusCode: route.statusCode,
                           contentType: route.contentType,
                           data: fixtureData,
                           additionalHeaders: route.headers)
        }
    }

    override func stopLoading() {
        // Nothing to cancel — responses are delivered synchronously or via short delay
    }

    // MARK: - Fixture Loading

    private func loadFixture(route: MockRoute) -> Data? {
        let name = route.fixtureName
        let possibleExtensions = ["json", "xml", "atom"]
        var data: Data?

        // Priority 0: embedded fixtures (always available, no bundle needed)
        data = EmbeddedFixtures.data(for: name)

        // Priority 1: direct file system path (set by tests). A name that
        // already carries its extension (a binary fixture such as an EPUB) is
        // read as-is.
        if let dirPath = Self.fixtureDirectoryPath {
            if let d = Self.regularFileContents(atPath: "\(dirPath)/\(name)") {
                data = d
            } else {
                for ext in possibleExtensions {
                    let path = "\(dirPath)/\(name).\(ext)"
                    if let d = FileManager.default.contents(atPath: path) {
                        data = d
                        break
                    }
                }
            }
        }

        // Priority 2: bundle resource lookup (runtime debug menu)
        if data == nil {
            let bundle = Self.fixtureBundle
            for ext in possibleExtensions {
                if let url = bundle.url(forResource: name, withExtension: ext, subdirectory: "Fixtures/API") ??
                             bundle.url(forResource: name, withExtension: ext) {
                    data = try? Data(contentsOf: url)
                    if data != nil { break }
                }
            }
        }

        // Priority 3: fallback to bundle base path
        if data == nil {
            let basePath = Self.fixtureBundle.bundlePath
            for ext in possibleExtensions {
                let path = "\(basePath)/Fixtures/API/\(name).\(ext)"
                if let d = FileManager.default.contents(atPath: path) {
                    data = d
                    break
                }
            }
        }

        guard var fixtureData = data else {
            Log.error(#file, "MockBackend: fixture '\(name)' not found in bundle")
            return nil
        }

        // If fixtureKey is set, extract a sub-object from a dictionary fixture
        if let key = route.fixtureKey {
            if let dict = try? JSONSerialization.jsonObject(with: fixtureData) as? [String: Any],
               let subObject = dict[key] {
                fixtureData = (try? JSONSerialization.data(withJSONObject: subObject)) ?? fixtureData
            }
        }

        return fixtureData
    }

    private static func regularFileContents(atPath path: String) -> Data? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return nil }
        return FileManager.default.contents(atPath: path)
    }

    // MARK: - Response Delivery

    /// Call only on `clientThread`.
    private func deliverResponse(on clientThread: MockClientThread,
                                  statusCode: Int,
                                  contentType: String,
                                  data: Data,
                                  additionalHeaders: [String: String]? = nil) {
        guard let url = request.url else { return }

        var headers: [String: String] = [
            "Content-Type": contentType,
            "Content-Length": "\(data.count)",
            "X-Mock-Backend": "true"
        ]
        additionalHeaders?.forEach { headers[$0.key] = $0.value }

        guard let response = HTTPURLResponse(url: url,
                                              statusCode: statusCode,
                                              httpVersion: "HTTP/1.1",
                                              headerFields: headers) else {
            return
        }

        // Deliver response and data now, then finish on the client thread's next
        // run loop pass. The extra pass lets the URLSession delegate process
        // didReceive(data:) before didCompleteWithError: fires; otherwise
        // TPPNetworkResponder's progressData may be empty when it parses a
        // problem document. Finishing on main instead stalled requests into
        // -1001 timeouts whenever the main thread was busy.
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        clientThread.perform {
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    private func deliverError(_ error: Error) {
        client?.urlProtocol(self, didFailWithError: error)
    }

    private func makeProblemDocument(title: String, detail: String, status: Int) -> Data {
        let doc: [String: Any] = [
            "type": "http://librarysimplified.org/terms/problem/mock-backend",
            "title": title,
            "detail": detail,
            "status": status
        ]
        return (try? JSONSerialization.data(withJSONObject: doc)) ?? Data()
    }
}

#endif
