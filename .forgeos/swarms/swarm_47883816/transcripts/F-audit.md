# F — FireAndForgetAudit (transcript)

**Swarm**: `swarm_47883816` — Test Pollution Sweep
**Implementer**: F
**Scope**: PURE AUDIT of `Task { ... }` and `DispatchQueue.{global,main}.async` occurrences in `PalaceTests/`.
**Code changes applied**: 0 (audit-only — see "Code changes" section).

---

## 1. Summary (counts per category)

| Source | Raw line count | Notes |
|---|---|---|
| `grep -rEn "Task\s*\{" PalaceTests --include="*.swift"` | **106** | Includes comments & method/type names containing "Task" |
| `grep -rEn "DispatchQueue\.(global\|main)\.async" PalaceTests --include="*.swift"` | **49** | Includes comments |
| **Total** | **155** | Architect contract estimated ~170; actual 155 |
| Non-comment sites | ~125 | After excluding `///`, `//` and `*` lines |

**Verified counts** (from `wc -l`):

```
     106 /tmp/F-task-sites.txt
      49 /tmp/F-dispatch-sites.txt
     155 total
```

### Classification

| Category | Count (approx) | Verdict |
|---|---|---|
| (i) **Utility drainer / test helper** | ~95 | OK — `XCTestCase+drainMainQueue.swift`, generation-guarded executor mocks, `Mock*Loader` completion shims, `DispatchQueue.main.async { drain.fulfill() }` patterns, `Task { @MainActor in exp.fulfill() }` patterns. |
| (ii) **Test-only awaited Task** | ~28 | OK — `Task { ... }` whose result/completion is awaited via `wait(for:)`, `await task.value`, `await task.result`, `await fulfillment(of:)`, `awaitCondition[Async]`, `awaitConditionAsync`, `waitForAsyncCleanup`, `waitForCompletion`, `streamTask.cancel()` after expectation, `withTaskGroup` (auto-awaited). |
| (iii) **Test-side fire-and-forget (FLAG)** | **2** | DRMAdversarialTests fire-and-forget XCTFail-bearing Task; PersistentLoggerTests tearDown Task. |
| (iii') **Production fire-and-forget reachable from tests** | **3 clusters** | Reachable by tests via critical-path retry/return/coordinator code. NOT touched by F — flagged for follow-up tickets per contract (off-limits matrix). |

---

## 2. Category (iii) findings — TEST-SIDE fire-and-forget

### F-iii-1 — `PalaceTests/Security/DRMAdversarialTests.swift:106` — fire-and-forget `XCTFail`-bearing Task in `testAdobe_fulfillmentPath_callsEnsureDeviceActivated()`

**Code excerpt** (file:line 106-114):
```swift
Task {
    do {
        try await AdobeDRMService.shared.ensureDeviceActivated()
        XCTFail("ensureDeviceActivated should throw when no licensor is available")
    } catch {
        // Expected: activation fails because no licensor credentials
        XCTAssertTrue(true, "Activation correctly failed without licensor credentials")
    }
}
```

**Why fire-and-forget**: The enclosing test method `testAdobe_fulfillmentPath_callsEnsureDeviceActivated()` is a *synchronous* `throws` method, **not** `async`. The `Task { ... }` is launched and **never awaited** — the method returns immediately after launching the task. Neither the `XCTFail` (sad path) nor the `XCTAssertTrue(true)` (happy path) is observed by XCTest before the method exits, so the assertion is effectively dead code.

**Additional smell**: The `XCTAssertTrue(true, ...)` inside the catch is a **tautology test** explicitly banned by CLAUDE.md (`XCTAssertTrue(x == true || x == false)` class of bug — `true` is always true).

**Impact on tests**:
1. The test always passes regardless of `AdobeDRMService.ensureDeviceActivated()`'s actual behavior — a regression that makes activation silently succeed would not fail this test.
2. The unawaited Task touches `AdobeDRMService.shared` (a global singleton) **after** the test method returns. If a subsequent test re-uses or modifies `AdobeDRMService.shared` state, the still-in-flight Task from this test can land its mutation in the next test's window — cross-test state pollution risk.

**Cannot be fixed by F**: This file is in `Palace/Security/` which is adjacent to DRM/critical-path. The fix requires marking the test `async`, awaiting the Task, and replacing the tautology with a real assertion that catches the specific expected error type — a non-trivial behavioral test change for a DRM-feature-gated path. Off-limits to F per the contract's "DRM" exclusion.

### F-iii-2 — `PalaceTests/Logging/PersistentLoggerTests.swift:26-31` — fire-and-forget Task in `tearDown()`

**Code excerpt**:
```swift
override func tearDown() {
    Task { [sut, testLogsRoot] in
        await sut?.clearLogs()
        if let root = testLogsRoot {
            try? FileManager.default.removeItem(at: root)
        }
    }
    sut = nil
    testLogsRoot = nil
    super.tearDown()
}
```

**Why fire-and-forget**: `tearDown()` is a synchronous override. The cleanup Task is launched and **never awaited**. `tearDown()` proceeds immediately to clear `sut`/`testLogsRoot` ivars and call `super.tearDown()` — the Task's `await sut?.clearLogs()` and `FileManager.removeItem(at: root)` run after the test's tearDown reports complete.

**Impact on tests**:
- *Low state-pollution risk* — each test instance uses a UUID-namespaced temp directory (`"test-persistent-\(UUID().uuidString)"`), so the next test sees a fresh dir regardless.
- *Disk leak risk* — if the simulator/CI host doesn't wipe `temporaryDirectory` between runs, every test run leaks its log dir. Over many CI runs this can grow.
- *PersistentLogger state* — `PersistentLogger` is an actor; the still-running `clearLogs()` after tearDown holds an actor reference past the test boundary. Race with `setUp()` creating a new instance is benign (new actor instance), but the lingering Task delays test-suite finalization.

**Cannot be fixed by F** in the strict ≤2-trivial-fix budget — it requires `override func tearDown() async`, which changes the override signature (XCTest supports `tearDown() async throws`). That's a behavioral change to a test class, not a one-line cancellables-store fix; the carve-out criterion ("single missing `cancellables` store, a single replaced `Task` with `cancellables`-backed publisher subscription") doesn't apply.

---

## 3. Category (iii') findings — PRODUCTION fire-and-forget reachable from tests (NOT touched by F)

These are **production** code surfaces (not in `PalaceTests/`) that tests poll/sleep around to wait for. They surface in the audit because the test-side patterns are clearly working around an unmanaged Task in production. **F does not touch any production code** — these are filed for follow-up under the critical-path exclusion.

### F-iii'-1 — `Palace/MyBooks/DownloadAuthRetryHandler.swift:173,200,214,239,264,276,329,356` — 8 fire-and-forget Tasks in critical-path auth-retry handler

**Why fire-and-forget**: 8 separate `Task { [weak self] in ... }` launches inside `@MainActor` methods, none of which retain the Task handle or expose a cancellation token. The Tasks perform `cleanupTrackingState(...)`, `coordinator.refreshCredentialsIfNeeded(...)`, and registry-state mutations.

**Test evidence**: `PalaceTests/MyBooks/DownloadAuthRetryHandlerTests.swift:148-156` defines a `waitForAsyncCleanup()` helper that sleeps for `5 × 30ms = 150ms` to let pending production Tasks settle before assertions. The comment says: *"Wait for any pending Task { } cleanup blocks the handler may have dispatched. The handler uses Task to do async stateManager cleanup before hopping back to MainActor for state mutation."* The test is poll-based because the production code provides no completion signal.

**Impact**: If a test fails before the production Task completes, the Task still runs to completion and writes to `bookRegistry` after the test exits — polluting subsequent tests' registry state.

**Critical path**: `Palace/MyBooks/Download*` — off-limits to F per contract. **Follow-up only.**

### F-iii'-2 — `Palace/MyBooks/BookReturnService.swift` (et al) — fire-and-forget Tasks in return flow

**Why fire-and-forget**: Per `PalaceTests/MyBooks/BookReturnServiceTests.swift:111-113` comment: *"Wait for the service's async Tasks (OPDS fetch + cleanup hops) to drain. The service uses Task { } extensively — assertions need to run after those finish."* The test uses `awaitConditionAsync` to poll for completion.

**Impact**: Same as F-iii'-1 — unmanaged Tasks survive test boundaries when the test fails early.

**Critical path**: `Palace/MyBooks/BookReturn*` — off-limits. **Follow-up only.**

### F-iii'-3 — `Palace/Accounts/TPPUserAccount` (or sibling) — fire-and-forget Task that resets `isSigningOut` ~100ms after `signOut()`

**Why fire-and-forget**: Per `PalaceTests/Accounts/UserAccountPublisherTests.swift:104-109`: *"The reset runs inside `Task { Task.sleep(100ms); isSigningOut = false }`. Default 5s `awaitCondition` budget flaked under late-suite dispatch saturation."* The test uses `awaitCondition(timeout: 15.0, ...)` with a FLAKE-OK annotation.

**Impact**: When a test sequence does `signOut()` → `tearDown()` quickly, the deferred reset Task can still execute after tearDown — touching `publisher.isSigningOut` in the next test if the publisher is a singleton or rebuilt against the same backing store.

**Critical path**: `Palace/Accounts/` & `Palace/SignInLogic/` — off-limits. **Follow-up only.**

---

## 4. Proposed follow-up tickets

| Proposed title | Area | Source finding | Severity |
|---|---|---|---|
| **PP-XXXX**: DRMAdversarialTests `testAdobe_fulfillmentPath_callsEnsureDeviceActivated` is a fluff test — fix or delete | `PalaceTests/Security/` | F-iii-1 | Medium (test theater + state pollution) |
| **PP-XXXX**: PersistentLoggerTests tearDown leaks Task — migrate to `tearDown() async throws` | `PalaceTests/Logging/` | F-iii-2 | Low (disk leak only; per-test UUID dir prevents state pollution) |
| **PP-XXXX**: `DownloadAuthRetryHandler` — retain/cancel auth-retry Tasks to prevent state leaks across test boundaries | `Palace/MyBooks/DownloadAuthRetryHandler.swift` | F-iii'-1 | High (critical path + 8 fire-and-forget sites + tests poll-wait) |
| **PP-XXXX**: `BookReturnService` — retain/cancel return-flow Tasks (OPDS fetch + cleanup hops) | `Palace/MyBooks/BookReturnService.swift` | F-iii'-2 | High (critical path) |
| **PP-XXXX**: `TPPUserAccount.signOut()` 100ms reset Task — retain handle for test-deterministic teardown | `Palace/Accounts/` or `Palace/SignInLogic/` | F-iii'-3 | Medium (auth path; flake history documented FLAKE-003-OK) |

Each ticket should reference this audit doc (`.forgeos/swarms/swarm_47883816/transcripts/F-audit.md`) for full context.

---

## 5. Code changes applied

**None.** F-iii-1 and F-iii-2 are both real findings but their fixes require:
- DRMAdversarialTests: replacing a tautology + restructuring to `async` test + asserting against the actual thrown error type — behavioral change in a DRM-flag-gated test, outside the ≤2-trivial-fix carve-out.
- PersistentLoggerTests: migrating `tearDown()` → `tearDown() async throws` — signature change, not a "single missing `cancellables` store" fix.

The 3 production-side findings (F-iii'-1, F-iii'-2, F-iii'-3) are explicitly **off-limits** to F per contract (critical paths: Audiobooks/SignIn/Borrow/Return/Download/DRM).

**`git diff` summary**: only `.forgeos/swarms/swarm_47883816/transcripts/F-audit.md` and `.forgeos/swarms/swarm_47883816/transcripts/F.md` added.

---

## 6. Grep evidence (selected lines)

### From `/tmp/F-task-sites.txt` (high-signal excerpts; full file checked in to /tmp during run)

**Category (i) — utility drainers / mock completion shims**:
```
PalaceTests/XCTestCase+drainMainQueue.swift:27:    /// Does NOT wait for `Task { ... }`-based async work — Tasks don't
PalaceTests/PDF/LCPPDFOpenProgressTests.swift:78:        Task { @MainActor in firstOpenWait.fulfill() }
PalaceTests/PDF/LCPPDFOpenProgressTests.swift:102:        Task { @MainActor in wait.fulfill() }
... (9 more sibling lines in LCPPDFOpenProgressTests — all fulfill an expectation)
```

**Category (ii) — awaited Tasks**:
```
PalaceTests/Integration/SearchFlowIntegrationTests.swift:156:        let task = Task {        # → await task.result (l.165)
PalaceTests/Integration/AccountSwitchIntegrationTests.swift:103:        let loadTask = Task {  # → await loadTask.result (l.112)
PalaceTests/CarPlay/CarPlayAuthHelperReadinessTests.swift:56:        let awaiterTask = Task {  # → await fulfillment(of: [resolved]) (l.73)
PalaceTests/Audiobooks/AudiobookOpenStateRaceTests.swift:86:        let awaiterTask = Task {   # → await fulfillment (l. later)
PalaceTests/SignInLogic/SignInModalLifecycleTests.swift:126,133:                            # → await firstTask.value / await secondTask.value
PalaceTests/Accounts/AccountStateMachineTests.swift:132,159,184,193,220,328: all → expectation/fulfillment
PalaceTests/Accounts/AccountsManagerStateMachineWiringTests.swift:437,508,591,837,1072: streamTask → cancelled after wait(for: ...) — see l.457/533/640/855/1094
PalaceTests/Network/{NetworkClient,NetworkRetry}Tests.swift: group.addTask within withTaskGroup — auto-awaited
PalaceTests/CatalogUI/CatalogSearchViewModelTests.swift:798,913,916,919: group.addTask / Task → fulfillment expectation
PalaceTests/Utilities/SafeDictionarySyncMirrorTests.swift:85,88: group.addTask within withTaskGroup
PalaceTests/MyBooks/MyBooksDownloadCenter{Integration,Concurrency}Tests.swift: withTaskGroup
```

**Category (iii) — flagged test-side fire-and-forget**:
```
PalaceTests/Security/DRMAdversarialTests.swift:106:        Task {           # → NEVER AWAITED (sync test body)
PalaceTests/Logging/PersistentLoggerTests.swift:26:        Task [sut, testLogsRoot] in   # → NEVER AWAITED (sync tearDown)
```

### From `/tmp/F-dispatch-sites.txt` (high-signal excerpts)

**Category (i) — drainer / mock completion shims**:
```
PalaceTests/XCTestCase+drainMainQueue.swift:40,60,90:     # drainer utility
PalaceTests/Mocks/{NYPLNetworkExecutor,MockImageLoader,TPPReauthenticator}Mock.swift: # mock completion shims
PalaceTests/Settings/TPPSettingsTests.swift:62,94:        DispatchQueue.main.async { drained.fulfill() }
PalaceTests/Bookmarks/TPPAnnotationsTests.swift:1106:     DispatchQueue.main.async { drain.fulfill() }
PalaceTests/BookStateManagement/BookCellModelActionTests.swift:238: drain.fulfill()
PalaceTests/Integration/BorrowAndDownloadIntegrationTests.swift:261,302: drained.fulfill()
PalaceTests/SignInLogic/TPPIdleSignOutRegressionTests.swift:210,352,470: networkProcessed/networkDrained.fulfill()
PalaceTests/Book/BookDetailViewModelTests.swift:927,1038,1205,1223,1239,1255,1274: flush/drain/exp.fulfill()
PalaceTests/Stats/BadgesViewModelTests.swift:162: DispatchQueue.main.async { ... exp.fulfill() }
PalaceTests/SignInLogic/TPPSignInAdobeSkipTests.swift:237: expectation.fulfill()
PalaceTests/Audiobook/Vendors/{OpenAccess,BearerToken,LocalFile}AdapterTests.swift: URLSession mock hop
PalaceTests/Audiobooks/CrossVendorSmokeTests.swift:239,258,325,424: URLSession mock hops
```

**Category (ii) — awaited via DispatchWorkItem polling**:
```
PalaceTests/MyBooks/TokenRefreshInterceptorTests.swift:239,262,329,351,454,515,551,592: DispatchQueue.main.asyncAfter(...) + wait(for: [exp], timeout:)
PalaceTests/ErrorHandling/TPPAlertUtilsTests.swift:351: # FLAKE-002-OK production-style dismissal, awaited
```

**Category (iii) — none on the DispatchQueue grep** — all matches are drainer/mock/awaited.

---

## 7. Conclusion

- **155 raw grep hits**, ~125 non-comment sites.
- **~95 are category (i)** — utility drainers and `Task { @MainActor in exp.fulfill() }` mock-completion shims. These are the *correct* pattern.
- **~28 are category (ii)** — awaited Tasks via `.value` / `.result` / `fulfillment(of:)` / `awaitCondition[Async]` / `withTaskGroup`. Correct.
- **2 are category (iii) test-side fire-and-forget** (DRMAdversarialTests + PersistentLoggerTests).
- **3 production-code clusters** are flagged via the test-side workarounds that try to drain them (`DownloadAuthRetryHandler`, `BookReturnService`, `TPPUserAccount.signOut`). All three are critical-path, off-limits to F. Follow-up tickets proposed.

**Recommendation to swarm orchestrator**:
1. File the 5 follow-up tickets in section 4 — owners: the appropriate critical-path team.
2. The 2 test-side (iii) findings (F-iii-1, F-iii-2) can be picked up by a follow-up swarm or a one-off `/rigorous-fix` for DRMAdversarialTests (it's a real tautology test) and `/clean-code` for PersistentLoggerTests' `async` tearDown migration.
3. The lint expansion in work package E should consider adding a check for **`Task { ... }` in a non-`async` test method without `let ... = Task` capture** — would catch F-iii-1 statically.

— F implementer, swarm_47883816
