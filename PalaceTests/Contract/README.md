# Contract-snapshot tests

A structural safety net for refactor PRs. Pair with `CallLog` + `ContractSnapshot.assert(...)` to lock the call sequence into a class's dependencies. When a future PR changes that sequence — intentionally or not — the snapshot diff fires.

## Why this exists

3.1.0's Phase 7 PR #890 extracted ~1,524 LOC from `MyBooksDownloadCenter` into `BorrowReducer` + `BorrowOperation` + `BookReturnService` + ... The extraction leaked four silent regressions (F-011, F-014, F-016, F-017) that existing unit tests didn't catch. Each was a call-sequence drift — a missing arm in a switch, an inverted condition, a missed observation — that per-case unit tests are *structurally insensitive to*.

A contract snapshot is the mechanical guard against that drift.

## Authoring a contract

```swift
import XCTest
@testable import Palace

final class BorrowOperationContractTests: XCTestCase {
    func test_attemptDownloadTrue_onDownloadNeededState() async throws {
        let log = CallLog()
        let spy = SpyBorrowDelegate(log: log)
        let operation = BorrowOperation.makeForTest(delegate: spy)

        _ = try await operation.borrowAsync(book, attemptDownload: true)

        ContractSnapshot.assert(log, named: "attemptDownloadTrue_onDownloadNeededState")
    }
}

// Co-located spy. Records the contract surface.
private final class SpyBorrowDelegate: BorrowOperationDelegate {
    let log: CallLog
    init(log: CallLog) { self.log = log }

    func startDownload(for book: TPPBook, withRequest req: URLRequest?) {
        log.record("startDownload",
                   args: ["bookId": book.identifier, "hasRequest": req != nil])
    }

    func startBorrow(for book: TPPBook, attemptDownload: Bool, borrowCompletion: (() -> Void)?) {
        log.record("startBorrow",
                   args: ["bookId": book.identifier, "attemptDownload": attemptDownload])
    }
}
```

First run: the test FAILS with `Contract snapshot recorded at ... — Commit this file to lock the contract`. Commit the JSON. Subsequent runs pass.

When the refactor changes the call sequence, the test fails with a side-by-side diff. Author can either fix the regression OR re-record with `CONTRACT_SNAPSHOT_RECORD=1` if the new sequence is intended.

## Snapshot file location

`PalaceTests/Contract/__Snapshots__/<TestFileBaseName>/<scenarioName>.json`

These files ARE the contract. Commit them. Review changes to them in PR review as carefully as you'd review the code change.

## When to add a contract

- **Required:** Extracting a class >300 LOC from an existing class (Phase 7-style decomposition)
- **Strongly recommended:** Refactoring an existing class's internal logic
- **Optional:** New classes — wait until they stabilize before locking the contract

## Limitations

- The snapshot captures `(method, args)` pairs **in order**. It does NOT capture timing, threading, or return values. If those matter to your scenario, add explicit assertions alongside the snapshot.
- Args are stringified through `String(describing:)` to keep the format schema-light. Complex value types may not produce stable representations across Swift versions — for those, pre-stringify in your spy with a canonical form.
- Async tests: `CallLog` is thread-safe (NSLock), but you must `await` your scenario to completion before calling `assert(...)`. Otherwise the snapshot will be a race-dependent partial.

## See also

- `CallLog.swift` — the recording primitive
- `ContractSnapshot.swift` — the assert / record / diff helper
- Memory: `phase7_borrow_path_regressions_2026_05_14.md` — the motivating incident
