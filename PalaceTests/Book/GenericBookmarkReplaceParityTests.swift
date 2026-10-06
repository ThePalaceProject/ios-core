//
//  GenericBookmarkReplaceParityTests.swift
//  PalaceTests
//
//  Replacing a generic bookmark must behave the same in TPPBookRegistryMock
//  and in the production BookmarkManager, so tests written against the mock
//  describe what patrons get.
//

import XCTest
import PalaceBookModel
@testable import Palace

@MainActor
final class GenericBookmarkReplaceParityTests: XCTestCase {

    private let book = TPPBookMocker.mockBook(identifier: "urn:uuid:replace-parity", title: "Replace Parity")

    private func record(_ json: String) -> TPPBookLocation {
        TPPBookLocation(locationString: json, renderer: "PalaceAudiobookToolkit")!
    }

    /// As saveBookmark stores it: no `chapter` key.
    private lazy var stored = record(#"{"@type":"LocatorAudioBookTime","@version":2,"annotationId":"","readingOrderItem":"t1","readingOrderItemOffsetMilliseconds":7000,"timeStamp":"2026-01-01T00:00:00Z"}"#)
    /// The same bookmark parsed and re-encoded, which adds `chapter: "0"`.
    private lazy var reparsed = record(#"{"@type":"LocatorAudioBookTime","@version":2,"annotationId":"","chapter":"0","readingOrderItem":"t1","readingOrderItemOffsetMilliseconds":7000,"timeStamp":"2026-01-01T00:00:00Z"}"#)
    private lazy var synced = record(#"{"@type":"LocatorAudioBookTime","@version":2,"annotationId":"srv-1","readingOrderItem":"t1","readingOrderItemOffsetMilliseconds":7000,"timeStamp":"2026-01-02T00:00:00Z"}"#)
    private lazy var other = record(#"{"@type":"LocatorAudioBookTime","@version":2,"annotationId":"srv-2","readingOrderItem":"t2","readingOrderItemOffsetMilliseconds":1000,"timeStamp":"2026-01-01T00:00:00Z"}"#)

    private func registries() -> [(name: String, registry: TPPBookRegistryMock)] {
        let all: [(String, TPPBookRegistryMock)] = [("mock", TPPBookRegistryMock()), ("production", BookmarkManagerBackedRegistry())]
        all.forEach { $0.1.addBook(book, state: .downloadSuccessful) }
        return all
    }

    private func records(in registry: TPPBookRegistryMock) -> [String] {
        registry.genericBookmarksForIdentifier(book.identifier).map(\.locationString)
    }

    /// A replace naming a record that is not stored (here, a re-parsed form of
    /// it) changes nothing, rather than adding a second copy.
    func testReplace_OldRecordNotStored_ChangesNothing() {
        for (name, registry) in registries() {
            registry.addGenericBookmark(stored, forIdentifier: book.identifier)

            registry.replaceGenericBookmark(reparsed, with: synced, forIdentifier: book.identifier)

            XCTAssertEqual(records(in: registry), [stored.locationString], name)
        }
    }

    /// A record at the same position but saved at another time is a different
    /// record; a replace naming one leaves the other alone.
    func testReplace_OldRecordDiffersOnlyInTimestamp_ChangesNothing() {
        for (name, registry) in registries() {
            registry.addGenericBookmark(stored, forIdentifier: book.identifier)
            let savedLater = record(stored.locationString.replacingOccurrences(of: "2026-01-01", with: "2026-03-03"))

            registry.replaceGenericBookmark(savedLater, with: synced, forIdentifier: book.identifier)

            XCTAssertEqual(records(in: registry), [stored.locationString], name)
        }
    }

    /// A replace naming the stored record swaps it in place and leaves the rest.
    func testReplace_StoredRecord_IsReplacedInPlace() {
        for (name, registry) in registries() {
            registry.addGenericBookmark(stored, forIdentifier: book.identifier)
            registry.addGenericBookmark(other, forIdentifier: book.identifier)

            registry.replaceGenericBookmark(record(stored.locationString), with: synced, forIdentifier: book.identifier)

            XCTAssertEqual(records(in: registry), [synced.locationString, other.locationString], name)
        }
    }

    /// Deleting by identity removes the named record and keeps another at the
    /// same position with the same fields.
    func testDeleteIdenticalTo_RemovesOnlyTheNamedRecord() {
        for (name, registry) in registries() {
            registry.addGenericBookmark(stored, forIdentifier: book.identifier)
            registry.addGenericBookmark(synced, forIdentifier: book.identifier)

            registry.deleteGenericBookmark(identicalTo: record(stored.locationString), forIdentifier: book.identifier)

            XCTAssertEqual(records(in: registry), [synced.locationString], name)
        }
    }

    /// A replace for a record deleted in the meantime does not write it back.
    func testReplace_AfterRecordWasDeleted_DoesNotWriteItBack() {
        for (name, registry) in registries() {
            registry.addGenericBookmark(stored, forIdentifier: book.identifier)
            registry.deleteGenericBookmark(stored, forIdentifier: book.identifier)

            registry.replaceGenericBookmark(stored, with: synced, forIdentifier: book.identifier)

            XCTAssertTrue(records(in: registry).isEmpty, name)
        }
    }
}
