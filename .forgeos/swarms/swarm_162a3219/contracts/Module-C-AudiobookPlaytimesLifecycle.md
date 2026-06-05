# Module C — Audiobook playtimes tracker lifecycle on account switch

**Owner module:** Palace/Audiobooks/Tracker/ + Palace/Audiobooks/AudiobookSessionManager.swift (account-switch hook) + PalaceTests/Audiobooks/
**Risk:** critical_path (Palace/Audiobooks/ per CLAUDE.md)
**Est LOC:** ~400 (prod ~120, tests ~280)

## Background

Bug B per `.forgeos/handoffs/2026-06-05-icarus-cross-host-logout-regression.md`. After PR #1044's classifier fix prevents the visible logout, the bad request still gets sent — `AudiobookDataManager.syncValues()` keeps POSTing playtimes to host A (e.g. A1QA gorgon.staging) for a book whose `libraryId` does not match the current account (now Icarus / minotaur). Module C stops that request from being made in the first place.

The tracker (`Palace/Audiobooks/AudiobookTimeTracker.swift`) collects entries per-book and forwards them to `AudiobookDataManager` (`Palace/Audiobooks/Tracker/AudiobookDataManager.swift`). The manager queues entries by `LibraryBook(bookId, libraryId)` and on a 60s timer flushes the queue. Account-switch is signaled via `NotificationCenter.default.post(name: .TPPCurrentAccountDidChange)` in `AccountsManager.currentAccount.didSet` (line ~387 of `AccountsManager.swift`).

## Scope (in)

