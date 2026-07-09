# CP-D2 (CredentialSnapshot) — implementer transcript

Swarm swarm_27c181b5 Wave C. CRITICAL-PATH (auth / credential storage).
Architect Phase 1a: APPROVED with mandatory test amendments.

## Summary

Removed the per-read `invalidateAllKeychainCaches()` from
`TPPUserAccount.credentialSnapshot()` (previously fired on EVERY network
request build, at the `TPPNetworkExecutor.swift:403` call site). Coherence is
now carried by the write-through keychain cache + one-instance-per-library
invariant, with EVENT-DRIVEN invalidation at the two out-of-band boundaries:
sign-out finalisation (`removeAll()`) and account switch
(`AccountsManager.currentAccount.didSet`). Pure event-driven, no TTL — the
simplest safe design per Phase 1a.

No coherence hole surfaced; Phase 1a's proof held under investigation (see
below).

## Why removing per-read invalidation is safe (verified, not assumed)

1. **Write-through cache.** `TPPKeychainVariable.write()` /
   `TPPKeychainCodableVariable.write()` set `cachedValue` AND `alreadyInited =
   true` AND persist to the keychain in one synchronized block
   (`TPPKeychainStoredVariable.swift:51-63, 121-140`). So a write on an
   instance leaves that instance's cache fresh with no re-read needed.
2. **One instance per library UUID.** `AccountsManager.userAccount(for:)`
   (`AccountsManager.swift:759-768`) caches exactly one `TPPUserAccount` per
   UUID under `userAccountsLock`. The ONLY production `TPPUserAccount(libraryUUID:)`
   construction is inside that factory (grep confirmed — every other site is a
   test).
3. **Writer and readers share that one instance.** Sign-in/out writes:
   `TPPSignInBusinessLogic.userAccount` returns
   `libraryAccountsProvider.userAccount(for: libraryAccountID)`
   (`TPPSignInBusinessLogic.swift:886-887`); the deprecated `sharedAccount(...)`
   shims also delegate to `accountsManager.userAccount(for:)`. Reads:
   `AccountDetailViewModel` (:150/567/598), `TPPNetworkExecutor` (:403/446/479/654),
   `TPPNetworkResponder` (:391/460) all go through `userAccount(for:)` /
   `currentUserAccount`. Same cached instance ⇒ write-through keeps them coherent.
4. **No cross-process writer.** No app-groups / keychain-sharing / extensions in
   entitlements (Phase 1a). Per-read invalidation was pure overhead on the
   request hot path — the build-459 bug it papered over (singleton writer vs.
   per-account reader) no longer exists.

## Files changed

Production (surgical — 3 edits, 2 files):
- `Palace/Accounts/User/TPPUserAccount.swift`
  - `credentialSnapshot()` — removed the `if libraryUUID != nil {
    invalidateAllKeychainCaches() }` per-read block; documented the new contract.
  - Added `invalidateCredentialCaches()` — public event-driven invalidation
    (wraps `invalidateAllKeychainCaches()` in `accountInfoQueue.sync`;
    re-entrancy-safe because each keychain var's transaction shares
    `accountInfoQueue` and `perform` runs inline via `getSpecific`).
  - `removeAll()` — added an `invalidateAllKeychainCaches()` at the end of the
    keychain transaction, synchronously BEFORE the `.TPPDidSignOut` post, so no
    consumer can observe a stale "signed in" after sign-out.
- `Palace/Accounts/Library/AccountsManager.swift`
  - `currentAccount.didSet` — after `currentAccountId = newValue?.uuid`, added
    `if previousAccountId != newAccountId, let newId = newAccountId {
    userAccount(for: newId).invalidateCredentialCaches() }`. Fires only on a
    real change (nil→B, A→B), not a redundant B→B.

**`TPPNetworkExecutor.swift` was NOT edited.** The `:403` site is just
`...credentialSnapshot()`; the invalidation lived inside `credentialSnapshot()`,
so removing it there is the whole change. Leaving the executor untouched keeps
blast radius off that critical file. Wave B's `clearCache()` at `:421` untouched.

Tests:
- `PalaceTests/Accounts/CredentialSnapshotInvalidationTests.swift` (NEW, added to
  PalaceTests target via `pbxproj_add_swift.rb`) — 4 classes, 5 tests (below).
