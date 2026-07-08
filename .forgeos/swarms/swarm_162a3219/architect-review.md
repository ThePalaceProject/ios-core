# Architect post-review — swarm_162a3219

**Reviewer:** forge-architect-reviewer subagent
**Date:** 2026-06-05
**Verdict:** APPROVED-WITH-CHANGES

## Findings

### Check 1: Scope-vs-reality (per module)

**Module A (Phase35-Meta) — PASS.**
All 6 target files exist or are intentionally NEW. The Phase 3.5 content insertion specs are accurate against the current `rigorous-fix/SKILL.md` and `swarm/SKILL.md` structure. Greppable verification criteria (≥4 hits on "Phase 3.5") are reasonable. Note: Module A's contract correctly says NEW `docs/architecture/phase-3.5-class-scan.md` — confirmed no such file exists yet.

**Module B (ForeignHost401Detector) — APPROVED-WITH-CHANGES.**

The architect predicts "0 survivors" after PR #1044. Mostly correct — the 3 known dispatch sites (`TPPNetworkResponder.swift:492-531`, `TokenRefreshInterceptor.swift:106-128`, `DownloadAuthRetryHandler.swift:212-236`) are all properly guarded with `authSurfaceHosts` / `currentAccountHostsProvider` references in scope. Verified via direct grep.

**HOWEVER, the architect missed a real survivor**: `Palace/Network/TPPNetworkExecutor.swift:582-585` matches the SEMANTIC bug class:

```swift
if let nsError = error as? NSError, nsError.code == 401 {
    ...
    self.accountsManager.userAccount(for: capturedAccountId ?? self.accountsManager.currentAccountId ?? "").markCredentialsStale()
    ...
}
```

The detector spec only looks for `statusCode == 401` / `.statusCode == 401`. This site uses `nsError.code == 401` — the SAME semantic 401 dispatch but a different syntactic form. The dispatch uses `capturedAccountId ?? currentAccountId` — a fallback to current account that is NOT proven host-scoped. If the token refresh runs for account A but currentAccountId is B (rapid library swap during a token refresh), this still mis-attributes. The detector as specified will miss this site.

**Required change**: Extend FH-1 trigger predicate to include `nsError.code == 401` and `error.code == 401` patterns when paired with a `markCredentialsStale` / `refreshCredentialsIfNeeded` call. Predicted-0-survivors becomes predicted-1-survivor (`TPPNetworkExecutor.swift:582`). Triage: either annotate with `// no-host-scoping: token-refresh closure already binds capturedAccountId, see fix-contract.md` OR add an inline `authSurfaceHosts` guard. Either way the detector spec is wrong if it can't see this site.

A second site worth review (not blocking): `Palace/Audiobooks/AudiobookSessionManager.swift:1552` dispatches `refreshCredentialsIfNeeded(reason: .samlSessionExpired)` from a `.playbackFailed` branch where `shouldTriggerSAMLReauthForPlaybackFailure(...)` is the gate (NO literal `statusCode == 401` in the function body). This is INTENTIONAL — the gate is upstream — but should be explicitly listed in the "Possible false-positive sites that need `// no-host-scoping:`" subsection of the contract so the implementer doesn't waste time on it.

**Module C (AudiobookPlaytimesLifecycle) — PASS with one annotation requirement.**

Production seam claim verified: `AudiobookDataManager.syncValues()` at lines 147-287 has the loop at line 175 with the POST at line 198 — guard insertion point is correct. The init signature at line 115 accepts the new closure parameter cleanly. Notification mechanism at `AccountsManager.swift:387` exists as claimed.

The contract is right that `currentAccountIdProvider` addition is a BR-4 finding (composition-root churn — even though `AudiobookDataManager` is not in `AppContainer.swift` itself, BR-4 also flags init param additions to `*Container.swift` files only — the spec is "any `*Container.swift`"). `AudiobookDataManager.swift` is NOT a `*Container.swift`. **BR-4 does NOT apply here.** The contract's verification criterion #11 is slightly wrong — BR-1 (`public` symbol on init) would apply if the new param exposes a public seam, but Swift `internal` (default) accessor on a `class` init param does NOT trigger BR-1 either. The PUBLIC_INTENT annotation is unnecessary unless the existing `init` signature is `public`. Grep confirms: `class AudiobookDataManager` (line 102) — `internal` default. **The PUBLIC_INTENT annotation is not required; remove that requirement from the contract.**

**Module D1 (LCPAcquisitionChainRecursive) — APPROVED-WITH-CHANGES (BLOCKING).**

