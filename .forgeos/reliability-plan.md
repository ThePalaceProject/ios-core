# Bulletproof Ownership — Reliability Initiative Plan

**Architect workstream contract.** Core promise: *"the book I downloaded is reliably mine for the loan period."* This document is the contract parallel implementers build against. Critical-path code (downloads / borrow-return / registry / auth-network) — a bug means a patron loses a book or a loan desyncs.

Worktree: `.claude/worktrees/reliability` (off `develop`). All citations verified against the current tree on this branch.

---

## 1. Verified current state (evidence)

### Problem 1 — Durable downloads: **CONFIRMED (with corrections)**

**1a. Background-session completion handler wired only for audiobooks — CONFIRMED.**
`Palace/AppInfrastructure/TPPAppDelegate.swift:442-444`:
```swift
internal func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
    audiobookLifecycleManager.handleEventsForBackgroundURLSession(for: identifier, completionHandler: completionHandler)
}
```
The `identifier` is **ignored** — every background-session wake is handed to the audiobook manager. The book download center runs its **own** background session: `MyBooksDownloadCenter.swift:930-935` (and 938-945, 1080-1085) build `URLSessionConfiguration.background(withIdentifier: bundleId + ".downloadCenterBackgroundIdentifier")`. That identifier is never matched, and `MyBooksDownloadCenter` implements **no** `urlSessionDidFinishEvents(forBackgroundURLSession:)` delegate (grep count = 0). So when a book download finishes while the app is suspended, iOS relaunches the app, calls the delegate above, the download center's stored system completion handler is neither captured nor invoked → the app cannot tell iOS it finished handling events (background time mismanaged), and there is no guaranteed path that recreates the download session so its delegate callbacks (`didFinishDownloadingTo`) fire → **a suspended-completion download can be silently dropped.**

**1b. Task↔book maps are in-memory only; no `getAllTasks` rehydrate on launch — CONFIRMED.**
`Palace/MyBooks/DownloadStateManager.swift:45-47` — the three tracking maps are plain in-memory `SafeDictionary`s:
```swift
let bookIdentifierToDownloadInfo = SafeDictionary<String, MyBooksDownloadInfo>()
let bookIdentifierToDownloadTask = SafeDictionary<String, URLSessionDownloadTask>()
let taskIdentifierToBook = SafeDictionary<Int, TPPBook>()
```
There is no persistence and no `session.getAllTasks`/`getTasksWithCompletionHandler` reconciliation anywhere in `MyBooksDownloadCenter.swift` (grep = 0). Kill mid-download → the maps are gone; the registry record persisted as `.downloading` is *partially* healed by `BookRegistrySync.load` (`BookRegistrySync.swift:166-173`: `.downloading` + file-exists → `.downloadSuccessful`, else → `.downloadFailed`) — **so "strands in `.downloading` forever" is slightly inaccurate**: on next launch the load-time heal flips it out of `.downloading`. **The real gap:** an actually-still-running background task (iOS keeps background downloads alive across app death) is orphaned — the app never re-adopts it, so it either gets marked `.downloadFailed` prematurely or its completion lands with no in-memory mapping and is dropped. There is no reconciliation between live URLSession tasks and registry state.

**1c. Content transfer has no transient retry/backoff — CONFIRMED.**
`DownloadErrorRecovery` (`Palace/MyBooks/DownloadErrorRecovery.swift`) is a complete exponential-backoff+jitter engine (`executeWithRetry`, `calculateBackoffDelay:285-291`, policies at :29-138). It is applied **only** to the borrow OPDS fetch: `MyBooksDownloadCenter.swift:809-811` inside `fetchBookClosure` with `RetryPolicy.borrowOperation`. The actual URLSession **content** download (the bytes transfer) has no retry — a transient network blip during transfer surfaces via `didCompleteWithError` → `.downloadFailed`, no automatic re-attempt.

### Problem 2 — Offline-safe loans: **CONFIRMED**