- `PalaceTests/SignInLogic/TPPCredentialSnapshotCoherenceTests.swift` (companion
  edit — see Scope note) — the 3 peer-instance tests now fire the invalidation
  EVENT between the peer write and the coherence read (the production seam),
  since per-read invalidation is gone. Header docstring updated to the new
  contract. This file was a direct casualty of the contract change: its premise
  (singleton-writer vs. per-account-reader staleness) is exactly what CP-D2
  retires; it was pinning the removed mechanism.

## Tests (Phase 1a mandatory amendments, all covered)

1. **Sign-out staleness through the REAL production seam
   (`AccountDetailViewModel`)** —
   `testSignOut_ThroughAccountDetailViewModel_GoesSignedInToSignedOut_neverStaleSignedIn`:
   signs in the cached instance, drives the VM to `isSignedIn=true`, `removeAll()`,
   `refreshSignInState()` → asserts `isSignedIn=false` AND the underlying snapshot
   `hasCredentials=false` / `authState=.loggedOut`. Never reads "signed in" after
   sign-out.
2. **Account-switch invalidation through the REAL `currentAccount` setter** —
   `testAccountSwitch_invalidatesNewlyCurrentAccountCredentialCache`: fresh
   isolated `AccountsManager`, seed fixture, nil→B switch (heavy A→B cleanup
   branch skipped; fixture state pre-set to `.detailsFailed(.accountNotFound)` so
   `driveCurrentAccountAuthDocIfNeeded()` early-returns with no network). Managed
   instance primed signed-out, peer writes out-of-band, `mgr.currentAccount =
   fixture` must invalidate → next snapshot re-reads and sees the peer write.
   **This kills the `!=`→`==` mutant on the switch guard** (mutated, nil==B is
   false, invalidation skipped, stale cache persists, assert fails).
3. **Cache-hit: no keychain re-read within a no-event window (read-count spy)** —
   `testCredentialSnapshot_withinNoInvalidationEvent_hitsCacheAndDoesNotRereadKeychain`
   (+ the `peerRemoveAll` mirror). Behavioural read spy: a peer write under the
   same keys is INVISIBLE to a primed reader until an invalidation event fires.
   Invisibility ⇒ the read was served from cache (no re-read); a re-read would
   necessarily surface the peer write. **This kills the "restore per-read
   invalidation" mutant** (restored, peer write surfaces, `XCTAssertFalse` fails)
   AND the "make `invalidateCredentialCaches()` a no-op" mutant (no-op, event
   read stays stale, final `XCTAssertTrue` fails).
4. **TPPNetworkResponder 401-decision NOT weakened (OFF-LIMITS, not edited)** —
   `testCurrentUserAccountSnapshot_reflectsSignInThenSignOut_soReauthDecisionInputIsNeverStale`
   drives the exact read seam the responder consumes
   (`accountsManager.currentUserAccount.credentialSnapshot()`, responder
   :391/460). After sign-in it reads signed-in (a stale "signed out" would
   trigger a spurious logout); after sign-out it reads signed-out (a stale
   "signed in" would suppress legitimate re-auth). Test method name deliberately
   omits the `TPPNetworkResponder` class noun (the class is off-limits/not
   constructed) so `check-test-name-vs-body.py` stays clean.

### TPPNetworkResponder-not-weakened reasoning (ordering proof)

The responder reads `currentUserAccount.credentialSnapshot()`.
`currentUserAccount` resolves to `userAccount(for: currentAccountId)` — the SAME
cached instance the sign-in/out pipeline writes. Write-through means the
responder always sees the last completed write without any invalidation. On
sign-out, `removeAll()` (a) write-throughs every var to nil and (b) calls
`invalidateAllKeychainCaches()` synchronously, BOTH inside the keychain
transaction and BEFORE `NotificationCenter.post(.TPPDidSignOut)` and before
`removeAll()` returns. Therefore any 401-decision read that happens after
sign-out completes observes signed-out state — the event-driven invalidation
provably fires before any subsequent snapshot read. A stale "signed in" (suppress
re-auth) or stale "signed out" (spurious logout) is impossible on this seam.

## Definition-of-Done evidence

- **check-test-name-vs-body.py** — new file: `OK, 0 fake-wiring` (exit 0);
  edited coherence file: `OK, 0 fake-wiring` (exit 0).
