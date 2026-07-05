# Blast-radius review — fix/sync-mock-race-segv-bookmark-keys

Reviewer: independent blast-radius (SoD floor). ForgeOS gates OFF — verdict recorded to file.
Base: origin/develop...HEAD. Diff: 16 files, +1060/-100 (2 prod files, 1 shared mock, tests, 1 new detector, verify-pr + pre-commit wiring, docs).

## VERDICT: APPROVED (1 warning, no blocking findings)

All 5 universal scripts exit 0:
- check-contract-reconciliation.py = 0
- check-blast-radius.py = 0
- check-adjacency-staleness.py = 0
- check-intent-recorded.py = 0
- check-superpartner-spectrum.py = 0
- (new) check-unsynchronized-sendable-mock.py = 0 on the full tree (3 latent notes; TPPUserAccountMock deferred)

## Findings against the caller's 5 focus points

### 1. Access-control widening (4 bookmark wire keys fileprivate → internal) — PASS
`timeKey, chapterKey, chapterProgressKey, bookProgressKey` on `TPPBookmarkDictionaryRepresentation`
(TPPReadiumBookmark.swift:15-27) drop from `fileprivate` to default `internal`. `hrefKey` was already
`@objc static let` (internal). Surface increase is minimal and justified: `internal` is the least access
that lets the sibling `TPPBookLocation+Locator.swift` (same module, different file) single-source the wire
format — `fileprivate` cannot cross files, and re-declaring literals is the exact STATE.SplitBrain bug being
fixed. No `public`/`open`/ABI surface added (Palace is an app target regardless). Keys are read-only
`static let` constants; the only "abuse" a new call site could commit is referencing the SSOT instead of a
literal, which is the desired behavior. Guarded by `TPPReadiumBookmarkTests.testWireFormatKeys_ArePinned`
(pins raw values) + `testToJSONDictionary_UsesPinnedWireKeys`. Only consumers today are the declaring file
and the Locator sibling.

### 2. TPPBookRegistryMock lock introduction — observable behavior UNCHANGED — PASS
`registry`, `myBooks`, `state`, `isSyncing`, `mockImages`, `resetCalledLibraryIDs` become locked computed
accessors over private `_`-backed storage. Verified no existing consumer of the 40+ test files breaks:
- `registry` HAS a setter (`set { lock.withLock { _registry = newValue } }`), so subscript writeback via
  get-modify-set is preserved. The caller's worst-case ("`mock.registry[id] = newRecord` lost on a returned
  copy") does NOT occur — that failure needs a get-only property; this one has get+set. Confirmed against
  live usage: `mock.registry = [:]` (18 sites) and `bookRegistry.registry[id] = record`
  (TPPSignInBusinessLogicSignOutTests.swift:410) both land correctly.
- `TPPBookRegistryRecord` is a `final class` (TPPBookRegistryRecord.swift:57), so the convenience path
  `mock.registry[id]?.location = x` / `?.state = x` mutates the shared record object through the reference —
  no dictionary writeback needed, mutation is not lost.
- Swift dictionaries are value types; a caller holding `mock.registry` already got a copy pre-change, so the
  "same storage reference" dependency was never possible. No semantics change.
- Combine `send(...)`/NotificationCenter `post(...)` correctly moved OUTSIDE the lock (re-entrancy rule);
  snapshot taken under lock then published. No deadlock, no behavior change.
Residual (documented, acceptable): the single-threaded subscript-assign convenience path is get-modify-set,
i.e. non-atomic across the read and write lock acquisitions. Fine — the doc comment restricts concurrent
access to the protocol methods (which mutate under one lock); no test uses subscript-assign concurrently.

### 3. verify-pr.sh coverage_by_fr sidecar skip — logic correct, does NOT mask drift — PASS
`COV_SKIP=1` is set ONLY when the structured JSON `error` field equals `sidecar_missing`
(verify-pr.sh:992-996). On a machine WITH the sidecar the error field is empty → `COV_SKIP` unset →
`if [ "${COV_SKIP:-0}" != "1" ]` is true → the gaps/missing/stale + `srd diff --code-vs-narrative --strict`
drift branch runs (verify-pr.sh:997-1010). Confirmed on this machine `harness srd coverage --json` returns
`{"ok","error":"sidecar_missing","path"}` — the checked shape is real. Uses the structured field, not
stderr string-matching (comment 989-991 documents the rationale). Any OTHER error / unparseable JSON leaves
COV_SKIP unset and routes gaps="?" to the `fail` branch — safe direction (blocks, never silently green).

### 4. New blocking detector (pre-commit "scan" + verify-pr "block") — one real caveat — PASS w/ note
- Missing PalaceTests/Mocks or PalaceTests → returns 0 (check-unsynchronized-sendable-mock.py:92-99), no
  false-block on synthetic hook-fixture repos or checkouts without the test target.
- Name matching uses `\b<name>\b` word boundaries → no substring collision (FooBar won't match Foo).
- Full-tree runtime is pure-Python regex over the mock + test corpus; acceptable for a scan detector.
- Exits 0 on the current tree.
See WARNING below re: the deferral marker being file-level.

### 5. #if DEBUG / new public API / discarded results — CLEAN — PASS
No `#if DEBUG` introduced in the diff (the only grep hit is a doc row in wall-failures/INDEX.md). No
`public`/`open` added on Palace/ production files. No discarded function results (blast-radius.py = 0). No
secrets.

## WARNING (non-blocking): deferred TPPUserAccountMock race is LIVE, and the detector marker blinds the net
`TPPUserAccountMock` (@unchecked Sendable, 18 unsynchronized vars) is scope-deferred via the
`// unsync-sendable-mock-deferred:` marker (TPPUserAccountMock.swift:12-17). This is honestly characterized —
the wall entry (2026-07-05-sync-mock-race.md:70-72) labels it ACTIVE, not latent, and the intent anti-claims
disclose it. Process is clean (documented deferral per scope protocol; the fix does not claim to lock it).
BUT the risk is not theoretical: `TPPCredentialConcurrencyTests` (TPPCredentialVisibilityTests.swift:693-771)
already hammers the SHARED mock from 50-100 `DispatchQueue.global()` threads —
`testConcurrentRefreshCredentials_doesNotCrash` runs 50 concurrent `refreshCredentialsFromKeychain()` calls.
This is the same segv-class the PR fixes for the registry mock, live today on the account mock. Two
consequences the user should weigh (not blocking, test-infra only — CI stability, not shipped surface):
  (a) The follow-up lock should be prioritized, not backlogged — the next random segv could originate here.
  (b) The deferral marker is FILE-LEVEL, so the new detector will never re-flag TPPUserAccountMock even if a
      future test adds more concurrent usage. Consider ticketing + time-boxing the marker so the safety net
      the PR installs isn't permanently holed over the one other mock that already has the bug.

## Notes couldn't fully evaluate
- Did not run the test suite / build (CI's job). The concurrency-soak green claims in the commit body are
  taken as asserted, not re-verified here.
- Whether every one of the 5 concurrency-primitive files that reference TPPUserAccountMock actually races it
  (vs. incidental co-occurrence) was spot-checked, not exhaustively traced; TPPCredentialConcurrencyTests
  alone is sufficient to establish the live-race point.
