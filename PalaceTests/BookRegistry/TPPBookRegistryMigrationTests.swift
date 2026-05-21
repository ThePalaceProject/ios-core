//
//  TPPBookRegistryMigrationTests.swift
//  PalaceTests
//
//  Deep, mutation-killing tests for the *format-migration* and *format-upgrade*
//  paths in BookRegistrySync.load + TPPBookRegistryRecord(record:) +
//  TPPBook(dictionary:). Each test plants a deliberately-shaped JSON corpus on
//  disk and pins the load behavior of the current code: what survives, what
//  defaults are filled, and what gets dropped.
//
//  These tests do NOT touch production code. They use a hermetic per-test
//  account UUID — the on-disk registry file lives under
//      <AppSupport>/<bundleId>/<test-uuid>/registry/registry.json
//  and is removed in tearDown.
//
//  Companion files (separate test suites):
//    - TPPBookRegistryAtomicWriteTests   — interrupted writes, atomic rename
//    - TPPBookRegistryLargeCorpusTests   — 5000-book load/save scaling
//    - TPPBookRegistryPersistenceTests   — basic save/load/corruption (owned
//      by a sibling agent — do NOT duplicate)
//
//  Copyright 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class TPPBookRegistryMigrationTests: XCTestCase {

    private var account: String!
    private var store: BookRegistryStore!
    private var sync: BookRegistrySync!
    private var accountsManager: AccountsManager!

    override func setUp() {
        super.setUp()
        account = "test-migration-\(UUID().uuidString)"
        store = BookRegistryStore()
        accountsManager = AccountsManager()
        sync = BookRegistrySync(
            store: store,
            accountsManager: accountsManager,
            downloadCenterProvider: { AppContainer.production().downloadCenter },
            opdsFeedServiceProvider: { AppContainer.production().opdsFeedService }
        )
    }

    override func tearDown() {
        if let url = sync?.registryUrl(for: account)?.deletingLastPathComponent() {
            try? FileManager.default.removeItem(at: url)
        }
        account = nil
        store = nil
        sync = nil
        accountsManager = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// Writes a JSON object to the registry file location for the test's
    /// account. Equivalent to seeding the disk with a pre-existing registry
    /// shape from an earlier app version.
    private func writeRegistryJSON(_ object: [String: Any]) {
        guard let url = sync.registryUrl(for: account) else {
            XCTFail("registryUrl(for:) returned nil"); return
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let data = try! JSONSerialization.data(withJSONObject: object, options: .fragmentsAllowed)
        try! data.write(to: url, options: .atomic)
    }

    /// Drive a load and wait for the .loaded state callback.
    /// 30s budget — disk-bound migration load through Codable + state-machine
    /// transitions reliably resolves in <0.5s locally, but CI runners under
    /// contention (especially during parallel test execution) have been
    /// observed exceeding 5s, blocking the whole suite. Same family as the
    /// TokenRefreshAndRetryQueue and ColdStartResume timeout bumps.
    private func loadAndWait() {
        let exp = expectation(description: "load completes")
        sync.load(account: account, setState: { newState in
            if newState == .loaded { exp.fulfill() }
        }, completion: nil)
        wait(for: [exp], timeout: 30.0)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
    }

    /// Build a minimal book-metadata dictionary in the *current* (V2)
    /// dictionaryRepresentation format. Acquisitions is intentionally empty so
    /// the book parses but defaultAcquisition is nil — that keeps state in
    /// `.holding` and avoids the file-existence path in load().
    private func currentFormatBookDict(id: String,
                                       title: String,
                                       updated: Date = Date(timeIntervalSince1970: 1_700_000_000),
                                       extraFields: [String: Any] = [:]) -> [String: Any] {
        var dict: [String: Any] = [
            "id": id,
            "title": title,
            "updated": updated.rfc339String,
            "acquisitions": [] as [Any],
            "categories": [] as [Any],
            "authors": [] as [Any],
            "author-links": [] as [Any]
        ]
        for (key, value) in extraFields {
            dict[key] = value
        }
        return dict
    }

    /// Build a record wrapper in the *current* (V2) registry shape.
    private func currentFormatRecord(_ bookDict: [String: Any],
                                     state: String = "holding",
                                     extraFields: [String: Any] = [:]) -> [String: Any] {
        var record: [String: Any] = [
            "metadata": bookDict,
            "state": state
        ]
        for (key, value) in extraFields {
            record[key] = value
        }
        return record
    }

    // MARK: - Schema migration: pre-existing on-disk format → current code

    /// Pin the current-version baseline. A registry written by the current
    /// app version must load — and round-trip — without losing books.
    /// Kills mutants that swap the keys hard-coded in
    /// `TPPBookRegistryKey` / `TPPBookRegistryData` from string literals to
    /// constants of different values.
    func testV2BaselineRoundTrip_LoadsAndPreservesIdentifierAndState() {
        let id = "v2-baseline-\(UUID().uuidString)"
        writeRegistryJSON([
            "records": [
                currentFormatRecord(
                    currentFormatBookDict(id: id, title: "V2 Baseline Book"),
                    state: "holding")
            ]
        ])

        loadAndWait()

        XCTAssertEqual(store.allBooks.count, 1,
                       "Baseline V2 registry must load exactly one book")
        XCTAssertEqual(store.state(for: id), .holding,
                       "State on disk must round-trip through load")
        XCTAssertEqual(store.book(forIdentifier: id)?.title, "V2 Baseline Book",
                       "Title on disk must round-trip through load")
    }

    /// V1 → V2 migration: a registry that uses the *deprecated* top-level
    /// `acquisition` (singular) key — present in `TPPBook.swift` only as a
    /// `Deprecated*Key` constant — must not crash and must NOT cause records
    /// with valid id+title to silently disappear. The current code ignores the
    /// deprecated key on read; this test PINS that contract so a future mutant
    /// that "reactivates" the key (or hard-crashes on its presence) is caught.
    func testV1SingularAcquisitionKey_IsIgnoredButRecordIsPreserved() {
        let id = "v1-singular-acq-\(UUID().uuidString)"
        // Mix deprecated + current keys so the record is "V1-shaped".
        var bookDict = currentFormatBookDict(id: id, title: "V1 Singular Acquisition")
        bookDict["acquisition"] = [
            "type": "application/epub+zip",
            "href": "https://example.com/legacy"
        ]
        bookDict["available-copies"] = 1
        bookDict["holds-position"] = 0
        bookDict["available-until"] = "2024-01-01"
        // V1 also serialized acquisitions as empty — current code reads only this.
        writeRegistryJSON(["records": [currentFormatRecord(bookDict, state: "holding")]])

        loadAndWait()

        XCTAssertEqual(store.allBooks.count, 1,
                       "V1-shaped record with deprecated keys must still load — kills mutant that drops records on unrecognized keys")
        XCTAssertEqual(store.state(for: id), .holding,
                       "V1 record's state must survive migration to V2-aware loader")
    }

    /// Schema migration: a record whose `acquisitions` array uses the *legacy
    /// dictionary shape* (no nested indirectAcquisitions key) must still parse
    /// — the current TPPOPDSAcquisition.acquisition(withDictionary:) is
    /// forgiving — and the record must be preserved.
    func testV1AcquisitionsLackingIndirectKey_StillParses() {
        let id = "v1-no-indirect-\(UUID().uuidString)"
        let bookDict = currentFormatBookDict(
            id: id, title: "Legacy Acquisitions",
            extraFields: [
                "acquisitions": [
                    [
                        "type": "application/epub+zip",
                        "rel": "http://opds-spec.org/acquisition",
                        "href": "https://example.com/legacy.epub"
                        // No "indirectAcquisitions" key — old format.
                    ]
                ]
            ])
        writeRegistryJSON(["records": [currentFormatRecord(bookDict, state: "holding")]])

        loadAndWait()

        XCTAssertNotNil(store.book(forIdentifier: id),
                        "Legacy-shaped acquisitions dict must not block record load — kills mutant that requires indirectAcquisitions key")
        XCTAssertEqual(store.state(for: id), .holding)
    }

    // MARK: - Format upgrade paths: missing-newer-field → default filled

    /// `audience` and `language` are fields TPPBook.swift reads from the dict
    /// via `as?` casts with no defaults: a record missing those fields must
    /// still load successfully (the optional fields just stay nil). Kills
    /// mutants that change `as? String` to a force-cast.
    func testRecordMissingAudienceAndLanguage_FillsNilDefaults() {
        let id = "missing-audience-lang-\(UUID().uuidString)"
        // currentFormatBookDict already omits audience + language — perfect.
        let bookDict = currentFormatBookDict(id: id, title: "No Audience or Language")
        writeRegistryJSON(["records": [currentFormatRecord(bookDict, state: "holding")]])

        loadAndWait()

        let book = store.book(forIdentifier: id)
        XCTAssertNotNil(book, "Record missing newer optional fields must still load")
        XCTAssertNil(book?.audience,
                     "Missing audience field must default to nil — kills mutant that fabricates a value")
        XCTAssertNil(book?.language,
                     "Missing language field must default to nil — kills mutant that fabricates a value")
    }

    /// `categories` is read as `as? [String] ?? []`. A record where categories
    /// is missing entirely must default to empty, not nil — pinning the
    /// `??` fallback path against a mutant that drops the default.
    func testRecordMissingCategoriesField_DefaultsToEmptyArray() {
        let id = "missing-categories-\(UUID().uuidString)"
        var bookDict = currentFormatBookDict(id: id, title: "No Categories Field")
        bookDict.removeValue(forKey: "categories")
        writeRegistryJSON(["records": [currentFormatRecord(bookDict, state: "holding")]])

        loadAndWait()

        let book = store.book(forIdentifier: id)
        XCTAssertNotNil(book, "Record must load when categories field is absent")
        // categoryStrings is the public accessor; default ?? [] yields an
        // empty (not nil) array.
        XCTAssertEqual(book?.categoryStrings ?? [], [],
                       "Missing categories field must default to [] — kills mutant that drops the ?? [] fallback")
    }

    /// The `updated` field accepts both RFC 3339 (current writer) and ISO 8601
    /// date-only (legacy OPDS feeds). A record using the legacy date-only
    /// shape must still load — kills mutant that drops the ISO 8601 fallback.
    func testRecordWithLegacyISO8601DateOnlyUpdated_StillParses() {
        let id = "iso8601-date-only-\(UUID().uuidString)"
        let bookDict = currentFormatBookDict(id: id, title: "ISO 8601 Date-Only",
                                              extraFields: ["updated": "2024-09-15"])
        writeRegistryJSON(["records": [currentFormatRecord(bookDict, state: "holding")]])

        loadAndWait()

        XCTAssertNotNil(store.book(forIdentifier: id),
                        "ISO 8601 date-only `updated` must parse — kills mutant that drops withISO8601DateString fallback")
    }

    /// An `updated` field that matches NEITHER RFC 3339 nor ISO 8601 must fall
    /// through to `Date.distantPast` and the book must still load — losing
    /// the timestamp is preferable to losing the downloaded book (per the
    /// comment in TPPBook.swift).
    func testRecordWithMalformedUpdated_FallsBackToDistantPast_StillLoads() {
        let id = "malformed-updated-\(UUID().uuidString)"
        let bookDict = currentFormatBookDict(id: id, title: "Malformed Updated",
                                              extraFields: ["updated": "not-a-date-at-all"])
        writeRegistryJSON(["records": [currentFormatRecord(bookDict, state: "holding")]])

        loadAndWait()

        let book = store.book(forIdentifier: id)
        XCTAssertNotNil(book,
                        "Malformed `updated` must NOT drop the record — kills mutant that returns nil on parse failure")
        XCTAssertEqual(book?.updated, Date.distantPast,
                       "Malformed `updated` must fall back to .distantPast — kills mutant that uses Date() (now) as default")
    }

    // MARK: - Format downgrade resilience: unknown future fields

    /// PIN the actual contract: extra/unknown top-level fields inside a
    /// record's metadata dict are *dropped* by the read path — TPPBook only
    /// extracts known keys via its `dictionaryRepresentation` round-trip. A
    /// future-version registry containing a key the current code doesn't
    /// recognize must still load (book is preserved), but the unknown field
    /// is not retained on the in-memory record. Save-out from current code
    /// therefore would not preserve the unknown field.
    ///
    /// This pins the *drop* behavior (NOT preserve). Mutants that pretend to
    /// retain extra metadata fields fail this test.
    func testRecordWithUnknownFutureFields_FieldDroppedButRecordSurvives() {
        let id = "future-fields-\(UUID().uuidString)"
        var bookDict = currentFormatBookDict(id: id, title: "Future Schema")
        bookDict["zzz-unknown-future-field"] = "a value that should not crash the loader"
        bookDict["another-unknown"] = ["nested": "object"]
        // A record-level (vs metadata-level) extra field — the unknown
        // key sits beside "metadata" and "state" inside the record dict.
        let recordWithExtras = currentFormatRecord(
            bookDict,
            state: "holding",
            extraFields: ["future-record-key": 42]
        )
        writeRegistryJSON(["records": [recordWithExtras]])

        loadAndWait()

        let book = store.book(forIdentifier: id)
        XCTAssertNotNil(book,
                        "Unknown future fields must not block loading — kills mutant that rejects unknown keys")
        // The unknown metadata field is dropped on read. We can't directly
        // assert on the absence of the key — TPPBook has no API to expose
        // its raw dictionary back — but the round-trip-out via
        // dictionaryRepresentation() is a fixed key set. Confirm the
        // recovered dict has *only* the known keys for the unknown ones we
        // injected.
        let roundTrip = book!.dictionaryRepresentation()
        XCTAssertNil(roundTrip["zzz-unknown-future-field"],
                     "Round-trip out must NOT retain unknown future fields — pins the 'drop' contract")
        XCTAssertNil(roundTrip["another-unknown"],
                     "Round-trip out must NOT retain unknown future fields — pins the 'drop' contract")
    }

    /// A record with an unknown future *state* string (not in
    /// TPPBookState's known cases) must be dropped — current code logs and
    /// returns nil from TPPBookRegistryRecord(record:). Kills mutants that
    /// default unknown states to a real state (e.g. `.downloadNeeded`).
    func testRecordWithUnknownState_DroppedFromRegistry() {
        let knownId = "known-state-\(UUID().uuidString)"
        let unknownId = "unknown-state-\(UUID().uuidString)"
        writeRegistryJSON([
            "records": [
                currentFormatRecord(currentFormatBookDict(id: knownId, title: "Known State"),
                                    state: "holding"),
                currentFormatRecord(currentFormatBookDict(id: unknownId, title: "Unknown State"),
                                    state: "future-state-that-doesnt-exist-yet")
            ]
        ])

        loadAndWait()

        XCTAssertNotNil(store.book(forIdentifier: knownId),
                        "Known-state record must load alongside an unknown-state sibling")
        XCTAssertNil(store.book(forIdentifier: unknownId),
                     "Unknown state must drop the record — kills mutant that defaults it to .downloadNeeded")
        XCTAssertEqual(store.allBooks.count, 1,
                       "Exactly one of the two records must load — pins the drop-on-unknown contract")
    }

    // MARK: - Index integrity

    /// Books on disk are keyed by `book.identifier`. Two records sharing the
    /// same identifier on disk — a malformed-registry state but a real one we
    /// have seen in production — MUST collapse to a single in-memory record.
    /// The current code uses dictionary assignment: last record wins.
    /// Kills mutants that turn `newRegistry[record.book.identifier] = record`
    /// into an *append-or-skip-if-present*.
    func testDuplicateIdentifiersOnDisk_CollapseToOneRecord() {
        let dupId = "duplicate-id-\(UUID().uuidString)"
        writeRegistryJSON([
            "records": [
                currentFormatRecord(currentFormatBookDict(id: dupId, title: "First Copy"),
                                    state: "holding"),
                currentFormatRecord(currentFormatBookDict(id: dupId, title: "Second Copy"),
                                    state: "unsupported")
            ]
        ])

        loadAndWait()

        XCTAssertEqual(store.allBooks.count, 1,
                       "Duplicate identifier on disk must collapse to exactly one in-memory record — kills mutant that turns the assignment into an append")
        XCTAssertNotNil(store.book(forIdentifier: dupId),
                        "Duplicate identifier must still resolve to exactly one book")
        // Last-record-wins per dict assignment in BookRegistrySync.load.
        XCTAssertEqual(store.book(forIdentifier: dupId)?.title, "Second Copy",
                       "Last record with duplicate identifier must win — kills mutant that flips assignment to first-wins")
        XCTAssertEqual(store.state(for: dupId), .unsupported,
                       "State from the second record must win — pins the dictionary-assignment semantics")
    }

    /// book(forIdentifier:) lookups must be unique-by-identifier — after load,
    /// every record in `store.allBooks` must be findable by its identifier.
    /// Kills mutants that change the keying field from `book.identifier` to
    /// something else (e.g. title), which would still load the books but
    /// would silently break lookup.
    func testLookupByIdentifier_IsUnique_AfterLoad() {
        var bookIds: [String] = []
        var records: [[String: Any]] = []
        for i in 0..<10 {
            let id = "lookup-\(i)-\(UUID().uuidString)"
            bookIds.append(id)
            records.append(currentFormatRecord(
                currentFormatBookDict(id: id, title: "Lookup Book \(i)"),
                state: "holding"))
        }
        writeRegistryJSON(["records": records])

        loadAndWait()

        // Every seeded id must map to a book; every book in the store must be
        // findable by its declared identifier.
        XCTAssertEqual(store.allBooks.count, bookIds.count,
                       "All seeded records must load — kills mutant that drops records based on insertion order")
        for id in bookIds {
            XCTAssertNotNil(store.book(forIdentifier: id),
                            "Lookup-by-identifier must resolve for every seeded id: \(id)")
        }
    }

    // MARK: - On-disk shape after round-trip

    /// Saving an in-memory registry produces a JSON file whose top-level
    /// shape is `{ "records": [ ... ] }`. Kills mutants that rename the
    /// top-level key (or move records nested under a different key).
    func testSavedFile_TopLevelShape_IsRecordsArray() throws {
        let id = "save-shape-\(UUID().uuidString)"
        let book = TPPBookMocker.mockBook(identifier: id, title: "Save Shape", distributorType: .EpubZip)
        store.mutateRegistrySync { registry in
            registry[id] = TPPBookRegistryRecord(book: book, state: .holding)
        }
        sync.saveSync(for: account)

        guard let url = sync.registryUrl(for: account),
              FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("Registry file must exist after saveSync"); return
        }
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertNotNil(json?["records"] as? [[String: Any]],
                        "Saved file must have a top-level `records` array — kills mutant that renames the key")
        XCTAssertEqual((json?["records"] as? [[String: Any]])?.count, 1,
                       "Saved file must contain exactly one record for one in-memory book")
    }

    /// A record's stored state value uses the documented stringValue() — NOT
    /// the raw Int enum. Kills mutants that swap stringValue for rawValue
    /// (which would break legacy loaders and any cross-platform tooling).
    func testSavedFile_StateField_IsStringValueNotInteger() throws {
        let id = "state-string-\(UUID().uuidString)"
        let book = TPPBookMocker.mockBook(identifier: id, title: "State String Form", distributorType: .EpubZip)
        store.mutateRegistrySync { registry in
            registry[id] = TPPBookRegistryRecord(book: book, state: .downloadSuccessful)
        }
        sync.saveSync(for: account)

        let url = sync.registryUrl(for: account)!
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let records = json?["records"] as? [[String: Any]] ?? []
        let stateField = records.first?["state"]

        XCTAssertNotNil(stateField as? String,
                        "Saved `state` must be a String — kills mutant that writes Int rawValue")
        XCTAssertEqual(stateField as? String, "download-successful",
                       "Saved `state` must use the human-readable stringValue() — kills mutant that writes the case name")
    }

    /// Load drops records whose `metadata` field is missing entirely (the
    /// init?(record:) guard at TPPBookRegistryRecord.swift:110). PIN this
    /// behavior so a mutant that fabricates a placeholder book is caught.
    func testRecordMissingMetadataField_Dropped() {
        let goodId = "has-metadata-\(UUID().uuidString)"
        writeRegistryJSON([
            "records": [
                currentFormatRecord(currentFormatBookDict(id: goodId, title: "Has Metadata"),
                                    state: "holding"),
                // Second record lacks `metadata` entirely.
                ["state": "holding"] as [String: Any]
            ]
        ])

        loadAndWait()

        XCTAssertEqual(store.allBooks.count, 1,
                       "Record without metadata must be dropped — kills mutant that fabricates a placeholder book")
        XCTAssertNotNil(store.book(forIdentifier: goodId),
                        "Sibling well-formed record must still load")
    }

    /// Load drops records whose `state` field is missing entirely. PIN the
    /// guard at TPPBookRegistryRecord.swift:124.
    func testRecordMissingStateField_Dropped() {
        let goodId = "has-state-\(UUID().uuidString)"
        let noStateId = "no-state-\(UUID().uuidString)"
        writeRegistryJSON([
            "records": [
                currentFormatRecord(currentFormatBookDict(id: goodId, title: "Has State"),
                                    state: "holding"),
                // Second record has `metadata` but no `state`.
                ["metadata": currentFormatBookDict(id: noStateId, title: "No State Field")]
            ]
        ])

        loadAndWait()

        XCTAssertNotNil(store.book(forIdentifier: goodId),
                        "Sibling record with state must still load")
        XCTAssertNil(store.book(forIdentifier: noStateId),
                     "Record missing state must be dropped — kills mutant that defaults state to .downloadNeeded")
        XCTAssertEqual(store.allBooks.count, 1)
    }

    /// PIN: A record-level field outside `metadata`/`state` (e.g.
    /// `fulfillmentId`, `location`, `bookmarks`, `genericBookmarks`) IS
    /// preserved across the round-trip. Kills mutants that change those keys.
    func testRecordLevelFulfillmentId_IsPreservedAcrossLoad() {
        let id = "fulfillment-roundtrip-\(UUID().uuidString)"
        let record = currentFormatRecord(
            currentFormatBookDict(id: id, title: "With Fulfillment"),
            state: "holding",
            extraFields: ["fulfillmentId": "txn-12345-roundtrip"])
        writeRegistryJSON(["records": [record]])

        loadAndWait()

        // BookRegistryStore doesn't expose record-level fulfillmentId via a
        // facade method that bypasses an identifier check — use the public
        // accessor on the store directly.
        let fid = store.fulfillmentId(forIdentifier: id)
        XCTAssertEqual(fid, "txn-12345-roundtrip",
                       "fulfillmentId at the record level must round-trip — kills mutant that renames the key")
    }
}