- **SUT instantiation** — new file: `TPPUserAccount(`=3, `AccountDetailViewModel(`=1,
  `.credentialSnapshot()`=17. All SUTs constructed.
- **Multi-step test-body check** — `testSignOut_...GoesSignedInToSignedOut...`
  and `..._reflectsSignInThenSignOut...` drive every named step (sign-in →
  assert → sign-out → assert). `testAccountSwitch_...` drives prime → out-of-band
  write → real switch → assert. No commented-out halves.
- **Scope audit** — all 4 Phase 1a test amendments landed; production change in
  the 2 permitted files; executor untouched (invalidation was internal to
  `credentialSnapshot()`).
- **pbxproj** — new test file added to PalaceTests target (`added=1`).

### Deferred to integration (blocked by task constraint "do NOT run git or a full app build")

- **Build + verify-pr --quick** — requires xcodebuild/sim.
- **Mutation (`palace_mutate.py --diff-only`)** — requires build. Diff-scoped
  mutants and expected kills documented above (switch-guard `!=`→`==` killed by
  test 2; per-read-invalidation-restored killed by test 3; invalidateCredentialCaches
  no-op killed by test 3). Run at integration with `verify-pr.sh --quick
  --enforce-mutations`.
- **blast-radius / contract-reconciliation / superpartner / adjacency** — all
  consume `git diff`; run at integration. Note new public API surface:
  `TPPUserAccount.invalidateCredentialCaches()` (intentional — the event-driven
  seam; consumed by `AccountsManager` + tests).

## Status: READY (pending the build-dependent gates above, which the constraint
forbids me from running locally — flagged, not skipped).

---

## Integration fix — test-pollution (2026-07-08)

**Finding (coordinator):** running the Wave-C set together, `AccountsManagerStateMachineWiringTests.testSingleFlight_twoConcurrentAwaiters_oneNetworkRequest` failed (`.detailsLoading` count 2, expected 1) ONLY when the CP-D2 credential classes ran first. Root cause: tests #1 and #4 drove the real `AccountDetailViewModel` / `currentUserAccount` against the SHARED production `AppContainer.production().accountsManager`; the view-model's init fires an auth-doc fetch that left in-flight `.detailsLoading`/current-account state bleeding across classes.

**Fix (isolation, mirrors the account-switch test #2 discipline):**
- Consolidated all 5 tests into ONE class `CredentialSnapshotInvalidationTests` (also makes the `-only-testing:PalaceTests/CredentialSnapshotInvalidationTests` selector resolve).
- Base class is now `PalaceWiringTestCase` (pre-test `SingletonResetRegistry.invokeAll()` + disk purge).
- Tests #1 and #4 now run on an ISOLATED fresh `AccountsManager` (`makeFreshAccountsManager(defaults: testUserDefaults())` + `makeTestAppContainer(accountsManager:)`) with a unique seeded fixture and a pre-set `.detailsFailed(.accountNotFound)` terminal — so the VM's init-time auth-doc fetch lands on the throwaway manager/UUID and cannot touch the production singleton or the single-flight test's UUID. The SAME real seams are still exercised (real `AccountDetailViewModel`, real `credentialSnapshot`, real `currentUserAccount`) — only the backing manager is isolated. The write-through coherence property under test is manager-agnostic (the responder uses the production manager; behaviour is identical).
- `tearDownWithError` defensively drains the production manager (`cancelAndDrainBackgroundWork()`) and wipes `AccountStateStore.shared._resetAllForTesting()` as belt-and-suspenders.
- Test #1's method is `@MainActor` (the VM init/`refreshSignInState`/`isSignedIn` are MainActor-isolated; sync XCTest methods are nonisolated at compile time).

**Verification (sim 141BD227 only, isolated derivedDataPath):**
`-only-testing` the 5 classes together (AccountsManagerLaunchSnapshotTests, AccountsManagerStateMachineWiringTests, CredentialSnapshotInvalidationTests, TPPCredentialSnapshotCoherenceTests, TPPSignInBusinessLogicSignOutTests) →
`Test Suite 'Selected tests' passed — Executed 44 tests, with 0 failures (0 unexpected)`, `** TEST SUCCEEDED **`. Single-flight test now counts 1 (0 failures). check-test-name-vs-body.py: exit 0.
