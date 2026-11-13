//
//  RegistryPositionTestDoubles.swift
//  PalaceTests
//
//  Doubles for the position-write tests (PP-5507): a stepped clock, a switchable
//  account scope, and a recorder that counts registry writes and can hold one
//  write or one save snapshot so a test can place a sign-out next to it.
//

import Foundation
import Combine
@testable import Palace
import PalaceBookModel
import PalaceCatalog
@_spi(Testing) @testable import PalaceBookRegistry

final class PositionTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }
}

/// An account scope whose current library a test can change. `hasCredentials`
/// is false, so the `sync()` the account-switch observer starts ends without
/// fetching or writing.
final class PositionTestAccountScope: AccountScopeProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var current: String
    private let changes = PassthroughSubject<Void, Never>()

    init(_ accountID: String) { current = accountID }

    var currentAccountID: String? {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    var accountDidChangePublisher: AnyPublisher<Void, Never> { changes.eraseToAnyPublisher() }

    func switchTo(_ accountID: String) {
        lock.lock()
        current = accountID
        lock.unlock()
        changes.send(())
    }

    /// Changes the current library without the change notification, for a test
    /// that loads the other account itself.
    func switchToWithoutNotifying(_ accountID: String) {
        lock.lock(); defer { lock.unlock() }
        current = accountID
    }

    func hasCredentials(forAccount accountID: String) -> Bool { false }

    func loansURL(forAccount accountID: String, readinessTimeout: TimeInterval) async throws -> URL? { nil }
}

/// Counts primary registry writes per account directory and can hold the next
/// primary write, or the next save snapshot, of one account until released.
final class RegistryWriteRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var primaryWrites: [String: Int] = [:]
    private var heldPrimaryDirectory: String?
    private var heldSnapshotAccount: String?
    let held = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)

    func primaryWriteCount(underDirectory directory: URL) -> Int {
        lock.lock(); defer { lock.unlock() }
        return primaryWrites[directory.path + "/"] ?? 0
    }

    func holdNextPrimaryWrite(underDirectory directory: URL) {
        lock.lock(); defer { lock.unlock() }
        heldPrimaryDirectory = directory.path + "/"
    }

    func holdNextSaveSnapshot(account: String) {
        lock.lock(); defer { lock.unlock() }
        heldSnapshotAccount = account
    }

    func beforeWrite(_ step: RegistryWriteStep, _ url: URL) {
        guard step == .primary else { return }
        lock.lock()
        // `<account dir>/registry/registry.json`
        let directory = url.deletingLastPathComponent().deletingLastPathComponent().path + "/"
        primaryWrites[directory, default: 0] += 1
        let hold = heldPrimaryDirectory.map { url.path.hasPrefix($0) } ?? false
        if hold { heldPrimaryDirectory = nil }
        lock.unlock()
        if hold { holdUntilReleased() }
    }

    func afterSaveSnapshot(_ account: String) {
        lock.lock()
        let hold = heldSnapshotAccount == account
        if hold { heldSnapshotAccount = nil }
        lock.unlock()
        if hold { holdUntilReleased() }
    }

    /// The bound keeps a broken test from hanging the suite.
    private func holdUntilReleased() {
        held.signal()
        _ = release.wait(timeout: .now() + 20)
    }
}

/// `NoContentDownloadService` that stops the next load in the middle of
/// reading its records, after the registry file has been read, until released.
final class LoadHoldingDownloadService: RegistryDownloadServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var armed = true
    let reached = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)

    func contentPresence(for book: TPPBook, account: String) -> RegistryContentPresence {
        let hold: Bool = lock.withLock { defer { armed = false }; return armed }
        if hold {
            reached.signal()
            // The bound keeps a broken test from hanging the suite.
            _ = release.wait(timeout: .now() + 20)
        }
        return .absent
    }

    func fileUrl(for book: TPPBook, account: String?) -> URL? { nil }
    func startDownload(for book: TPPBook) {}
    func deleteLocalContent(forBook book: TPPBook, account: String?) {}
    func redownloadLCPContentFile(for book: TPPBook) {}
    func contentFileSatisfied(for book: TPPBook, account: String) -> Bool { false }
    func lcpContentFileMissing(for book: TPPBook, account: String) -> Bool { false }
    func isDownloadInFlight(for book: TPPBook) -> Bool { false }
}

