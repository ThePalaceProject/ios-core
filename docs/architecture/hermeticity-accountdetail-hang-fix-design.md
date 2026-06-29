# Design — AccountDetailViewModel hang class (hermeticity leaker hunt)

**Status:** design-for-review (SoD). Investigation complete; see
`.forgeos/intent/hermeticity-leaker-accountdetail-vm.md` for the real-artifact
reproduction + spindump root cause.
**Owner:** test-hermeticity leaker hunt (palace-hermeticity).
**Approved direction (Chairman, 2026-06-29):** systemic, not the amplifier patch.
Each layer fixed at its root with a structural guard so the CLASS can't recur.

## The hang (one sentence)

A leaked `AccountDetailViewModel` `@MainActor` account-change observer re-runs an
O(~1142) `account()` linear scan on the main thread on every
`.TPPCurrentAccountDidChange` post — the posts driven by a real-network catalog
refresh churn — saturating the main thread >120s so the next async/main test
hangs (victim varies by shuffle: TPPSettings / CatalogPreloader / EPUBSearch).

## Fix A — remove MallocStackLogging from the test scheme  [DONE, hygiene]

`Palace.xcscheme` Test action carried `MallocStackLogging` +
`PrefersMallocStackLoggingLite` (Diagnostics-tab leftover). The spindump shows
~50% of the hot-loop leaf time is `stack_logging_lite_malloc` / `thread_stack_pcs`.
Removed both. **Hygiene, not the fix** — it reduces, not eliminates, the hang
(the O(n) loop + churn remain). Zero production change.

## Fix #1 — O(1) account lookup  [KEYSTONE · critical-path · design+SoD]

**Problem.** `AccountsManager.account(_:)` (AccountsManager.swift:455-461):
```swift
accountSets.values.first { $0.contains(where: { $0.uuid == uuid }) }?
           .first(where: { $0.uuid == uuid })
```
O(total accounts) linear scan under `accountSetsLock`, on the MAIN thread for
every account-change-driven `setupTableData`. With the bundled 1142-account
snapshot this is the saturation source. **This is the deepest fix: with O(1)
lookup, even a leaked observer firing costs ~nothing → no main saturation → no
hang. It is also a live-app perf win (every account switch pays this today).**

**Design.** Maintain a derived index alongside `accountSets`:
- Add `private var accountByUUID = [String: Account]()` (guarded by the same
  `accountSetsLock`).
- Rebuild it inside `performWrite` at EVERY `accountSets` mutation site (5 sites:
  :323, :491-500 seed, :1167, :1298 test-seam, and removal in :500). A single
  private `rebuildAccountIndex()` called at the end of each barrier write keeps
  it impossible to forget.
- `account(_:)` becomes `performRead { accountByUUID[uuid] }` — O(1).

**Semantics preserved.** Current code returns the first match across
`accountSets.values` (dict order nondeterministic). In practice a UUID lives in
exactly one bucket (a given registry hash); the index is uuid→Account. If a UUID
ever appeared in two buckets, last-rebuilt wins — acceptably equivalent to the
nondeterministic current behavior. Documented in the index doc-comment.

**Structural guard.** A unit test that seeds N accounts and asserts `account()`
returns the right Account AND a contract/perf test pinning that `account()` does
not scale with account count (e.g. lookups on a 1000-account set complete within
a tight budget) — so a regression back to a linear scan fails. Mutation: flipping
the index write must fail the lookup test.

## Fix #2 — observer-leak fix + promote the leak detector to a HARD gate