`Palace/MyBooks/MyBooks/MyBooksViewModel.swift:131-146` — `loadData()` (which runs on **every** My Books appearance, including offline) partitions on `book.isExpired` and, for every expired book, unconditionally deletes local content and unregisters:
```swift
let (active, expired) = registryBooks.reduce(into: ...) { ... if book.isExpired ... }
if !expired.isEmpty {
    for book in expired {
        downloadCenter.deleteLocalContent(for: book.identifier)   // :143 — deletes the FILE
        bookRegistry.setState(.unregistered, for: book.identifier) // :144
    }
}
```
`isExpired` is a **purely local** computation on the cached `until` date: `TPPBook.swift:567-570` → `getExpirationDate()` reads `availability.limited.until` / `ready.until` from the cached OPDS entry. **No online check, no server confirmation, no grace period.** A stale/early `until`, a clock skew, or a server that would still honor the loan → the patron's downloaded file is destroyed while offline. The code comment at :129-130 explicitly says this was *intentionally* moved to run online-or-offline — that is the defect.

**No in-app loan renewal — CONFIRMED.** No OPDS `renew` rel handling exists (grep for `renew` in `Palace/` finds only a developer-settings mock string at `TPPDeveloperSettingsTableViewController.swift:750` and an unrelated `PalaceAuth/AuthOutcome.swift:60`). Loan-expiry warnings depend on CM push (not in this tree).

### Problem 3 — Offline queue: **CONFIRMED**

`Palace/Platform/OfflineQueueService.swift` is a polished actor: exponential backoff (`OfflineAction.nextRetryDelay`), typed actions (`OfflineActionType`: `.borrow`, `.return`, `.hold`, `.cancelHold` — `OfflineAction.swift:13-18`), persistence, `NWPathMonitor`-driven auto-drain (:184-200), executor injection seam `setExecutor` (:75-77). **Zero production wiring for real actions**: the only references outside the file are its own diagnostics UI — `OfflineQueueDetailView.swift`, `AppHealthViewModel.swift:38`, `PlatformTab.swift:49-50` — all reading `.shared` for display. **`setExecutor` is never called in production**, so `processQueue()` early-returns at :134 (`guard let executor = self.executor else { return }`). Nothing ever calls `enqueue`.

The **live** queue is `Palace/Network/TPPNetworkQueue.swift` (class `NetworkQueue`): SQLite-backed, wired only for annotation POSTs, drops rows after `MaxRetriesInQueue = 5` (:57, deletion at :202-204). Returns/renewals/offline-created bookmarks are never queued.

**Offline return dead-ends — CONFIRMED.** `BookReturnService.returnBook` (`BookReturnService.swift:272`) with a `revokeURL` goes straight to `opdsFeedService.fetchFeed(from: revokeURL)` (:317). Offline → throws → `handleRevokeError` (:397) → not loan-gone, not auth → generic alert (:529). No enqueue, no deferred retry. The user is told return failed with no durable "will retry when online."

### Problem 4 — Registry resilience: **CONFIRMED**

`Palace/Book/Models/BookRegistrySync.swift:145-245`. The load path:
```swift
if FileManager...fileExists && let data = try? Data(...) && let json = try? JSONSerialization... && let records = json.array(for: .records) {
    ... parse ...
} else {
    Log.info("  No existing registry file found or failed to parse")   // :242 — conflates two cases!
}
registry = newRegistry   // :245 — empty on the failure branch
```
A corrupt/unparseable `registry.json` takes the `else` branch, is logged **identically to "no file exists,"** and `newRegistry` stays empty → the in-memory shelf is zeroed. Any subsequent `save(for:)` (`:554`, called from `sync` reconciliation :537, `validateDownloadedContent` :643, etc.) writes the empty snapshot back with `.write(to:, options: .atomic)` (:574) — **overwriting the (recoverable) corrupt file with a valid-but-empty one.** No `.bak`, no quarantine, no rebuild-from-loans-feed, and the on-disk payload has **no schema version** (`save` writes only `{records: [...]}` at :564; contrast the SQLite queue which *does* version via `PRAGMA user_version`). A single bad write/OS truncation silently erases the patron's whole shelf.

---

## 2. Workstreams (file-disjoint)

Three workstreams. Ownership is exclusive: a file is edited by exactly one WS; every other WS treats it read-only. Cross-WS interaction happens only through the **shared seams** in §2.4, which are public APIs, not shared files.

