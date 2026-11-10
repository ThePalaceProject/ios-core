//
//  PerBookRegistryModelTests.swift
//  PalaceTests
//
//  PP-5507: seeded random operation sequences over several launches, with a
//  crash at a random write step, checked against a plain dictionary model of
//  the shelf after every reload. Fixture: PerBookRegistryTestCase.
//

import XCTest
@testable import Palace
import PalaceBookModel
@_spi(Testing) @testable import PalaceBookRegistry

@MainActor
final class PerBookRegistryModelTests: PerBookRegistryTestCase {

    /// Fixed seeds keep the run repeatable and short enough for CI. A failure
    /// message names its seed and the operations that led to it.
    private static let seeds: [UInt64] = Array(1...40)
    private static let launchesPerSeed = 6
    private static let maxOperationsPerLaunch = 5

    /// After every reload each book is as it was before or after the operation
    /// a crash interrupted, or exactly as the model says when no crash fired;
    /// no book is lost and the shelf never loads empty. Operations run with the
    /// flag on. A flag-off launch between them reads registry.json without the
    /// record files, so it shows the shelf of the last completed registry.json
    /// write; its positions may be newer, so it is compared without them.
    func testRandomOperationsWithCrashes_EachReloadMatchesTheModel() async throws {
        for seed in Self.seeds {
            try await run(seed: seed)
        }
    }

    // MARK: - One seed

    private typealias Shelf = [String: ShelfEntry]

    private func run(seed: UInt64) async throws {
        try? FileManager.default.removeItem(at: root)
        try await seedMigratedShelf()
        var random = SeededRandom(seed: seed)
        var trail: [String] = []
        let start = shelf(await launch())
        var expected: (before: Shelf, after: Shelf) = (start, start)
        var singleFileShelf = start
        var counter = 0

        for launchIndex in 0..<Self.launchesPerSeed {
            if random.int(below: 10) < 3 {
                settings.flag = false
                let offLog = LaunchLog()
                let off = shelf(await launch(offLog))
                let context = "seed \(seed), flag-off launch before launch \(launchIndex) after [\(trail.joined(separator: "; "))]"
                XCTAssertEqual(Self.withoutLocations(off), Self.withoutLocations(singleFileShelf), context)
                XCTAssertFalse(off.isEmpty, "\(context): the shelf loaded empty")
                // Taking newer positions rewrites registry.json, and the next
                // flag-on launch moves that shelf to the per-book files again.
                if offLog.steps.contains(.primary) {
                    expected = (off, off)
                    singleFileShelf = off
                }
                trail.append("flag-off launch")
                settings.flag = true
            }

            let log = LaunchLog()
            let registry = await launch(log)
            var model = shelf(registry)
            assertLoad(model, expected, "seed \(seed), launch \(launchIndex) after [\(trail.joined(separator: "; "))]")
            trail.append("launch \(launchIndex)")

            if random.int(below: 10) < 7 {
                let offset = random.int(below: 12)
                log.armCrash(afterSteps: offset)
                trail.append("crash armed at +\(offset)")
            }
            var interrupted: (before: Shelf, after: Shelf)?
            for _ in 0...random.int(below: Self.maxOperationsPerLaunch) {
                let stepsBefore = log.steps.count
                let crashedBefore = log.didCrash
                let modelBefore = model
                counter += 1
                let name = perform(&random, on: registry, model: &model, counter: counter)
                await settle(registry)
                trail.append(name + (log.didCrash && !crashedBefore ? " (crashed)" : ""))
                XCTAssertEqual(shelf(registry), model, "seed \(seed): premise: the model matches the shelf in memory after \(name)")
                if !crashedBefore {
                    XCTAssertTrue(model == modelBefore || log.steps.count > stepsBefore,
                                  "seed \(seed): \(name) changed the shelf and wrote nothing")
                    if log.didCrash { interrupted = (modelBefore, model) }
                    let steps = Array(log.steps.dropFirst(stepsBefore))
                    let written = steps.filter { $0 == .primary }.count - (log.didCrash && steps.last == .primary ? 1 : 0)
                    if written > 0 { singleFileShelf = model }
                }
            }
            expected = interrupted ?? (model, model)
        }

        let final = shelf(await launch())
        assertLoad(final, expected, "seed \(seed), final launch after [\(trail.joined(separator: "; "))]")
    }

