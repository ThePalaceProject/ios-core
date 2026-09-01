//
//  TaskProvenanceTests.swift
//  PalaceTests
//
//  PP-4986. `TaskProvenance` exists ONLY because `URLSessionTask.taskDescription`
//  is a shared field: `DownloadTaskPersistence.adoptableTask` has earmarked it for
//  a book id. If a bare assignment were acceptable there would be no enum at all.
//
//  So the property under test is coexistence — that two owners can each hold a key
//  without erasing the other. Review flagged that the encoding was the entire
//  justification for the type and was pinned by nothing: the round-trip worked
//  end-to-end in the retry test, which would also pass against
//  `task.taskDescription = accountId`.
//

import XCTest
@testable import Palace

final class TaskProvenanceTests: XCTestCase {

    private func makeTask() -> URLSessionTask {
        URLSession(configuration: .ephemeral)
            .dataTask(with: URL(string: "https://example.invalid/x")!)
    }

    // MARK: - The property the type exists for

    /// THE regression gate. A second owner writing its own key must not erase the
    /// account — that erasure would silently reopen the credential leak PP-4986
    /// closed, with no test failing anywhere.
    func test_aSecondOwnersKey_doesNotEraseTheAccount() {
        let task = makeTask()
        TaskProvenance.setAccount("urn:uuid:library-a", on: task)

        // Drive the INSTRUCTED path. An earlier version of this test assigned
        // `taskDescription` directly and called that "the way the pointer comment
        // instructs" — the comment instructs the exact opposite, and the
        // instructed path was not writable until `set(_:forKey:)` existed.
        TaskProvenance.set("abc123", forKey: "book", on: task)

        XCTAssertEqual(TaskProvenance.account(of: task), "urn:uuid:library-a",
                       "a co-tenant key must not displace the account")
        XCTAssertEqual(TaskProvenance.value(forKey: "book", of: task), "abc123",
                       "…and the co-tenant's key must survive alongside it")
    }

    /// Re-stamping must update the account in place rather than append a second
    /// `acct=`, which would make the read order-dependent.
    func test_restamping_replacesRatherThanAppends() {
        let task = makeTask()
        TaskProvenance.setAccount("urn:uuid:library-a", on: task)
        TaskProvenance.setAccount("urn:uuid:library-b", on: task)

        XCTAssertEqual(TaskProvenance.account(of: task), "urn:uuid:library-b")
        let occurrences = task.taskDescription?.components(separatedBy: "acct=").count ?? 0
        XCTAssertEqual(occurrences, 2, "exactly one `acct=` key (split yields n+1 parts)")
    }

    // MARK: - Absence must be distinguishable, not guessed

    func test_unstampedTask_reportsNoAccount() {
        XCTAssertNil(TaskProvenance.account(of: makeTask()),
                     "an unstamped task must report nil so the caller can fall back deliberately")
    }

    /// A nil or empty account is not written. Writing `acct=` with no value would
    /// make `account(of:)` return an empty string, which reads as "an account" at
    /// every call site.
    func test_nilOrEmptyAccount_isNotRecorded() {
        let a = makeTask()
        TaskProvenance.setAccount(nil, on: a)
        XCTAssertNil(TaskProvenance.account(of: a))

        let b = makeTask()
        TaskProvenance.setAccount("", on: b)
        XCTAssertNil(TaskProvenance.account(of: b),
                     "an empty account must not round-trip as a present one")
    }

    /// A colon-bearing value round-trips. This does NOT pin `maxSplits: 1` — an
    /// earlier version claimed it did and that was vacuous: the fixture contains
    /// no `=`, so `split(separator: "=")` and `maxSplits: 1` return the same two
    /// parts. Verified by removing the limit and watching all six still pass.
    /// Account ids are UUID URNs and cannot contain `=`, so no honest fixture
    /// exists for that path; the constraint is documented on the type instead.
    func test_valueContainingColons_survivesTheRoundTrip() {
        let task = makeTask()
        TaskProvenance.setAccount("urn:uuid:0e3f-aa:bb", on: task)
        XCTAssertEqual(TaskProvenance.account(of: task), "urn:uuid:0e3f-aa:bb")
    }

    /// THE hazard `DownloadTaskPersistence`'s caution exists for: a co-tenant
    /// assigning `taskDescription` directly erases the account, silently
    /// reopening the credential leak PP-4986 closed. Nothing tested this before,
    /// and the "instructed" path was not even writable — `set(_:forKey:)` was
    /// added so the caution can be followed and this can be pinned.
    func test_bareAssignment_erasesTheAccount_whichIsWhyTheCautionExists() {
        let task = makeTask()
        TaskProvenance.setAccount("urn:uuid:library-a", on: task)

        task.taskDescription = "book=abc123"   // the forbidden move

        XCTAssertNil(TaskProvenance.account(of: task),
                     "a bare assignment erases the account — this is the documented hazard, pinned so the caution is not merely prose")
    }

    func test_malformedDescription_isIgnoredRatherThanTrapping() {
        let task = makeTask()
        task.taskDescription = "garbage;;=;book;acct"
        XCTAssertNil(TaskProvenance.account(of: task),
                     "a field written by someone else must never crash the read path")
    }
}
