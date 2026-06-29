---
name: accountdetail-leak-cycle-and-hermetic-network
created: 2026-06-29
author: claude
type: bugfix
---

# accountdetail-leak-cycle-and-hermetic-network

Design-first SoD follow-up to `hermeticity-leaker-accountdetail-vm` (the hang fix
#1 O(1) index + fix A shipped + green-twice on branch
`fix/test-hermeticity-leaker-hunt`). These are the deeper PROD-weakness roots the
hang fix neutralized but did not remove. Chairman bar: fix prod at root + test
hard (red-first), not test-side workarounds. Bundled as ONE SoD-reviewed change
(palace-pm decision: (b) then (c)). NOT bundled into #1 — #1 stays the clean
hang-fix.

## Claims

- **#2 — break the AccountDetailViewModel retain cycle (real prod leak).** Make
  `TPPNetworkResponder.credentialsProvider` `weak` so the cycle
  VM -> businessLogic -> networker(TPPNetworkExecutor) -> responder ->
  credentialsProvider(=VM) no longer retains the VM. The nil-fallback at
  `TPPNetworkResponder.swift:641` (`?? AppContainer.production().accountsManager
  .currentUserAccount`) already covers a deallocated transient provider.
  Plus `[weak self]` on `AccountDetailViewModel.loadInitialData`'s init Task.
- **#3 — close the test real-network escape.** Route the test-time
  `TPPNetworkExecutor` session through `NoNetworkURLProtocol` via the EXISTING
  `init(sessionConfiguration:)` seam (palace-pm decision: 3a-via-existing-inits,
  NOT new `#if DEBUG` prod surface) so `AccountsManager.fallbackDirectRefresh ->
  networkExecutor.GET` cannot reach `registry.palaceproject.io` in tests.
- **structural guards:** (a) hermetic `AccountDetailViewModelLeakTests` dealloc
  assertion (red-first: fails if the cycle returns); (b) promote the warn-only
  NotificationCenter observer-leak detector (`PalaceSingletonResetObserver`
  net-adds) to a HARD gate via `PalaceTestCase.tearDownWithError`, after a
  zero-false-positive audit on a full green run; (c) a hermeticity test proving
  no test `TPPNetworkExecutor` escapes to a non-stub host.

## Anti-claims

- does NOT change the #1 O(1) index or fix A (already landed).
- does NOT add `#if DEBUG` to production network code (blast-radius rule; use the
  existing test-injection init).
- does NOT change `TPPNetworkResponder`'s auth-error decision logic — only the
  ownership (`let` -> `weak var`) of `credentialsProvider`, with the existing nil
  fallback preserved.

## Files in scope

- Palace/Network/TPPNetworkResponder.swift (credentialsProvider weak — CRITICAL-PATH)
- Palace/Settings/AccountDetailViewModel.swift (loadInitialData [weak self])
- PalaceTests/ViewModels/AccountDetailViewModelLeakTests.swift (re-add; red-first)
- PalaceTests/Support/PalaceTestCase.swift + PalaceTests/PalaceTestSetup.swift (observer-leak gate promotion)
- PalaceTests/NoNetworkURLProtocol.swift / bootstrap + TPPNetworkExecutor test session wiring (#3)
- PalaceTests/Network/* (executor block-test)

## Reproduction

The hermetic `AccountDetailViewModelLeakTests.testViewModel_deallocatesAfterRelease`
(written + run 2026-06-29, then held out of #1) asserts the VM deallocates after
release; it FAILED (weak ref non-nil) even after the loadInitialData weak-self
change, proving the leak is the 4-hop retain cycle, not just the init Task.
Real-network escape evidenced in #1122 CI: `registry.palaceproject.io/libraries`
GET, 67s elapsed, -1001 timeouts (TPPNetworkExecutor session not covered by
NoNetworkURLProtocol, which only catches URLSession.shared).

## Root cause

`TPPNetworkResponder.swift:37` stores `credentialsProvider` as a strong
`private let`; the VM passes itself as the provider
(`AccountDetailViewModel.swift:157`), closing the cycle. `uiDelegate`
(TPPSignInBusinessLogic.swift:120) and `userInputProvider`
(TPPUserAccountFrontEndValidation.swift:63) are already weak — credentialsProvider
is the one strong back-edge. For #3: `URLProtocol.registerClass`
(NoNetworkURLProtocol.enable) only affects URLSession.shared; TPPNetworkExecutor
builds its own `URLSession(configuration:)` whose `protocolClasses` omits
NoNetworkURLProtocol.

## Deferred / related (palace-pm decisions, 2026-06-29)

- **Pool-responsiveness gate warn->hard (charter Deliverable A): DEFERRED, keep
  WARN-ONLY** (decision (ii)). It guards class-4 (pool-starvation), which the
  real artifact RULED OUT for this hang (17 WS0-POOL-DIAG all completed=true);
  it already earned its keep AS the diagnostic that ruled pool-starvation out.
  Promote to hard ONLY after a real false-positive audit, if class-4 ever bites.
  The observer-leak gate below is the correct guard for the class we fixed.
- **qa optional follow-ups (fold in if cheap):** (1) pin the dup-UUID
  cross-bucket tie-break (`buildAccountIndex` last-wins — the one behavior change
  vs the old nondeterministic scan); (2) keep `AccountsManager.swift` in the
  pre-release `palace_mutate` run so the 50% floor stays honest.

## Verification

TBD on implementation: red-first leak-repro fails -> passes when the cycle is
broken; observer-leak gate self-tested both directions + zero-false-positive
audit; executor block-test proves no test escapes to the real registry; full
suite green; architect + qa SoD on the critical-path TPPNetworkResponder change.
