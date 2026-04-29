//
//  NetworkTransportContractTests.swift
//  PalaceNetworkTests
//
//  Contract tests for NetworkTransport + ActiveTasksStore. These exercise
//  the public surface without hitting the network — pause/resume/cancel
//  must be no-ops on an empty store, and clearCache must not crash when
//  there's no cache. The transport must also produce a usable URLSession.
//

import XCTest
@testable import PalaceNetwork

final class NetworkTransportContractTests: XCTestCase {

    // MARK: - Init produces a usable URLSession

    func testInit_WithCachingStrategy_ProducesUsableURLSession() {
        let transport = NetworkTransport(delegate: nil,
                                         cachingStrategy: .default,
                                         requestTimeout: 30.0)
        // urlSession is the public surface — it must exist and have non-zero timeout
        XCTAssertGreaterThan(transport.urlSession.configuration.timeoutIntervalForRequest, 0,
                             "URLSession must have a non-zero request timeout for requests to be schedulable")
        XCTAssertEqual(transport.urlSession.configuration.timeoutIntervalForRequest, 30.0,
                       "Request timeout must round-trip through init")
    }

    func testInit_EphemeralCachingStrategy_DistinctFromDefault() {
        // The .ephemeral and .default branches must produce distinguishable
        // configs. We check the urlCache identity — .ephemeral uses the
        // system's in-memory cache; .default uses TPPCaching's custom cache.
        let ephemeral = NetworkTransport(delegate: nil,
                                         cachingStrategy: .ephemeral,
                                         requestTimeout: 30.0)
        let standard = NetworkTransport(delegate: nil,
                                        cachingStrategy: .default,
                                        requestTimeout: 30.0)
        // Their cache instances must not be the same object.
        XCTAssertFalse(ephemeral.urlSession.configuration.urlCache === standard.urlSession.configuration.urlCache,
                       "Ephemeral and default caching strategies must produce distinct urlCache instances")
        // The default config sets httpMaximumConnectionsPerHost to 8;
        // ephemeral inherits the system default (which is not 8).
        XCTAssertEqual(standard.urlSession.configuration.httpMaximumConnectionsPerHost, 8,
                       ".default strategy must set httpMaximumConnectionsPerHost to 8 (documented contract)")
    }

    func testInit_WithExplicitConfiguration_UsesProvidedConfig() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 17.0
        let transport = NetworkTransport(delegate: nil,
                                         sessionConfiguration: config,
                                         requestTimeout: 30.0)
        XCTAssertEqual(transport.urlSession.configuration.timeoutIntervalForRequest, 17.0,
                       "Explicit URLSessionConfiguration must override the requestTimeout argument")
    }

    // MARK: - Pause/resume/cancel are no-ops on empty store

    func testPauseAllTasks_OnEmptyStore_DoesNotCrash() {
        let transport = NetworkTransport(delegate: nil,
                                         cachingStrategy: .default,
                                         requestTimeout: 30.0)
        // Must not crash, must not throw
        transport.pauseAllTasks()
    }

    func testResumeAllTasks_OnEmptyStore_DoesNotCrash() {
        let transport = NetworkTransport(delegate: nil,
                                         cachingStrategy: .default,
                                         requestTimeout: 30.0)
        transport.resumeAllTasks()
    }

    func testCancelNonEssentialTasks_OnEmptyStore_DoesNotCrash() {
        let transport = NetworkTransport(delegate: nil,
                                         cachingStrategy: .default,
                                         requestTimeout: 30.0)
        transport.cancelNonEssentialTasks()
    }

    // MARK: - clearCache never crashes

    func testClearCache_OnDefaultConfiguration_DoesNotCrash() {
        let transport = NetworkTransport(delegate: nil,
                                         cachingStrategy: .default,
                                         requestTimeout: 30.0)
        transport.clearCache()
    }

    func testClearCache_OnEphemeralConfiguration_NoCacheDoesNotCrash() {
        let transport = NetworkTransport(delegate: nil,
                                         cachingStrategy: .ephemeral,
                                         requestTimeout: 30.0)
        // Ephemeral has no urlCache — clearCache must handle nil gracefully
        transport.clearCache()
    }

    // MARK: - ActiveTasksStore add/remove invariants

    func testActiveTasksStore_AddThenCancelNonEssential_ReturnsAtLeastOne() {
        let store = ActiveTasksStore()
        // Build a real URLSessionTask with a non-audiobook URL
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: URL(string: "https://example.com/api/books")!)
        store.add(task)
        let cancelled = store.cancelNonEssential()
        XCTAssertEqual(cancelled, 1,
                       "A non-audiobook task must be counted as cancelled by cancelNonEssential")
    }

    func testActiveTasksStore_AudiobookURL_NotCancelledByCancelNonEssential() {
        let store = ActiveTasksStore()
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: URL(string: "https://example.com/audiobook/foo.mp3")!)
        store.add(task)
        let cancelled = store.cancelNonEssential()
        XCTAssertEqual(cancelled, 0,
                       "Audiobook tasks must be preserved during account-switch cancellation")
    }
}
