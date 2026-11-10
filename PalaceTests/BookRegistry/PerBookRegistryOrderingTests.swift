//
//  PerBookRegistryOrderingTests.swift
//  PalaceTests
//
//  PP-5507: which per-book file wins at load, and when the last-good backup is
//  written. Layout and rules: docs/architecture/per-book-registry-storage.md.
//

import XCTest
@testable import Palace
import PalaceBookModel
@_spi(Testing) @testable import PalaceBookRegistry

@MainActor
final class PerBookRegistryOrderingTests: PerBookRegistryTestCase {

    /// How long a change made inside a save's sequence window may wait for the
    /// shelf. It waits the whole time when the save holds the shelf, as it must.
    private let windowWait: DispatchTimeInterval = .milliseconds(500)

    // MARK: - Sequence and shelf taken together

    /// A position saved while a shelf save takes its sequence must not win over
    /// a newer position that save captured: the reload shows the newest
    /// position that reached any per-book file.
    func testShelfSave_PositionSavedInsideItsSequenceWindow_NewestPositionLoads() async throws {
        try await seedMigratedShelf()
        let registry = await launch()
        let wait = windowWait
        sequenceHook.armOnce {
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                registry.setLocation(self.locationValue("a-2"), forIdentifier: "a")
                registry.setLocationDeferringSave(self.locationValue("a-3"), forIdentifier: "a")
                _ = registry.location(forIdentifier: "a")
                done.signal()
            }
            _ = done.wait(timeout: .now() + wait)
        }

        registry.setFulfillmentId("f-1", for: "a")
        await settle(registry)
        XCTAssertTrue(sequenceHook.fired, "premise: the shelf save took a sequence")