### WS-A — Durable Downloads
**Owns (edit):**
- `Palace/MyBooks/DownloadStateManager.swift`
- `Palace/MyBooks/MyBooksDownloadCenter.swift`
- `Palace/MyBooks/DownloadErrorRecovery.swift` (extend policy use only)
- `Palace/AppInfrastructure/TPPAppDelegate.swift` (**only** the `handleEventsForBackgroundURLSession` method, :442-444, and adding a stored completion-handler property)
- **New:** `Palace/MyBooks/DownloadTaskPersistence.swift` (the persistence model + pure reconciliation function)
- Tests: `PalaceTests/MyBooks/DownloadStateManagerTests.swift`, `MyBooksDownloadCenterTests.swift`, plus new `DownloadTaskPersistenceTests.swift`, `DownloadReconciliationTests.swift`

**Off-limits (read-only, another WS owns):** `MyBooksViewModel.swift` (C), `BookReturnService.swift` (C), `BookRegistrySync.swift` (B), `OfflineQueueService.swift` (C).

**Concrete changes:**
1. **Route the book background session's completion handler.** In `TPPAppDelegate.handleEventsForBackgroundURLSession`, branch on `identifier`: if it matches the download center's `…downloadCenterBackgroundIdentifier`, store `completionHandler` on the download center and ensure the download center's session is (re)instantiated so its delegate callbacks fire; else keep the audiobook route. Add `urlSessionDidFinishEvents(forBackgroundURLSession:)` to `MyBooksDownloadCenter` that invokes and clears the stored handler on the main thread. **Preserve the existing audiobook route unchanged.**
2. **Persist the task↔book map.** Introduce `DownloadTaskPersistence` — a durable record of `{bookID, taskIdentifier, expectedBytes, downloadURL, account}` written when a task starts and removed on terminal completion. Storage: a small JSON/plist keyed alongside the registry (do **not** reuse `BookRegistrySync`'s file — B owns that). `DownloadStateManager` writes/reads through it; keep the in-memory `SafeDictionary`s as the hot cache.
3. **Reconcile on launch.** New pure function `DownloadReconciliation.reconcile(persisted:, liveTasks:, registryStates:) -> [ReconcileDecision]` (adopt / restart / markFailed / cleanup). At startup, call `session.getAllTasks`, feed live tasks + persisted records + registry snapshot in, apply decisions: re-adopt still-running tasks into the maps, restart tasks that died, and only then let the registry heal. **Must run AFTER `BookRegistrySync.load` completes** (see §3).
4. **Add transient retry to the content transfer.** Wrap the content download's failure path in `DownloadErrorRecovery.executeWithRetry` with a **download-transfer policy** (resumable, respects `didCompleteWithError` NSURLError classification already encoded in `RetryPolicy.default.shouldRetry`). Prefer resume-data-based retry over full re-fetch. Cap attempts; never retry non-transient (auth/404/insufficient-space) — the classifier at `DownloadErrorRecovery.swift:34-90` already encodes this.

**Acceptance criteria:**
- Kill-mid-download → relaunch: a still-running background task is re-adopted (not double-started, not spuriously failed); a task that truly died is restarted; registry ends in a state consistent with disk.
- Download that completes while suspended: on next foreground the file is present, registry `.downloadSuccessful`, and the stored system completion handler was invoked exactly once.
- Transient transfer error retries with backoff and eventually succeeds without user action; non-transient fails fast with the existing alert.
- Audiobook background handling is byte-for-byte unchanged.

### WS-B — Registry Resilience
**Owns (edit):**
- `Palace/Book/Models/BookRegistrySync.swift`
- **New:** `Palace/Book/Models/RegistryFileRecovery.swift` (pure corrupt-file classification + quarantine/backup helper + schema version)
- Tests: `PalaceTests/Book/BookRegistrySyncTests.swift` and new `RegistryFileRecoveryTests.swift`

**Off-limits:** everything WS-A and WS-C own. B does **not** touch `MyBooksDownloadCenter` even though load schedules re-downloads through it (:306) — those calls use MBDC's existing public API and stay as-is.

**Concrete changes:**
1. **Distinguish "no file" from "corrupt file."** Split the `BookRegistrySync.swift:145-243` guard so a file that exists but fails to parse takes a **quarantine** branch, not the silent-empty `else`.
2. **Quarantine + backup, never destroy.** Before overwriting a corrupt file, copy it to `registry.json.corrupt-<timestamp>` (quarantine) and, on every successful `save`, first write a `.bak` sidecar (write-new → fsync → rename pattern; keep last-good). On corrupt load, attempt recovery from `.bak` before falling back to empty.
3. **Rebuild path.** When a corrupt/empty load is detected, do **not** immediately `save` empty (that is what erases the shelf). Leave in-memory empty, set a `needsRebuildFromServer` flag, and let the next authenticated `sync` repopulate from the loans feed — but **guard the empty-registry save**: `save(for:)` must refuse to persist an empty snapshot over a non-empty last-good `.bak` unless an authoritative server sync produced the emptiness (reuse the spirit of `shouldSkipBulkDeletion` at :674).
4. **Schema version.** Add a `schemaVersion` field to the persisted payload (`save` at :564 / `saveSync` at :598) and a migration read at load. Version 1 = today's shape.

**Acceptance criteria:**
- Corrupt `registry.json` on launch: original is quarantined, `.bak` (if present) restores the shelf, and the corrupt file is **never** overwritten by an empty save before a server sync.
- A truncated/empty save cannot replace a non-empty last-good backup without server authority.
- Old (unversioned) files load and are migrated to versioned on next save.
- The existing bulk-deletion guard (`shouldSkipBulkDeletion`) behavior is preserved.

### WS-C — Offline-Safe Loans, Renewal & Offline-Queue Wiring
**Owns (edit):**
- `Palace/MyBooks/MyBooks/MyBooksViewModel.swift` (eviction gate)
- `Palace/MyBooks/BookReturnService.swift` (offline → enqueue)
- `Palace/Platform/OfflineQueueService.swift` (only if the executor seam needs widening; prefer not to edit)
- **New:** `Palace/MyBooks/LoanEvictionPolicy.swift` (pure eviction-decision function)
- **New:** `Palace/MyBooks/LoanRenewalService.swift` (OPDS `renew` rel)
- **New:** `Palace/Platform/OfflineQueueCoordinator.swift` (wires `OfflineQueueService.setExecutor` to real actions)
- Tests: `PalaceTests/MyBooks/MyBooksViewModelTests.swift`, `BookReturnServiceTests.swift`, `PalaceTests/Platform/OfflineQueueServiceTests.swift`, plus new `LoanEvictionPolicyTests.swift`, `LoanRenewalServiceTests.swift`, `OfflineQueueCoordinatorTests.swift`

**Off-limits:** `MyBooksDownloadCenter.swift` (A) — C calls its **existing** public API (`deleteLocalContent`, `startDownload`, borrow) but does **not** edit it. `BookRegistrySync.swift` (B). `DownloadStateManager.swift` (A). `TPPAppDelegate.swift` (A).

**Concrete changes:**
1. **Gate offline eviction.** Replace the unconditional delete at `MyBooksViewModel.swift:139-146` with a call to `LoanEvictionPolicy.decide(book:, now:, isOnline:, graceInterval:)`. Rule: **never delete a downloaded file based on a cached `until` alone while offline.** Delete only when online AND (server-confirmed absence from loans feed OR past `until` + grace window). Offline expired books stay readable (or show a "loan may have expired — reconnect to confirm" affordance) rather than being destroyed. Inject an `isOnline`/reachability provider into the view model (new constructor dependency, default to production reachability).
2. **Loan renewal.** `LoanRenewalService.renew(book:)` reads the OPDS `renew` rel from the book's acquisition/links, POSTs it, updates the registry record from the response entry. Surface a "Renew" affordance where loan expiry is shown. Route auth errors through the same host-scoped classifier as borrow/return (see Invariant 5).
3. **Wire the offline queue.** `OfflineQueueCoordinator` calls `OfflineQueueService.shared.setExecutor { action in … }` at app startup (registered from `AppContainer`/app launch — coordinate the single registration site with the owner of that seam; the *call* lives in C's new file). Executor dispatches by `OfflineActionType`: `.return` → `BookReturnService`, `.borrow` → download center borrow API, `.hold`/`.cancelHold` → holds API — all via existing public methods. Returns `true` only on server-confirmed success so the queue's retry/backoff drives failures.
4. **Offline return enqueues.** In `BookReturnService.handleRevokeError` (:397), when the error is a genuine offline/no-connection `NSURLError`, enqueue an `OfflineAction(.return, …)` instead of dead-ending in the alert, and inform the user it will complete when back online. **Do not** delete local content or unregister until the queued return is server-confirmed (Invariant 2/3).

**Acceptance criteria:**
- Offline + expired-by-cached-`until` book: file is **not** deleted; book remains openable; no unregister.
- Online + server-confirmed-returned book: eviction proceeds as today.
- Renewal: tapping Renew POSTs the `renew` rel and extends the loan in the registry; auth failure re-prompts via the shared classifier.
- Offline return: enqueued, retried on reconnect, and only then does local cleanup run; queue survives app restart.

### 2.4 Shared seams (interfaces — define once, both sides code to these)

**Seam S1 — Download-state persistence & reconciliation (owned by WS-A).**
```swift
struct PersistedDownloadRecord: Codable, Sendable {
    let bookID: String
    let taskIdentifier: Int
    let downloadURL: URL
    let account: String
    let expectedBytes: Int64?
    let startedAt: Date
}
enum ReconcileDecision: Equatable { case adopt(bookID: String, taskIdentifier: Int)
                                    case restart(bookID: String)
                                    case markFailed(bookID: String)
                                    case cleanup(bookID: String) }
// Pure — unit-testable without URLSession:
func reconcile(persisted: [PersistedDownloadRecord],
               liveTaskIdentifiers: Set<Int>,
               registryStates: [String: TPPBookRegistry.RegistryState]) -> [ReconcileDecision]
```
Only A implements/edits this. B's registry load is the *input* (`registryStates`), never the mutator. Contract: **registry state is the source of truth for a book's lifecycle; A reconciles URLSession tasks to it, and only heals `.downloading` records that have no live task.**

**Seam S2 — Offline queue executor (owned by WS-C; the actor API is frozen).**
`OfflineQueueService.setExecutor(_ executor: @escaping OfflineActionExecutor)` where `OfflineActionExecutor = @Sendable (OfflineAction) async -> Bool` (`OfflineQueueService.swift:15`). **Do not change this signature** — it is the whole integration point. C's `OfflineQueueCoordinator` supplies the closure. The closure returns `true` **only** on server-confirmed success. Registration must happen exactly once at launch.

**Seam S3 — Eviction decision (owned by WS-C).**
```swift
enum EvictionDecision: Equatable { case keep; case evict; case confirmWithServer }
func LoanEvictionPolicy.decide(expiration: Date?, now: Date,
                               isOnline: Bool, grace: TimeInterval) -> EvictionDecision
```
Pure, no I/O. The view model calls it; the file delete only happens on `.evict`. This function is the single guardrail behind Invariant 2.

---

## 3. Sequencing / dependencies

**Land first (foundational, fully parallel to each other):**
- **WS-B (registry resilience)** — independent; nothing else edits `BookRegistrySync`. Ship first because A's reconciliation *reads* registry state and must not fight a shelf-erasing corrupt-load.
- **WS-A seam S1 (persistence model + pure `reconcile`)** — the `DownloadTaskPersistence.swift` + pure function can be built and unit-tested with no dependency on B.

**Then / parallel:**
- **WS-A integration** (background handler routing, launch reconciliation, transfer retry) proceeds in parallel with C. A's launch reconciliation depends on the **runtime ordering** "registry load → then reconcile" — that is a call-order contract inside AppContainer/launch, not a file dependency. Enforce it with a contract-snapshot test.
- **WS-C** proceeds in parallel: eviction gate (S3) and renewal are independent; offline-queue wiring (S2) depends only on the already-existing `OfflineQueueService`. C calls MBDC/BookReturnService **public** API — no file collision with A because C never edits MBDC.

**Stacks (do not start until dependency merged):**
- C's offline-return enqueue (`BookReturnService`) is independent of A, but its executor's `.borrow` branch calls MBDC borrow API — verify that API is stable (it is; no A change to it is required).

**Merge order recommendation:** B → A → C, but A and C can develop concurrently against frozen seams and merge in either order once B lands.

---

## 4. CRITICAL SAFETY INVARIANTS (the most important output)

Each invariant + the guarding test. Violating any is a BLOCK.

**INV-1 — Never overwrite a recoverable registry with an empty one.** A corrupt/unparseable `registry.json` must be quarantined and `.bak`-restored; `save(for:)` must refuse to persist an empty snapshot over a non-empty last-good backup absent authoritative server emptiness.
*Guard:* `RegistryFileRecoveryTests.testCorruptFile_isQuarantined_notOverwrittenEmpty`; `BookRegistrySyncTests.testSaveEmptyOverNonEmptyBackup_isRefusedWithoutServerAuthority`. (WS-B)

**INV-2 — Never delete a downloaded file while offline based on a cached `until` alone.** Eviction requires online + server confirmation (absence from loans feed) OR past-`until`+grace *and* online. Offline expired ⇒ keep the file.
*Guard:* `LoanEvictionPolicyTests.testOfflineExpiredByCachedUntil_keepsFile`; `MyBooksViewModelTests.testLoadData_offline_doesNotDeleteExpiredLocalContent`. (WS-C)

**INV-3 — Loan-return client/server consistency.** The client must not unregister/delete locally until the return is server-confirmed (revoke feed OK, or a known loan-gone problem-doc, or a server-confirmed queued return). An offline return enqueues; it does **not** pre-emptively clean up. Preserve the existing ordered cleanup contract `setProcessing → setState → removeBook → announce.returnSucceeded`.
*Guard:* `BookReturnServiceContractTests` (existing snapshot at `PalaceTests/Contract/__Snapshots__/BookReturnServiceContractTests`) must not drift; new `BookReturnServiceTests.testOfflineReturn_enqueues_doesNotDeleteLocalContent`. (WS-C)

**INV-4 — Adopt, don't double-start or spuriously fail, live background downloads.** Launch reconciliation must re-adopt a still-running task (no second task, no premature `.downloadFailed`) and must run after registry load.
*Guard:* `DownloadReconciliationTests.testLiveTask_isAdopted_notRestarted`, `…testDeadTask_isRestarted`, `…testCompletedWhileSuspended_marksSuccessfulOnce`; a contract-snapshot test pinning the launch order registry-load→reconcile. (WS-A)

**INV-5 — Auth-error host scoping is preserved on every new network path.** Renewal and queued-return retries route 401/credentials-stale decisions through the current-account host-scoped classifier (`AuthErrorClassifier.currentAccountHostsProvider`, per CLAUDE.md — a 401 from a non-account host is never a session expiry). New POSTs (renew, queued return) must not blanket-logout on a foreign-host 401.
*Guard:* `LoanRenewalServiceTests.testForeignHost401_doesNotMarkCredentialsStale`; reuse the `AuthErrorClassifierPropertyTests` Invariant-8 pattern. (WS-C)

**INV-6 — DRM fulfillment path is untouched.** No WS changes Adobe/LCP fulfillment. The Adobe return call (`BookReturnService.swift:284-297`) and LCP re-download scheduling (`BookRegistrySync.swift:283-296`) stay byte-identical. New retry wrapping (WS-A) applies to the plain content transfer, **not** to DRM fulfillment handlers.
*Guard:* `MyBooksDownloadCenterTests` DRM-path assertions unchanged; diff review confirms no edits inside `#if FEATURE_DRM_CONNECTOR` / `#if LCP` fulfillment blocks.

**INV-7 — Background completion handler invoked exactly once, per session identifier.** The stored system completion handler must be called once and cleared; the audiobook route must remain intact (identifier-matched, not clobbered).
*Guard:* `MyBooksDownloadCenterTests.testFinishEvents_invokesStoredHandlerOnce`; a test asserting an audiobook-session identifier still routes to the audiobook manager. (WS-A)

**INV-8 — Offline queue idempotency & no duplicate side effects.** A queued action that partially succeeded must not double-apply (e.g., a return that reached the server then failed to parse must not enqueue a second return that errors as "no active loan" and confuses the user). Executor returns `true` on server-confirmed success only; dedupe by `bookID`+`type`.
*Guard:* `OfflineQueueCoordinatorTests.testDuplicateReturn_isDeduped`; `OfflineQueueServiceTests` retry/backoff behavior preserved. (WS-C)

---

## 5. TDD strategy (per workstream)

**Pure seams to extract & unit-test (no I/O, high mutation yield):**
- WS-A: `reconcile(persisted:liveTaskIdentifiers:registryStates:) -> [ReconcileDecision]` (S1); the transfer retry classification reuses `DownloadErrorRecovery.RetryPolicy.*.shouldRetry` (already pure). Test the decision matrix exhaustively (live/dead/completed × registry state).
- WS-B: `RegistryFileRecovery.classify(data:) -> {valid(records) | corrupt | empty}` and the `.bak`/quarantine path resolution — pure over `Data`/paths.
- WS-C: `LoanEvictionPolicy.decide(...)` (S3) — the single most important pure function; enumerate {expired/not} × {online/offline} × {within/after grace}. `LoanRenewalService` renew-rel extraction over a fixture entry.

**Contract-snapshot tests (ordered side effects):**
- WS-C: `BookReturnServiceContractTests` already locks `setProcessing → setState → removeBook → announce`. Extend with an offline-enqueue scenario snapshot (must show enqueue, **no** local delete). Borrow/BorrowReducer contracts already exist and must not drift.
- WS-A: new contract snapshot for the launch reconciliation call order (registry-load → getAllTasks → reconcile → apply).

**Mandatory mutation testing (critical-path files, `--diff-only`, ≥50% kill, ideally 100% on touched lines):**
- `Palace/MyBooks/MyBooksDownloadCenter.swift`, `DownloadStateManager.swift`, `DownloadTaskPersistence.swift` (WS-A)
- `Palace/Book/Models/BookRegistrySync.swift`, `RegistryFileRecovery.swift` (WS-B)
- `Palace/MyBooks/BookReturnService.swift`, `MyBooksViewModel.swift`, `LoanEvictionPolicy.swift`, `LoanRenewalService.swift` (WS-C)
Command per file: `python3 scripts/palace_mutate.py --file <f> --tests <TestClass> --diff-only`.

**Definition-of-Done gates (CLAUDE.md §Definition of Done, all 11):** each WS runs the SUT-instantiation check, `check-test-name-vs-body.py`, contract reconciliation, blast-radius, superpartner-spectrum, and `verify-pr.sh --quick` before declaring READY. No `bookRegistry.setState` shortcut tests for the user-action→state wiring — drive the production seam (per the state-machine wiring rule).

---

## 6. Review routing

All three workstreams touch critical paths → **architect + SoD (dual reviewer) required regardless of LOC**, per CLAUDE.md "Risk-driven rigor bar":
- **WS-A** — `Palace/MyBooks/Download*`, background-session handling, `TPPAppDelegate`. Architect (concurrency/session-lifecycle) + qa_test + blast_radius. Use `/rigorous-fix` for the single-module reconciliation seam; `/swarm` if A and C land together.
- **WS-B** — persistence/schema of the shelf source of truth (`TPPBookRegistry` data). Architect (data-integrity/migration) + qa_test. Migration/persistence is an explicit critical path.
- **WS-C** — `BookReturnService` (return flow), `MyBooksViewModel` eviction, renewal POST, auth-error host scoping. Architect + SoD; **INV-5 (auth host scoping) reviewer BLOCK criteria apply** — any 401 path that doesn't consult the current-account host set is a block.

Cross-cutting: because the three share the download/registry/return critical seams, run a **connections** pass before integration to catch latent coupling (S1 registry-state contract vs B's load heal; S2 executor calling A's borrow API). Every reviewer BLOCK → a `.forgeos/wall-failures/` entry per the catalog policy.

---

### Appendix — file ownership matrix

| File | WS-A | WS-B | WS-C |
|---|---|---|---|
| `DownloadStateManager.swift` | **edit** | ro | ro |
| `MyBooksDownloadCenter.swift` | **edit** | ro | ro (call public API) |
| `DownloadErrorRecovery.swift` | **edit** | ro | ro |
| `TPPAppDelegate.swift` (bg handler) | **edit** | ro | ro |
| `DownloadTaskPersistence.swift` (new) | **edit** | — | — |
| `BookRegistrySync.swift` | ro (read state) | **edit** | ro |
| `RegistryFileRecovery.swift` (new) | — | **edit** | — |
| `MyBooksViewModel.swift` | ro | ro | **edit** |
| `BookReturnService.swift` | ro | ro | **edit** |
| `OfflineQueueService.swift` | ro | ro | **edit** (seam only) |
| `LoanEvictionPolicy.swift` (new) | — | — | **edit** |
| `LoanRenewalService.swift` (new) | — | — | **edit** |
| `OfflineQueueCoordinator.swift` (new) | — | — | **edit** |

*ro = read-only / off-limits.* New source files need entries in both `Palace` and `Palace-noDRM` targets via `ruby scripts/pbxproj_add_swift.rb` (test files auto-route to `PalaceTests`).