Two scope errors:
1. **Wrong path: `Palace/Reader3/` does NOT exist** — `ls Palace/` shows only `Reader2/` and `ReaderStreaming/`. The architect appears to have referenced an outdated CLAUDE.md structure note.
2. **`Palace/Audiobooks/` is MISSING from the scan scope** — yet PP-4407 is the audiobook bug. The actual file with the OLD pattern still partially present is `Palace/Audiobooks/LCP/LCPAudiobooks.swift:200-201`:

```swift
guard let defaultAcquisition = book.defaultAcquisition else { return false }
return book.defaultBookContentType == .audiobook && defaultAcquisition.type == expectedAcquisitionType
```

The fix lives in the same file at line 217 (`hasLCPAcquisition`). The detector spec MUST include `Palace/Audiobooks/` in the scan and the spec must distinguish between "the bad pattern" (line 200, non-recursive direct check) and "the canonical fix" (line 217, recursive via `indirectChainContainsLCP`). Without that, the detector either misses the original bug class home or false-positives the canonical fix.

**Required change**: Contract must specify scan dirs as `Palace/MyBooks/`, `Palace/Reader2/`, `Palace/Audiobooks/`, `Palace/OPDS2/` (drop `Reader3/`). Spec also needs a refinement: a function that calls `hasLCPAcquisition(_:)` is CLEAN; a function that uses `defaultAcquisition.type ==` without the recursive walk is the violation.

**Module D2 (SwiftUIPlaceholderA11y) — PASS.**
4 tests + caption/a11yLabel-aware spec is reasonable. Scan dirs `Palace/SignInLogic/` + `Palace/Settings/` are correct. Standard risk tier.

**Module D3 (CompletionNilErrorSuppression) — APPROVED-WITH-CHANGES.**

Detector trigger is `completion?(nil, ` — too broad. Verified at least one false-positive: `Palace/SignInLogic/TPPSignInBusinessLogic+OAuth.swift:244` calls `completion?(nil, nil, nil)` in the SUCCESS PATH after `validateCredentials()`. This is correct semantics, not the bug class. Also matched by detector spec: `Palace/Network/TPPNetworkExecutor.swift:464,484` (`completion?(nil, response, error)` in failure-passthrough — the error IS present).

**Required change**: Tighten spec — flag ONLY when `nil` is in the error position AND args 2-3 contain string literals (not nil, not variable references) — the specific PP-4419 bug shape is `completion(nil, "Sign-in failed", "...")` not `completion(nil, nil, nil)`. Update fixtures accordingly.

**Module D4 (NSErrorProblemDocPreservation) — PASS.**
Detector scope (Palace/Network/, Palace/SignInLogic/) is correct. The 4 `NSError(domain: TPPErrorLogger.clientDomain` sites in `TPPNetworkExecutor.swift` are legitimate candidates for the detector to evaluate (no HTTP response data in scope = pass; with HTTP response = potential flag).

**Module D5 (NotificationCenterObserverStorage) — PASS.**
Verified 3 known-suspect sites in `TPPAppDelegate.swift:129`, `NotificationService.swift:139,143` — all unstored. `DLNavigator.swift:107` does store via `token = ...`. Predicted 2-6 is accurate.

**Module D6 (D-scan) — PASS.**
Observation-only; no live verification needed.

### Check 2: Off-limits completeness

Module A correctly excludes existing wall-failure entries from retrofit (B handles its own backfill).
Module B excludes `AuthErrorClassifier.swift`, `Account.swift` `authSurfaceHosts`, the 3 known guarded dispatch sites — clean.
Module C excludes PalaceAudiobookToolkit submodule, broader playtimes rewrite, Carthage release flow, `networkExecutor.cancelNonEssentialTasks()` semantics, `AudiobookTimeTracker.swift`, `AudiobookSessionState` enum — clean and explicit, satisfying the user's stated off-limits requirements.
D1-D5 each list out-of-scope patterns reasonably (UIKit, KVO, etc.).

**Gap**: Module C's "Scope (out)" does NOT explicitly exclude `AuthCoordinator.swift` (mentioned in the user's review prompt). Implementer should be told NOT to touch coordinator recovery strategy. **Minor nit, not blocking.**

### Check 3: Verification-criteria validity

