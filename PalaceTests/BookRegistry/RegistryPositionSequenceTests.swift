//
//  RegistryPositionSequenceTests.swift
//  PalaceTests
//
//  PP-5507: random sequences (fixed seeds) of coalesced and immediate position
//  changes, flushes, sign-outs and library switches, with both accounts'
//  registry files compared against a small reference model after every step.
//  A failure names the seed and the steps, so it replays exactly.
//

import XCTest
@testable import Palace
import PalaceBookModel
@_spi(Testing) @testable import PalaceBookRegistry

@MainActor
final class RegistryPositionSequenceTests: XCTestCase {

    /// SplitMix64: small, fast and stable across platforms and Swift versions.
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// What the registry should hold in memory and on disk. Every registry write
    /// stores the loaded account's whole in-memory shelf, so "disk" is the memory
    /// as of that account's last write.
    private struct Model {
        let interval: TimeInterval = 15
        var loaded: String
        var memory: [String: String] = [:]
        var disk: [String: [String: String]] = [:]
        var pending: [String: Set<String>] = [:]
        var lastWrite: [String: Date] = [:]

        init(loaded: String) { self.loaded = loaded }

        private func key(_ account: String, _ id: String) -> String { account + "|" + id }

        private mutating func write(_ account: String) { disk[account] = memory }

        mutating func addBook(_ id: String) {
            memory[id] = ""
            write(loaded)
        }

        mutating func setPosition(_ value: String, for id: String, coalesced: Bool, now: Date) {
            memory[id] = value
            if coalesced, let last = lastWrite[key(loaded, id)], now.timeIntervalSince(last) < interval {
                pending[loaded, default: []].insert(id)
                return
            }
            lastWrite[key(loaded, id)] = now
            pending[loaded] = nil
            write(loaded)
        }

        mutating func flush(now: Date) {
            if let ids = pending[loaded], !ids.isEmpty {
                for id in ids { lastWrite[key(loaded, id)] = now }
                write(loaded)
            }
            pending = [:]
        }

        mutating func reset() {
            disk[loaded] = nil
            memory = [:]
            pending[loaded] = nil
            lastWrite = lastWrite.filter { !$0.key.hasPrefix(loaded + "|") }
        }

        mutating func switchTo(_ account: String, now: Date) {
            flush(now: now)
            loaded = account
            memory = disk[account] ?? [:]
        }
    }

    private let accountA = "seq-A-\(UUID().uuidString)"
    private let accountB = "seq-B-\(UUID().uuidString)"

    func testRandomSequences_DiskMatchesTheModelAfterEveryStep() async throws {
        for seed: UInt64 in [1, 7, 42, 1_234, 9_001, 65_537] {
            try await run(seed: seed, steps: 40)
        }
    }

    private func run(seed: UInt64, steps: Int) async throws {
        var rng = SeededGenerator(state: seed)
        let fixture = PositionRegistryFixture(account: accountA)
        defer { fixture.removeFiles() }
        await fixture.load(accountA)
        var model = Model(loaded: accountA)
        var log: [String] = []
        var nextBook = 0
        var nextPosition = 0

        for step in 0..<steps {
            fixture.clock.advance(TimeInterval(Int.random(in: 0...20, using: &rng)))
            let now = fixture.clock.now
            let books = model.memory.keys.sorted()
            let roll = Int.random(in: 0..<100, using: &rng)

            switch roll {
            case 0..<12 where books.count < 4, _ where books.isEmpty:
                let id = "book-\(nextBook)"
                nextBook += 1
                log.append("add \(id)")
                await fixture.addBooks([id])
                model.addBook(id)
            case 0..<55:
                let id = books.randomElement(using: &rng)!
                let value = "pos-\(nextPosition)"
                nextPosition += 1
                log.append("coalesced \(id) \(value) at +\(step)")
                fixture.registry.setLocation(PositionRegistryFixture.location(value), forIdentifier: id, persistence: .coalesced)
                model.setPosition(value, for: id, coalesced: true, now: now)
            case 55..<70:
                let id = books.randomElement(using: &rng)!
                let value = "pos-\(nextPosition)"
                nextPosition += 1
                log.append("immediate \(id) \(value)")
                fixture.registry.setLocation(PositionRegistryFixture.location(value), forIdentifier: id)
                model.setPosition(value, for: id, coalesced: false, now: now)
            case 70..<85:
                log.append("flush")
                fixture.registry.flushPendingPositions()
                model.flush(now: now)
            case 85..<92:
                log.append("sign out \(model.loaded)")
                fixture.registry.reset(model.loaded)
                model.reset()
                await fixture.load(model.loaded)
            default:
                let other = model.loaded == accountA ? accountB : accountA
                log.append("switch to \(other == accountA ? "A" : "B")")
                fixture.scope.switchTo(other)
                var loaded = false
                for _ in 0..<1000 where !loaded {
                    loaded = fixture.registry.loadedAccountID == other
                    if !loaded { try await Task.sleep(nanoseconds: 10_000_000) }
                }
                XCTAssertTrue(loaded, "seed \(seed): account \(other) never loaded")
                model.switchTo(other, now: now)
            }
            await fixture.registry._awaitPendingPersistenceForTesting()

            let context = "seed \(seed), step \(step): \(log.joined(separator: "; "))"
            for account in [accountA, accountB] {
                let onDisk = fixture.persistedLocations(account) ?? [:]
                XCTAssertEqual(onDisk, model.disk[account] ?? [:], "disk of \(account == accountA ? "A" : "B") — \(context)")
            }
            for (id, value) in model.memory {
                XCTAssertEqual(fixture.registry.location(forIdentifier: id)?.locationString ?? "", value, "memory \(id) — \(context)")
            }
            if testRun?.failureCount ?? 0 > 0 { return }
        }
    }
}