    private static func withoutLocations(_ shelf: Shelf) -> Shelf {
        shelf.mapValues { $0.with(location: nil) }
    }

    private func assertLoad(_ loaded: Shelf, _ expected: (before: Shelf, after: Shelf), _ context: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        assertEachBook(loaded, before: expected.before, after: expected.after, context, file: file, line: line)
        XCTAssertFalse(loaded.isEmpty, "\(context): the shelf loaded empty", file: file, line: line)
    }

    // MARK: - Operations

    /// Runs one random operation on `registry` and the same change on `model`.
    private func perform(_ random: inout SeededRandom, on registry: TPPBookRegistry, model: inout Shelf, counter: Int) -> String {
        let ids = model.keys.sorted()
        let id = ids[random.int(below: ids.count)]
        let value = "\(id)-\(counter)"
        switch random.int(below: 10) {
        case 0:
            registry.setLocation(location(value), forIdentifier: id)
            model[id] = model[id]?.with(location: value)
            return "position \(value)"
        case 1:
            registry.setLocation(nil, forIdentifier: id)
            model[id] = model[id]?.with(location: nil)
            return "clear position \(id)"
        case 2:
            registry.setLocation(location(value), forIdentifier: id, persistence: .coalesced)
            registry.flushPendingPositions()
            model[id] = model[id]?.with(location: value)
            return "coalesced position \(value) and flush"
        case 3:
            let newID = "n\(counter)"
            registry.addBook(book(newID), location: location("\(newID)-\(counter)"), state: .holding)
            model[newID] = ShelfEntry(title: "Book \(newID)", state: .holding, location: "\(newID)-\(counter)",
                                      genericBookmarks: 0, readiumBookmarks: 0)
            return "add \(newID)"
        case 4 where ids.count > 1:
            // Never the last book: an empty save without server authority is refused by design.
            registry.removeBook(forIdentifier: id)
            model[id] = nil
            return "remove \(id)"
        case 5:
            let state = toggled(model[id]?.state)
            registry.setState(state, for: id)
            model[id] = model[id]?.with(state: state)
            return "state \(id) \(state.stringValue())"
        case 6:
            registry.addGenericBookmark(location("bm-\(counter)")!, forIdentifier: id)
            model[id] = model[id]?.with(genericBookmarks: (model[id]?.genericBookmarks ?? 0) + 1)
            return "bookmark \(id)"
        case 7:
            let state = toggled(model[id]?.state)
            registry.setLocationDeferringSave(location(value), forIdentifier: id)
            registry.setState(state, for: id)
            model[id] = model[id]?.with(location: value).with(state: state)
            return "position \(value) with state \(state.stringValue())"
        case 8 where ids.count > 2:
            let others = ids.filter { $0 != id }
            let first = others[0], second = others[1]
            let state = toggled(model[id]?.state)
            registry.setLocationDeferringSave(location("\(first)-\(counter)"), forIdentifier: first)
            registry.setLocationDeferringSave(location("\(second)-\(counter)"), forIdentifier: second)
            registry.setState(state, for: id)
            model[first] = model[first]?.with(location: "\(first)-\(counter)")
            model[second] = model[second]?.with(location: "\(second)-\(counter)")
            model[id] = model[id]?.with(state: state)
            return "three books \(counter)"
        default:
            registry.flushPendingPositions()
            return "flush"
        }
    }

    private func toggled(_ state: TPPBookState?) -> TPPBookState {
        state == .holding ? .downloadNeeded : .holding
    }
}

private extension PerBookRegistryTestCase.ShelfEntry {
    func with(location: String?) -> Self {
        .init(title: title, state: state, location: location, genericBookmarks: genericBookmarks, readiumBookmarks: readiumBookmarks)
    }
    func with(state: TPPBookState) -> Self {
        .init(title: title, state: state, location: location, genericBookmarks: genericBookmarks, readiumBookmarks: readiumBookmarks)
    }
    func with(genericBookmarks: Int) -> Self {
        .init(title: title, state: state, location: location, genericBookmarks: genericBookmarks, readiumBookmarks: readiumBookmarks)
    }
}

/// SplitMix64: the same sequence for the same seed on every machine.
private struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func int(below bound: Int) -> Int {
        Int(next() % UInt64(bound))
    }
}