Sample-run greps:
- Module A criterion 1: `grep -c "Phase 3.5" .claude/skills/rigorous-fix/SKILL.md` ≥ 4 — valid; will pass once Module A lands.
- Module B criterion 6: `pytest scripts/test_check_foreign_host_401_scoping.py -v` — valid invocation.
- Module B criterion 1: `python3 scripts/check-foreign-host-401-scoping.py --scan Palace/ --quiet` — depends on detector spec being correct (see Check 1 Module B).
- Module C criterion 9 (mutation): `palace_mutate.py --diff-only` — valid CLAUDE.md-mandated invocation.
- Module C criterion 5 (SUT instantiation): `grep -c "AudiobookDataManager(" ...` — valid DoD #1 check.
- Module C criterion 7 (test-name-vs-body): `python3 scripts/check-test-name-vs-body.py` — exists and runnable.
- Module D1-D5 criteria mostly inherited from D1 ("same shape as D1") — boilerplate but functional.

**Concern**: Module C criterion 11 — `check-blast-radius.py` BR-4 incorrectly applied; see Check 1 Module C.

### Check 4: Cross-module dependencies

Manifest declares `depends_on: [A-Phase35-Meta]` for B, D1-D5. Reading Module A's actual deliverables, the convention (TEMPLATE.md additions, `detector_script:` frontmatter spec) is needed by B, D1-D5 only at the wall-failure-entry authoring step — NOT for detector script construction itself. B and D1-D5 can build the Python detector + tests in parallel with A; the wall-failure entry frontmatter just needs A's TEMPLATE convention to be authoritative by integration time.

**Recommendation**: Treat A as a "soft dependency" — all 9 modules can dispatch in parallel. The architect's plan.md already acknowledges this ("In practice all 9 can run in parallel if implementers are willing to use the contract-documented Phase 3.5 convention even before Module A lands"). This is correct; Phase 2 orchestrator should launch all 9 in one wave with explicit instruction that D1-D5+B may reference the contract-documented frontmatter convention before A's docs merge.

### Check 5: Call-graph completeness (Module C focus)

The contract traces:
- `AccountsManager.currentAccount.didSet` (`AccountsManager.swift:387`) — posts `.TPPCurrentAccountDidChange` ✅
- `cleanupActiveContentBeforeAccountSwitch` (`AccountsManager.swift:393`) — calls `networkExecutor.cancelNonEssentialTasks()` to kill in-flight requests ✅
- `AudiobookDataManager.subscribeToAccountChanges()` (NEW) — observes the notification ✅
- `AudiobookDataManager.syncValues()` (`AudiobookDataManager.swift:147`) — the production seam ✅
- Guard at line 175 loop body — skips POST for cross-account libraryBook ✅
- `endBackgroundTask` accounting — contract explicitly addresses the new skip path ✅
- Pending uploads' fate — contract explicitly preserves queue entries for re-flush on switch-back ✅

**Round-trip wiring**: Test 2 (`testPlaytimes_accountSwitchedAway_skipsCrossAccountUploadButRetainsQueue`) drives enqueue → syncValues (POST) → switch → enqueue → syncValues (no POST) → switch back → syncValues (POST). Matches CLAUDE.md "Write → reset → re-enter" via production seam. ✅

**One graph gap**: The contract does NOT explicitly trace what happens to an in-flight POST (one currently mid-flight when the switch fires). It relies on `networkExecutor.cancelNonEssentialTasks()` from `cleanupActiveContentBeforeAccountSwitch` — but that's an opaque external dep. Implementer should verify that "cancellation" + "post-cancellation retry" doesn't reinstate the foreign POST via a network-queue replay. Test 2 already exercises this implicitly by not POSTing after the switch, but an explicit assertion ("spy executor recorded NO POST after the cancel-notification fires") would tighten the contract.

**Recommendation, non-blocking**: Add to Module C Test 4 (or a Test 6) an explicit cancellation/replay check: enqueue + start `syncValues()` + fire notification mid-flight + assert post-switch POST count = 0.

## Risk-tier decisions

**Module A (`critical_path_meta`)**: This Phase 1a architect review IS the architect review for A. A also goes through Phase 4 SoD review per the swarm convention. Meta-tooling gets the FULL bar because (a) it shapes every future swarm/rigorous-fix, and (b) docs-only modules have historically slipped substandard structure under "it's just docs" exemptions. The `critical_path_meta` tier is appropriate; no lighter bar warranted.

**Modules B, C, D1, D3, D4 (`critical_path`)**: standard full bar per CLAUDE.md "Risk-driven rigor bar" — architect + qa + blast_radius reviewers required.

**Modules D2, D5, D6 (`standard`)**: standard bar.

## Dependency graph recommendation