**Problem.** `AccountDetailViewModel` survives its test with active
`.TPPCurrentAccountDidChange` / `.TPPUserAccountDidChange` `@MainActor` Combine
observers. Retained because `loadInitialData()`'s `Task { @MainActor in
setupViews(); accountDidChange() }` captures `self` STRONGLY (no `[weak self]`),
and `ensureAuthenticationDocumentIsLoaded`'s chain keeps it alive on a slow
real-network auth-doc load. Tests create the VM as a local `let`, never torn down.

**UPDATE (2026-06-29) — the leak is a 4-hop RETAIN CYCLE, not just a strong-self Task.**
A hermetic leak-repro test (`AccountDetailViewModelLeakTests`, seeds an account,
no keychain gate) proved the VM does NOT deallocate even after the `loadInitialData`
weak-self fix. Spindump-independent root: the VM constructs
`TPPNetworkExecutor(credentialsProvider: self, …)` (AccountDetailViewModel.swift:157)
and hands it to `businessLogic`. The cycle:

  VM → `businessLogic` (strong, :50)
     → `networker` = the executor (TPPSignInBusinessLogic.swift:83, strong)
     → `responder` (TPPNetworkExecutor → TPPNetworkResponder, strong)
     → `credentialsProvider` (TPPNetworkResponder.swift:37, `private let` — STRONG)
     → **VM**

So every `AccountDetailViewModel` leaks in production (Settings → Account screen),
taking its account-change observers + a whole network stack with it. `uiDelegate`
is already `weak` (TPPSignInBusinessLogic.swift:120) and `userInputProvider` is
weak — `credentialsProvider` is the one strong back-edge.

**Root fix (CRITICAL-PATH — TPPNetworkResponder is the auth-error decision point;
architect + SoD REQUIRED):** make `TPPNetworkResponder.credentialsProvider` a
`weak var`. `NYPLBasicAuthCredentialsProvider` must be class-bound to allow weak;
the existing fallback at TPPNetworkResponder.swift:641 (`credentialsProvider ??
AppContainer.production().accountsManager.currentUserAccount`) already handles a
nil provider, so a deallocated transient provider degrades to the singleton —
which is the correct behavior. Verify no production caller relies on the responder
RETAINING a transient provider. Plus the `loadInitialData` weak-self cleanup.

**Structural guard:** the hermetic `AccountDetailViewModelLeakTests` dealloc
assertion (red-first: fails today, passes once the cycle is broken) + promoting
the NotificationCenter observer-leak detector below.

**Structural guard (the class-closer).** Promote the EXISTING warn-only
NotificationCenter observer-leak detector. Today `PalaceSingletonResetObserver.
testCaseDidFinish` measures `NotificationCenter.default` observer net-adds and
emits a `runActivity` warning — but `record()` from `testCaseDidFinish` is inert
(documented). Move the assertion into `PalaceTestCase.tearDownWithError` (the same
in-lifecycle pattern the defer-flag gate uses), so a test that leaves net
observer adds FAILS at its own boundary. A leaked VM (its Combine
`NotificationCenter.publisher` subscriptions count as observer adds) is then
caught structurally for the WHOLE leak class, not just this VM.
- Risk: false positives from tests that legitimately add process-lifetime
  observers. Mitigation: start warn-only-promoted on `PalaceTestCase` adopters,
  audit a full green run for zero false positives, THEN flip to `XCTFail` (same
  promotion discipline as the pool gate). Self-test both directions.

## Fix #3 — close the TPPNetworkExecutor real-network escape  [critical-path · design+SoD]

**Problem.** `NoNetworkURLProtocol.enable()` uses `URLProtocol.registerClass`,
which only covers `URLSession.shared` (e.g. `LibraryRegistryCrawler` — its
`/libraries/crawlable` requests ARE blocked). But `TPPNetworkExecutor` builds its
session via `URLSession(configuration:)`, whose `configuration.protocolClasses`
does NOT include `NoNetworkURLProtocol` → `AccountsManager.fallbackDirectRefresh
→ networkExecutor.GET` hits real `registry.palaceproject.io/libraries` (CI: 67s
elapsed, -1001 timeouts) → the loadCatalogs churn engine.

**Design options (for SoD):**
- (3a) Test-bootstrap: have `PalaceTestSetup` ensure every production
  `TPPNetworkExecutor` default session config includes `NoNetworkURLProtocol`
  first in `protocolClasses`. Cleanest if the executor reads a test-injectable
  default config.
- (3b) In DEBUG, `TPPNetworkExecutor`'s default `URLSessionConfiguration` prepends
  any globally-registered test URLProtocols. Small, contained, DEBUG-gated.
TPPNetworkExecutor already exposes `init(... sessionConfiguration:)` test inits —
prefer wiring those rather than new production surface.

**Structural guard.** A hermeticity test that drives `TPPNetworkExecutor.GET` to
a non-stub host and asserts it is BLOCKED (not a real request) — proving no test
executor can escape to the network. Pairs with a bootstrap assertion.

## Validation plan

1. Positive control: full suite iters-1 reproduces the hang (spindump shows the
   AccountDetailViewModel observer hot-loop). [1 spindump captured; 2nd in-flight]
2. After #1 (+A): re-run; spindump no longer shows the hot-loop; suite green.
3. After #2/#3: full suite **green twice at iters-1** (the DoD bar), plus the
   promoted observer-leak gate self-tested both directions, zero false positives
   on a full green run.
4. CI parity (iters-3) green; mutation on `account()` index + guards ≥ critical-path bar.
