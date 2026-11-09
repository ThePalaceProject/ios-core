//
//  MemoryEventRecorderTests.swift
//  PalaceTests
//
//  PP-5509: the memory event line that device runs parse to set the budget.
//

import XCTest
@testable import Palace

final class MemoryEventRecorderTests: XCTestCase {

    private let megabyte: UInt64 = 1024 * 1024

    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func append(_ line: String) { lock.withLock { stored.append(line) } }
        var all: [String] { lock.withLock { stored } }
    }

    func testRecord_WritesKindFootprintAvailableAndCachesInNameOrder() {
        let lines = Lines()
        let mb = megabyte
        let recorder = MemoryEventRecorder(
            footprint: { 412 * mb },
            available: { 1_037 * mb },
            write: { lines.append($0) }
        )
        recorder.registerCache(named: "images") { Int(25 * mb) }
        recorder.registerCache(named: "covers") { Int(40 * mb + 1) }

        recorder.record(.pressureCritical)

        XCTAssertEqual(lines.all, [
            "event=pressure-critical footprintMB=412 availableMB=1037 cache.coversMB=40 cache.imagesMB=25"
        ])
    }

    /// Six names registered in reverse order: without sorting, the dictionary's
    /// per-process order would almost never match.
    func testRecord_ManyCaches_AreWrittenInNameOrder() {
        let lines = Lines()
        let recorder = MemoryEventRecorder(footprint: { 0 }, available: { 0 }, write: { lines.append($0) })
        for name in ["f", "e", "d", "c", "b", "a"] {
            recorder.registerCache(named: name) { 0 }
        }

        recorder.record(.warning)

        XCTAssertEqual(lines.all, [
            "event=warning footprintMB=0 availableMB=0 cache.aMB=0 cache.bMB=0 cache.cMB=0 cache.dMB=0 cache.eMB=0 cache.fMB=0"
        ])
    }

    /// A reader that reports a negative size must not end the app.
    func testRecord_NegativeCacheSize_IsWrittenAsZero() {
        let lines = Lines()
        let recorder = MemoryEventRecorder(footprint: { 0 }, available: { 0 }, write: { lines.append($0) })
        recorder.registerCache(named: "broken") { -1 }

        recorder.record(.warning)

        XCTAssertEqual(lines.all, ["event=warning footprintMB=0 availableMB=0 cache.brokenMB=0"])
    }

    /// The budget data is split by pressure level, so a critical event must not
    /// be labelled a warning.
    func testKind_ForPressureEvents_CriticalWinsOverWarning() {
        XCTAssertEqual(MemoryEventKind(pressure: .warning), .pressureWarning)
        XCTAssertEqual(MemoryEventKind(pressure: .critical), .pressureCritical)
        XCTAssertEqual(MemoryEventKind(pressure: [.warning, .critical]), .pressureCritical)
    }

    func testRecord_EachEventKind_NamesItsSource() {
        let lines = Lines()
        let recorder = MemoryEventRecorder(footprint: { 0 }, available: { 0 }, write: { lines.append($0) })

        recorder.record(.warning)
        recorder.record(.pressureWarning)

        XCTAssertEqual(lines.all.map { $0.components(separatedBy: " ").first }, ["event=warning", "event=pressure-warning"])
    }

    /// A failed kernel read must not look like a zero footprint.
    func testRecord_WhenFootprintIsUnavailable_SaysUnknown() {
        let lines = Lines()
        let recorder = MemoryEventRecorder(footprint: { nil }, available: { 0 }, write: { lines.append($0) })

        recorder.record(.warning)

        XCTAssertEqual(lines.all, ["event=warning footprintMB=unknown availableMB=0"])
    }

    func testRecord_CacheRegisteredAgainUnderTheSameName_ReplacesTheReader() {
        let lines = Lines()
        let mb = megabyte
        let recorder = MemoryEventRecorder(footprint: { 0 }, available: { 0 }, write: { lines.append($0) })
        recorder.registerCache(named: "images") { Int(5 * mb) }
        recorder.registerCache(named: "images") { Int(7 * mb) }

        recorder.record(.warning)

        XCTAssertEqual(lines.all, ["event=warning footprintMB=0 availableMB=0 cache.imagesMB=7"])
    }

    /// The footprint read follows memory the app actually touches, so a device
    /// run sees allocations, not a constant.
    func testPhysicalFootprint_GrowsWhenTheAppTouchesMemory() throws {
        let before = try XCTUnwrap(MemoryEventRecorder.physicalFootprint())
        let size = 64 * Int(megabyte)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 1, count: size)

        let after = try XCTUnwrap(MemoryEventRecorder.physicalFootprint())

        XCTAssertGreaterThan(after, before + 32 * megabyte)
    }
}