Recommend single-wave 9-way parallel dispatch. Module A's convention is documented in its own contract; D1-D5 + B can reference that convention while authoring their wall-failure entries. Integration (Phase 4) reconciles — if A's eventual docs deviate from the contract-stated convention, that's an A finding, not a D1-D5 finding. The 1-wave-vs-2-wave choice saves wall time without risk because (a) all 9 modules touch independent file sets (zero merge conflicts predicted), (b) A's deliverables don't gate the others' Python code construction, and (c) the orchestrator already has the Phase 2 BLOCKED-on-conflict guard.

## Module D6 cost/value verdict

D6 is worth the swarm overhead. It's NOT pure observation — it produces 3 outcome docs + follow-up Jira tickets that seed the next swarm's audit pipeline. Total cost: ~1 implementer slot, ~60 LOC docs. Value: avoids future bug-class recurrence on (i) Timer-nil-on-background, (ii) lock-screen-engagement suspend, (iii) VoiceOver row activation — three classes that genuinely don't fit a static detector but DO fit Tier 2 Explore subagent scans. Treating these as deferred follow-ups outside the swarm would lose the audit context and bias the next swarm against revisiting them.

## Required changes before Phase 2 (APPROVED-WITH-CHANGES)

1. **Module B**: Extend FH-1 detector spec trigger predicate to also match `nsError.code == 401` and `error.code == 401` patterns. Predicted-0 becomes predicted-1 (`TPPNetworkExecutor.swift:582`). Update the "Possible false-positive sites" subsection to include `Palace/Audiobooks/AudiobookSessionManager.swift:1552` (intentional gate via `shouldTriggerSAMLReauthForPlaybackFailure`, annotate with `// no-host-scoping:`).

2. **Module C**: Drop the `// PUBLIC_INTENT:` annotation requirement on the new `currentAccountIdProvider` init parameter. `AudiobookDataManager` is `internal` (not public, not a `*Container.swift`) — BR-4 does NOT apply. Verification criterion #11 needs the BR-4 reasoning removed; replace with a note that blast-radius is expected to be clean.

3. **Module D1**: Fix scan-dir scope. Replace `Palace/Reader3/` (nonexistent) with `Palace/Audiobooks/` + `Palace/OPDS2/`. Update predicted-survivors to include `Palace/Audiobooks/LCP/LCPAudiobooks.swift:200-201` (the OLD non-recursive predicate still present in the codebase alongside the canonical recursive fix at line 217). Spec must distinguish "calls `hasLCPAcquisition(_:)`" (clean) from "uses `defaultAcquisition.type ==`" (violation).

4. **Module D3**: Tighten detector trigger to require string literals in positions 2-3 (the title/message args), NOT the all-nil success-path shape. Otherwise `TPPSignInBusinessLogic+OAuth.swift:244` becomes a false positive that needs an annotation.

## Risk highlights for the orchestrator

- **Module B Python coverage gate**: 80% line coverage on the detector is the established convention but tied directly to the FH-1 trigger predicate quality. If predicate is too narrow (`statusCode == 401` only, no `error.code == 401`), the class can recur from `TPPNetworkExecutor.swift:582` and the wall has a structural hole. Fix the predicate first.

- **Module C round-trip wiring**: The contract correctly uses CLAUDE.md state-machine wiring rule, but the cross-vendor smoke rationale (vendor-agnostic playtimes endpoint) is correct AND politically risky — qa reviewer may push back. The architect pre-justified it in the test header AND the contract. If qa pushes back at Phase 4, the rationale lives in two places; do not capitulate without re-examining whether playtimes truly is vendor-agnostic (verify by reading the circulation-manager backend doc).

- **All D-detectors share a Python coverage convention** but each test file must independently hit ≥80% line coverage on its detector. The architect's "(analogous to D1)" boilerplate in D2-D5 contracts is acceptable shorthand but each implementer should not skip the coverage measurement.

- **9-way parallel dispatch is the right move**, but the orchestrator's Phase 2 conflict-detection must be alert to two predictable churn points: (1) `scripts/verify-pr.sh` (6 detectors all add a `run_m1_check` block), and (2) `.claude/settings.json` (6 hook entries). Pre-allocate ordered insertion blocks per detector ID to avoid implementer collisions. Module B integrator can serialize the merge of these two files manually if conflict arises.

- **Forward-port risk**: Module B's wall-failure backfill of the existing `2026-06-05-pr1018-icarus-cross-host-logout.md` entry is the ONLY edit to an existing wall-failure entry. This is in-scope per Module B's acceptance criteria but conflicts with Module A's "DO NOT retrofit existing entries" out-of-scope clause. Reconcile: A's clause means "Module A does not retrofit"; Module B explicitly DOES retrofit its OWN entry. No actual contract conflict, but the orchestrator should note this for Phase 4.5 contract reconciliation.