| File | Change | Est LOC |
|------|--------|---------|
| `Palace/Audiobooks/Tracker/AudiobookDataManager.swift` | (1) Add `currentAccountIdProvider: () -> String?` init parameter (default closure reads `AppContainer.production().accountsManager.currentAccountId`). NO PUBLIC_INTENT annotation needed per Phase-1a review (internal class, not Container file → BR-4 does not fire). (2) In `syncValues()` inner `for libraryBook in queuedLibraryBooks` loop, BEFORE the POST, guard: if `libraryBook.libraryId != currentAccountIdProvider()`, skip THIS upload but keep the entries queued (they'll flush when the user switches back to library X). Log via `audiobookLogger` and `TPPErrorLogger.logError` with `summary: "Skipping cross-account playtimes upload"`. (3) Add `subscribeToAccountChanges()` called from `init` — observe `.TPPCurrentAccountDidChange`, on fire invoke `audiobookLogger.logEvent(forBookId: "", event: "Account changed — cross-account playtimes uploads will be deferred to next foreground sync")`. NO destructive queue clear — entries are preserved for later flush. (4) Make the existing `for libraryBook in ...` loop aware: skipped uploads must NOT count toward `pendingCount` for the background task end check, OR the `if allComplete` block needs to handle the new skip path. Fix the background-task counting so `endBackgroundTask` still fires even when every entry is cross-account. | +70 |
| `Palace/Audiobooks/AudiobookSessionManager.swift` | NO production-code change (cancellation of in-flight audiobook session already handled by `cleanupActiveContentBeforeAccountSwitch` at `AccountsManager.swift:393` which calls `networkExecutor.cancelNonEssentialTasks()`). Module C adds ONE comment block at the account-switch hook documenting the playtimes-tracker contract: tracker uploads scope by `libraryId == currentAccountId`; on switch the queued entries persist but do not fire foreign POSTs. | +12 (comment only) |
| ~~`Palace/Audiobooks/Tracker/AudiobookDataManager.swift`~~ | **DROPPED per Phase-1a review:** ~~Add `// PUBLIC_INTENT:` annotations to new `currentAccountIdProvider` init parameter per BR-4.~~ BR-4 fires only on `*Container.swift` files. `AudiobookDataManager.swift` is `internal class` — neither public nor a Container file. Annotation unnecessary; blast-radius is expected clean without it. The first-row PUBLIC_INTENT-annotated note above is also dropped — see DoD check #11 below. | (n/a) |
| `Palace/AppInfrastructure/AppContainer.swift` | If `AudiobookDataManager` is wired through the container, add the closure injection. **Verify first via grep** — `grep -n "AudiobookDataManager(" Palace/` — if container wires it, update; if singleton-style instantiation, leave default. | +8 conditional |
| `PalaceTests/Audiobooks/AudiobookPlaytimesLifecycleTests.swift` (NEW) | The lifecycle test class. Round-trip wiring test PER CLAUDE.md "State-machine wiring tests must exercise round-trips" rule. Minimum 5 tests — see Tests section. | +180 |
| `PalaceTests/Mocks/SpyAudiobookNetworkExecutor.swift` (NEW or extend existing if present) | Spy that records `POST(_:useTokenIfAvailable:)` calls — captures requested URL + body so tests can assert "no POST to host A made post-switch". | +35 |
| `.forgeos/handoffs/2026-06-05-icarus-cross-host-logout-regression.md` | Mark Bug B resolved. Add a section "## Resolution log" with date + commit SHA + this swarm_id + the production file that owns the fix. | +15 |

## Scope (out — DO NOT touch)

- **PalaceAudiobookToolkit submodule** — Bug B is fixable at the Palace layer (`AudiobookDataManager` is the queue owner). Do NOT touch the submodule. The toolkit's `AudiobookPlaybackTrackerDelegate` protocol is unchanged.
- **Broader playtimes-tracker rewrite** — explicitly OUT per task spec. No timer policy change, no merging the per-book trackers, no upload-coalescing. JUST the cross-account scope guard + the observer.
- **Carthage release flow for the toolkit submodule** — OUT per task spec. No submodule version bump.
- **`networkExecutor.cancelNonEssentialTasks()` semantics** — already does the work for in-flight upload cancellation; do NOT touch. Module C complements it (prevents future uploads); cancellation handles current.
- **`AudiobookTimeTracker.swift`** — already correctly per-book scoped (its `libraryId` is fixed at init). Do NOT touch unless verification reveals a real defect.
- **`AudiobookSessionManager.swift`** beyond the comment block — the session manager already cancels active loads on account switch; the tracker is a separate downstream concern. No new field, no new closure.
- **State machine in `AudiobookSessionState`** — no new case, no transition change.

## Verification criteria (grep-able)

1. **Production seam wiring** —
   ```bash
   grep -n "currentAccountIdProvider\|currentAccountId\b" Palace/Audiobooks/Tracker/AudiobookDataManager.swift
   ```
   ≥ 2 lines (init parameter declaration + sync-loop guard).

2. **Cross-account skip is observable in log** —
   ```bash
   grep -n "Skipping cross-account playtimes upload\|cross-account playtimes" Palace/Audiobooks/Tracker/AudiobookDataManager.swift
   ```
   ≥ 1 line.

3. **Account-change subscription** —
   ```bash
   grep -n "TPPCurrentAccountDidChange" Palace/Audiobooks/Tracker/AudiobookDataManager.swift
   ```
   ≥ 1 line.

4. **No new POST sites in the Tracker dir** —
   ```bash
   grep -c '\.POST(' Palace/Audiobooks/Tracker/
   ```
   equal to the pre-PR count. The fix MUST be a guard BEFORE the existing POST, not a new POST path.

5. **Tracker tests instantiate the SUT** —
   ```bash
   grep -c "AudiobookDataManager(" PalaceTests/Audiobooks/AudiobookPlaytimesLifecycleTests.swift
   ```
   ≥ 1 (NEW SUT-instantiation per CLAUDE.md DoD #1).

6. **Round-trip wiring test exists** —
   ```bash
   grep -c "testPlaytimes_accountSwitch_skipsCrossAccountUpload\|switchedAccount_doesNotPostToForeignHost\|crossAccount.*roundtrip\|accountSwitch.*defers" PalaceTests/Audiobooks/AudiobookPlaytimesLifecycleTests.swift
   ```
   ≥ 1.

7. **Test-name-vs-body audit** —
   ```bash
   python3 scripts/check-test-name-vs-body.py PalaceTests/Audiobooks/AudiobookPlaytimesLifecycleTests.swift
   ```
   exit 0.

8. **Module B detector clean on the tracker dir** —
   ```bash
   python3 scripts/check-foreign-host-401-scoping.py --scan Palace/Audiobooks/Tracker/ --quiet
   ```
   exit 0 (no spurious additions).

9. **Mutation kill (diff-only) on the changed production file** —
   ```bash
   python3 scripts/palace_mutate.py \
     --file Palace/Audiobooks/Tracker/AudiobookDataManager.swift \
     --tests PalaceTests/AudiobookPlaytimesLifecycleTests \
     --diff-only
   ```
   ≥ **80% on changed lines** per CLAUDE.md critical-path rule (Palace/Audiobooks/ regex match). Per file-level invocation, paste kill rate.

10. **Contract reconciliation** — `python3 scripts/check-contract-reconciliation.py --commit-msg <commit-msg-file>` exit 0.

11. **Blast radius** — `python3 scripts/check-blast-radius.py --quiet` exit 0 (new init parameter on `AudiobookDataManager` is BR-4 — annotate with `// PUBLIC_INTENT: cross-account playtimes scope guard (Bug B, swarm_162a3219)` to clear).

12. **Superpartner spectrum** — `python3 scripts/check-superpartner-spectrum.py --quiet` exit 0 (new guard branch must have a matching test in the diff).

13. **Build + verify-pr** — `scripts/verify-pr.sh --quick` PASS. Paste tail. Audiobook cross-vendor smoke MUST pass (Module C touches a tracker file under `Palace/Audiobooks/`, triggering `AudiobookCrossVendorSmokeTests`).

14. **Bug B resolution log present** —
    ```bash
    grep -n "Resolution log\|## Resolved\|Module C\|swarm_162a3219" .forgeos/handoffs/2026-06-05-icarus-cross-host-logout-regression.md
    ```
    ≥ 1.

## Tests required

`PalaceTests/Audiobooks/AudiobookPlaytimesLifecycleTests.swift` — minimum 5 tests:

1. **`testPlaytimes_sameAccountUpload_postsNormally`** — happy path. Configure manager with `currentAccountIdProvider` returning libraryId X; enqueue an entry with libraryId X; fire `syncValues()`; assert spy network executor recorded exactly one POST with the expected URL + body.

2. **`testPlaytimes_accountSwitchedAway_skipsCrossAccountUploadButRetainsQueue`** — the critical-path round-trip. (a) Configure manager with provider returning libraryId X; enqueue entry for libraryId X. (b) `syncValues()` — confirm POST. (c) Change provider to return libraryId Y (simulate account switch — drive via `NotificationCenter.default.post(name: .TPPCurrentAccountDidChange)` if the manager observes). (d) Enqueue another entry for libraryId X (simulating tracker still running on old book). (e) Fire `syncValues()` — assert NO additional POST recorded by spy. (f) Switch back to libraryId X; `syncValues()` — assert the deferred entry now flushes (proves "retain queue" behavior). This is the production-seam round-trip test the CLAUDE.md state-machine rule mandates.

3. **`testPlaytimes_accountChangeNotification_doesNotClearQueue`** — drive the `.TPPCurrentAccountDidChange` notification with a populated queue; assert queue size unchanged + no POST fires.

4. **`testPlaytimes_skipDoesNotLeakBackgroundTask`** — invoke `syncValues()` with all entries cross-account; assert no `endBackgroundTask`-not-called leak. Use `UIApplication.shared.beginBackgroundTask` instrumentation (or a wrapper protocol if the existing code can be DI'd).

5. **`testPlaytimes_accountSwitch_doesNotPostToForeignHost_findawayScenario`** — cross-vendor smoke. Drive a Findaway-scenario libraryId mismatch (or — per `reference_audiobook_toolkit_risk_profile.md` — explicitly bind this test to the only-vendor that the playtimes endpoint exists on: it's a Palace circulation-manager endpoint, vendor-agnostic from the upload side. **Document in the test header** that the playtimes upload is vendor-agnostic — the LibraryBook scoping is per-library not per-vendor, so cross-vendor smoke is satisfied by ONE library-switch test rather than 4 vendor permutations). This satisfies `reference_audiobook_toolkit_risk_profile.md` requirement with explicit rationale rather than 4-vendor duplication.

**Cross-vendor smoke rationale (per the brief):** playtimes-tracker is downstream of the Palace circulation-manager `/playtimes/` REST endpoint, NOT of the audiobook vendor adapter chain. The bug class is vendor-agnostic — Findaway/OverDrive/LCP/open-access all upload through the same `AudiobookDataManager` to the same circulation-manager endpoint. One library-switch test exercises the scope guard for all vendors. This is documented in the test file header + the contract here so the qa reviewer doesn't reject for missing 4-vendor permutations.

## Round-trip wiring requirement (PER CLAUDE.md)

Test 2 above is the round-trip wiring test. Sets a state (provider returns X), changes state (switch to Y), drives the production seam (`syncValues()`), proves the negative (no foreign POST), restores state (switch back to X), drives seam again, proves entries flush. Full `enqueue → syncValues → switch → enqueue → syncValues (no POST) → switch back → syncValues (POST)` cycle through the PUBLIC production seam, NOT via direct `_setState`-style shortcuts. Pinned by the test name + body per CLAUDE.md DoD #1 and `scripts/check-test-name-vs-body.py`.

## Mutation requirement

`python3 scripts/palace_mutate.py --file Palace/Audiobooks/Tracker/AudiobookDataManager.swift --tests PalaceTests/AudiobookPlaytimesLifecycleTests --diff-only` ≥ 80% on changed lines (Palace/Audiobooks/ is a critical path per CLAUDE.md regex). Run BEFORE reporting READY (mandatory per DoD #5).

## Acceptance

- All 14 verification criteria pass
- All 5 new tests PASS in xcresult evidence (paste bundle path)
- Mutation kill ≥ 80% diff-only on `AudiobookDataManager.swift`
- `scripts/verify-pr.sh --quick` PASS including `audiobook_smoke`
- The handoff doc's Bug B section is marked Resolved with swarm_id + commit SHA
- The fix can be verified manually on the regression repro: borrow audiobook from library X, switch to library Y, observe per-minute playtimes upload no longer fires for library X's book (verify via `idevicesyslog` or AudiobookFileLogger). NOTE: manual verification is an out-of-band step Maurice may want to script via simdrive; not gating this contract.

## Wall-failure backfill

Update `.forgeos/wall-failures/2026-06-05-pr1018-icarus-cross-host-logout.md` to record Bug B's resolution: add a row to "Application log" showing "2026-06-XX — Bug B (playtimes lifecycle) resolved in swarm_162a3219 / Module C / commit <sha>; foreign POST eliminated at the source."