/// Nothing on disk and nothing in flight, so `.holding` records load unchanged.
final class NoContentDownloadService: RegistryDownloadServicing, @unchecked Sendable {
    func fileUrl(for book: TPPBook, account: String?) -> URL? { nil }
    func startDownload(for book: TPPBook) {}
    func deleteLocalContent(forBook book: TPPBook, account: String?) {}
    func redownloadLCPContentFile(for book: TPPBook) {}
    func contentFileSatisfied(for book: TPPBook, account: String) -> Bool { false }
    func lcpContentFileMissing(for book: TPPBook, account: String) -> Bool { false }
    func contentPresence(for book: TPPBook, account: String) -> RegistryContentPresence { .absent }
    func isDownloadInFlight(for book: TPPBook) -> Bool { false }
}

struct UnreachableLoansFeed: OPDSFeedFetching {
    func fetchFeed(from url: URL) async throws -> TPPOPDSFeed {
        throw URLError(.notConnectedToInternet)
    }
}

/// A registry over a temporary directory, with the clock, scope and recorder above.
struct PositionRegistryFixture: @unchecked Sendable {
    let root: URL
    let clock = PositionTestClock()
    let recorder = RegistryWriteRecorder()
    let scope: PositionTestAccountScope
    let registry: TPPBookRegistry

    /// Pass the `root` of another fixture to model a relaunch over its files.
    init(account: String, root existingRoot: URL? = nil,
         downloadService: any RegistryDownloadServicing = NoContentDownloadService()) {
        let root = existingRoot ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("RegistryPosition-\(UUID().uuidString)", isDirectory: true)
        let clock = self.clock
        let recorder = self.recorder
        self.root = root
        self.scope = PositionTestAccountScope(account)
        self.registry = TPPBookRegistry(
            accountScope: scope,
            imageLoader: MockImageLoader(),
            dependencies: RegistryExternalDependencies(
                downloadService: { downloadService },
                loansFeedFetcher: { UnreachableLoansFeed() },
                sideloadedIdentifiers: { [] },
                registryDirectory: { root.appendingPathComponent($0, isDirectory: true) },
                onAvailabilityChange: { _, _ in },
                beforeRegistryWrite: { recorder.beforeWrite($0, $1) },
                positionClock: { clock.now },
                afterSaveSnapshot: { recorder.afterSaveSnapshot($0) }
            )
        )
    }

    func accountDirectory(_ account: String) -> URL {
        root.appendingPathComponent(account, isDirectory: true)
    }

    func primaryURL(_ account: String) -> URL {
        accountDirectory(account).appendingPathComponent("registry/registry.json")
    }

    func primaryWrites(_ account: String) -> Int {
        recorder.primaryWriteCount(underDirectory: accountDirectory(account))
    }

    func load(_ account: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            registry.load(account: account) { continuation.resume() }
        }
        await registry._awaitPendingPersistenceForTesting()
    }

    func addBooks(_ ids: [String]) async {
        for id in ids {
            registry.addBook(
                TPPBookMocker.mockBook(identifier: id, title: "Book \(id)", distributorType: .EpubZip),
                location: nil, state: .holding, fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil
            )
        }
        await registry._awaitPendingPersistenceForTesting()
    }

    /// Book identifier to persisted `locationString` ("" for none), or nil when
    /// the account has no registry file.
    func persistedLocations(_ account: String) -> [String: String]? {
        guard let data = try? Data(contentsOf: primaryURL(account)) else { return nil }
        guard case .valid(let records) = RegistryFileRecovery.classify(data: data) else { return nil }
        var result: [String: String] = [:]
        for record in records {
            guard let id = (record["metadata"] as? [String: Any])?["id"] as? String else { continue }
            result[id] = (record["location"] as? [String: Any])?["locationString"] as? String ?? ""
        }
        return result
    }

    func removeFiles() {
        try? FileManager.default.removeItem(at: root)
    }

    static func location(_ value: String) -> TPPBookLocation? {
        TPPBookLocation(locationString: value, renderer: "test-renderer")
    }
}

/// Waits for a semaphore without blocking the caller's executor.
func waitOffMain(_ semaphore: DispatchSemaphore, timeout: TimeInterval) async -> Bool {
    await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
        DispatchQueue.global().async {
            continuation.resume(returning: semaphore.wait(timeout: .now() + timeout) == .success)
        }
    }
}