        let onDisk = perBookLocations(of: "a")
        let newest = onDisk.max { rank($0) < rank($1) }
        let reloaded = shelf(await launch())["a"]?.location
        XCTAssertEqual(reloaded, newest, "files hold \(onDisk)")
    }

    /// A position save taken while the shelf changes keeps the order of the
    /// changes: the later position loads, not the one read first.
    func testPositionSave_PositionChangedInsideItsSequenceWindow_LaterPositionLoads() async throws {
        try await seedMigratedShelf()
        let registry = await launch()
        registry.setLocationDeferringSave(location("a-2"), forIdentifier: "a")
        await settle(registry)
        let wait = windowWait
        sequenceHook.armOnce {
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                registry.setLocation(self.locationValue("a-3"), forIdentifier: "a")
                _ = registry.location(forIdentifier: "a")
                done.signal()
            }
            _ = done.wait(timeout: .now() + wait)
        }

        registry._savePositionForTesting(["a"])
        await settle(registry)
        XCTAssertTrue(sequenceHook.fired, "premise: the position save took a sequence")

        let reloaded = shelf(await launch())["a"]?.location
        XCTAssertEqual(reloaded, "a-3")
    }

    // MARK: - Position cache and record writes

    /// After a record file holds a newer position, saving the earlier position
    /// again still writes the position file.
    func testPositionSavedAgainAfterARecordWrite_IsWritten() async throws {
        try await seedMigratedShelf()
        let registry = await launch()
        registry.setLocation(location("a-2"), forIdentifier: "a")
        await settle(registry)
        registry.setLocationDeferringSave(location("a-3"), forIdentifier: "a")
        registry.setState(.downloadNeeded, for: "a")
        await settle(registry)

        registry.setLocation(location("a-2"), forIdentifier: "a")
        await settle(registry)

        let reloaded = shelf(await launch())["a"]?.location
        XCTAssertEqual(reloaded, "a-2")
    }

    /// The same across a launch: a position file older than its record file
    /// does not stop the next launch from writing that position again.
    func testPositionFileOlderThanRecord_NextLaunchWritesThatPositionAgain() async throws {
        try await seedMigratedShelf()
        let killed = await launch(LaunchLog(crashAtFirst: .backupStaging))
        killed.setLocation(location("a-2"), forIdentifier: "a")
        await settle(killed)
        killed.setLocationDeferringSave(location("a-3"), forIdentifier: "a")
        killed.setState(.downloadNeeded, for: "a")
        await settle(killed)
        let next = await launch()
        XCTAssertEqual(shelf(next)["a"]?.location, "a-3", "premise: the record file is newer than the position file")

        next.setLocation(location("a-2"), forIdentifier: "a")
        await settle(next)

        let reloaded = shelf(await launch())["a"]?.location
        XCTAssertEqual(reloaded, "a-2")
    }

    /// A position file that is still the newest is not written again for the
    /// same position.
    func testSamePositionSavedTwice_WritesThePositionFileOnce() async throws {
        try await seedMigratedShelf()
        let log = LaunchLog()
        let registry = await launch(log)
        registry.setLocation(location("a-2"), forIdentifier: "a")
        await settle(registry)
        let afterFirst = log.steps.filter { $0 == .bookPosition }.count

        registry.setLocation(location("a-2"), forIdentifier: "a")
        await settle(registry)

        XCTAssertEqual(afterFirst, 1)
        XCTAssertEqual(log.steps.filter { $0 == .bookPosition }.count, 1)
    }

    // MARK: - Removals

    /// A removal that stops before registry.json is written leaves the book as
    /// it was, including a position saved only to its position file.
    func testRemove_CrashBeforeTheSingleFile_KeepsTheNewestPosition() async throws {
        try await seedMigratedShelf()
        let registry = await launch(LaunchLog(crashAtFirst: .primary))
        registry.setLocation(location("b-2"), forIdentifier: "b")
        await settle(registry)

        registry.removeBook(forIdentifier: "b")
        await settle(registry)

        let reloaded = shelf(await launch())["b"]?.location
        XCTAssertEqual(reloaded, "b-2")
    }

    /// A removal that stops after registry.json and its trust record, before the
    /// book's files are removed, loads without the book; the next shelf save
    /// removes the files left behind.
    func testRemove_CrashBeforeFileRemoval_BookStaysRemovedAndFilesGo() async throws {
        try await seedMigratedShelf()
        let crashing = await launch(LaunchLog(crashAtFirst: .bookRemoval))
        crashing.setLocation(location("b-2"), forIdentifier: "b")
        await settle(crashing)
        crashing.removeBook(forIdentifier: "b")
        await settle(crashing)
        XCTAssertNotNil(perBookRecords()["b"], "premise: b's files are still on disk")

        let next = await launch()
        let reloaded = shelf(next)
        next.addBook(book("x"), state: .holding)
        await settle(next)

        XCTAssertNil(reloaded["b"])
        XCTAssertNil(perBookRecords()["b"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: booksDirectory.path)
            .filter { $0.hasPrefix(PerBookRegistryFiles.fileStem(for: "b")) }, [])
    }

    /// A removal that stops between a book's record file and its position file
    /// leaves no book on reload, and the next shelf save removes the position
    /// file left behind.
    func testRemove_CrashBetweenTheBooksFiles_LeftoverPositionFileGoes() async throws {
        try await seedMigratedShelf()
        let crashing = await launch(LaunchLog(crashAtFirst: .bookRemoval, occurrence: 2))
        crashing.setLocation(location("b-2"), forIdentifier: "b")
        await settle(crashing)
        crashing.removeBook(forIdentifier: "b")
        await settle(crashing)
        let stem = PerBookRegistryFiles.fileStem(for: "b")
        let leftover = try FileManager.default.contentsOfDirectory(atPath: booksDirectory.path).filter { $0.hasPrefix(stem) }
        XCTAssertEqual(leftover, ["\(stem).position.json"], "premise: only the position file is left")

        let next = await launch()
        let reloaded = shelf(next)
        next.addBook(book("x"), state: .holding)
        await settle(next)

        XCTAssertNil(reloaded["b"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: booksDirectory.path).filter { $0.hasPrefix(stem) }, [])
    }

    // MARK: - Scheduled backup

    /// With per-book files in use, shelf saves inside the backup interval write
    /// the last-good backup once; the first save after it writes it again.
    func testShelfSaves_WriteTheBackupOncePerInterval() async throws {
        try await seedMigratedShelf()
        let log = LaunchLog()
        let registry = await launch(log)

        registry.addBook(book("x"), state: .holding)
        await settle(registry)
        registry.addBook(book("y"), state: .holding)
        await settle(registry)
        let withinInterval = backups(log)
        let backupBeforeInterval = try backupIdentifiers()
        clock.advance(PerBookRegistryFiles.backupInterval)
        registry.addBook(book("z"), state: .holding)
        await settle(registry)

        XCTAssertEqual(withinInterval, 1)
        XCTAssertEqual(backupBeforeInterval, ["a", "b", "c", "x"])
        XCTAssertEqual(backups(log), 2)
        XCTAssertEqual(try backupIdentifiers(), ["a", "b", "c", "x", "y", "z"])
    }

    /// A missing backup file is written at the next shelf save, inside the interval.
    func testBackupMissingOnDisk_WrittenAtTheNextShelfSave() async throws {
        try await seedMigratedShelf()
        let log = LaunchLog()
        let registry = await launch(log)
        registry.addBook(book("x"), state: .holding)
        await settle(registry)
        try FileManager.default.removeItem(at: backupURL)

        registry.addBook(book("y"), state: .holding)
        await settle(registry)

        XCTAssertEqual(backups(log), 2)
        XCTAssertEqual(try backupIdentifiers(), ["a", "b", "c", "x", "y"])
    }

    /// A backup write that fails is tried again at the next shelf save.
    func testBackupWriteFails_TriedAgainAtTheNextShelfSave() async throws {
        try await seedMigratedShelf()
        let log = LaunchLog(failOnce: .backupStaging)
        let registry = await launch(log)
        registry.addBook(book("x"), state: .holding)
        await settle(registry)

        registry.addBook(book("y"), state: .holding)
        await settle(registry)

        XCTAssertEqual(log.steps.filter { $0 == .backupStaging }.count, 2)
        XCTAssertEqual(backups(log), 1)
        XCTAssertEqual(try backupIdentifiers(), ["a", "b", "c", "x", "y"])
    }

    /// The app-event write of registry.json is the full snapshot and refreshes
    /// the backup inside the interval too.
    func testAppEventWrite_RefreshesTheBackupInsideTheInterval() async throws {
        try await seedMigratedShelf()
        let log = LaunchLog()
        let registry = await launch(log)
        registry.addBook(book("x"), state: .holding)
        await settle(registry)
        registry.setLocation(location("x-1"), forIdentifier: "x")
        await settle(registry)

        registry.flushPendingPositions()
        await settle(registry)

        XCTAssertEqual(backups(log), 2)
        XCTAssertEqual(try backupLocation(of: "x"), "x-1")
    }

    /// The app-event backup restarts the interval: a shelf save less than an
    /// interval after it does not write the backup again.
    func testAppEventBackup_RestartsTheInterval() async throws {
        try await seedMigratedShelf()
        let log = LaunchLog()
        let registry = await launch(log)
        registry.addBook(book("x"), state: .holding)
        await settle(registry)
        clock.advance(PerBookRegistryFiles.backupInterval)
        registry.setLocation(location("x-1"), forIdentifier: "x")
        await settle(registry)
        registry.flushPendingPositions()
        await settle(registry)

        registry.addBook(book("y"), state: .holding)
        await settle(registry)

        XCTAssertEqual(backups(log), 2)
        XCTAssertEqual(try backupIdentifiers(), ["a", "b", "c", "x"])
    }

    /// With the flag off every shelf save still writes the backup.
    func testFlagOff_EveryShelfSaveWritesTheBackup() async throws {
        settings.flag = false
        let log = LaunchLog()
        let registry = await launch(log)
        registry.addBook(book("x"), state: .holding)
        await settle(registry)

        registry.addBook(book("y"), state: .holding)
        await settle(registry)

        XCTAssertEqual(backups(log), 2)
    }

    /// A corrupt registry.json is recovered from the scheduled backup: the
    /// shelf as of that backup.
    func testCorruptSingleFile_RecoversTheShelfOfTheLastBackup() async throws {
        try await seedMigratedShelf()
        let registry = await launch()
        registry.addBook(book("x"), state: .holding)
        await settle(registry)
        try Data("{ not json".utf8).write(to: primaryURL)

        let recovered = shelf(await launch())

        XCTAssertEqual(recovered.keys.sorted(), ["a", "b", "c", "x"])
    }

    // MARK: - Helpers

    private var backupURL: URL { registryDirectory.appendingPathComponent("registry.json.bak") }

    private func backups(_ log: LaunchLog) -> Int {
        log.steps.filter { $0 == .backupReplace }.count
    }

    private func backupRecords() throws -> [[String: Any]] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: backupURL)) as? [String: Any]
        return object?["records"] as? [[String: Any]] ?? []
    }

    private func backupIdentifiers() throws -> [String] {
        try backupRecords().compactMap { ($0["metadata"] as? [String: Any])?["id"] as? String }.sorted()
    }

    private func backupLocation(of identifier: String) throws -> String? {
        try backupRecords().first { ($0["metadata"] as? [String: Any])?["id"] as? String == identifier }
            .flatMap { ($0["location"] as? [String: Any])?["locationString"] as? String }
    }

    /// `location(_:)` for closures that run off the main actor.
    nonisolated private func locationValue(_ value: String) -> TPPBookLocation? {
        TPPBookLocation(locationString: value, renderer: "test-renderer")
    }

    /// The location strings of a book's record file and position file.
    private func perBookLocations(of identifier: String) -> [String] {
        let stem = PerBookRegistryFiles.fileStem(for: identifier)
        return [".record.json", ".position.json"].compactMap { suffix in
            guard let data = try? Data(contentsOf: booksDirectory.appendingPathComponent(stem + suffix)),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            let location = suffix == ".record.json"
                ? (object["record"] as? [String: Any])?["location"]
                : object["location"]
            return (location as? [String: Any])?["locationString"] as? String
        }
    }

    /// Order of the test positions: "a-1" < "a-2" < "a-3".
    private func rank(_ location: String) -> Int {
        Int(location.split(separator: "-").last ?? "") ?? -1
    }
}
