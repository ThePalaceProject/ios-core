# QA Review — fix/useraccount-mock-lock

**Verdict: APPROVED**
Reviewer role: qa_test (independent). ForgeOS gates OFF — verdict recorded here, not via forge_submit_review.
Base: origin/develop  •  HEAD: 33af610c2, f9e56cd84
Files: PalaceTests/Mocks/TPPUserAccountMock.swift, scripts/check-intent-recorded.py,
scripts/tests/test_check_intent_recorded_nearmiss.py, .forgeos/wall-failures/2026-07-05-sync-mock-race.md

## Summary
A lock retrofit of TPPUserAccountMock (segv-class race follow-up to the 2026-07-05 wall entry)
plus an R9 tooling change to the intent-gate near-miss message. Behavioral semantics for the
40+/68 consuming test files are preserved (verified mechanically); concurrency safety is
strengthened; the R9 message change is safe and non-regressing. One warning on R9 pytest
coverage breadth. No concern/fail findings → APPROVED.

## Findings

### 1. Behavioral compatibility — PASS (coverage)
Verified equivalence against origin/develop and production TPPUserAccount:
- **authState derivation preserved.** New `UserAccountAuthHelper.hasCredentials(creds)` on a
  locked snapshot is EXACTLY what old `hasCredentials()` computed — production TPPUserAccount.swift:343
  is literally `UserAccountAuthHelper.hasCredentials(credentials)`. loggedOut+credentials → loggedIn
  semantics identical, now torn-read-free (single lock acquisition, snapshot then pure helper).
- **markCredentialsStale guard identical.** New derive-under-lock (mock:216-222) replicates old
  `guard authState == .loggedIn` including the derived-loggedIn case; now TOCTOU-safe vs concurrent
  markLoggedIn/setAuthToken (strictly stronger, same observable outcome).
- **setAuthToken atomic.** token + credentials(.token) + .loggedIn all set under one lock (mock:184-191),
  uses raw `__credentials`. Preserved; old was unlocked.
- **removeAll clears everything it used to.** git show origin/develop confirms the old removeAll already
  set signInGeneration=0; new keeps the identical field set + `_removeAllCallCount += 1` under lock, with
  signInGeneration=0 moved OUTSIDE mockLock (correct — production setter takes controlLock; avoids inversion).
- **credentialSnapshot** now reads a consistent (creds,state,authDef) snapshot under one lock; authDefinition
  sourced from that snapshot instead of the locked getter — equivalent, torn-read-free.
- **Re-entrancy audit clean:** every in-lock access uses raw `__credentials`/`__authDefinition`
  (mock:186,201,218,234,335,337); the locked `_credentials`/`_authDefinition` wrappers are only touched by
  the non-locked override accessors. NSLock is non-recursive — no self-deadlock path exists.

### 2. Concurrency evidence — PASS (coverage)
TPPCredentialConcurrencyTests (TPPCredentialVisibilityTests.swift:693+) drives credentialSnapshot ×100
concurrent AND refreshCredentialsFromKeychain ×50 concurrent. That covers both the segv-class torn-read
path and the accountInfoQueue(barrier)→mockLock cross-lock nesting (refresh→hasCredentials()→overridden
credentials getter→mockLock). Lock order is one-directional (accountInfoQueue→mockLock; controlLock only
outside mockLock) — no inversion. Because every public member now locks exactly once with no re-entrancy,
all 68 consumers are safe by construction; the soak proves no deadlock/regression on the heaviest path.
The other detector-flagged files (AccountsManagerStateMachineWiringTests, TPPAnnotationsTests,
PalaceTestSetup) do not need separate soaks — correctness is structural, not soak-dependent.
Detector `check-unsynchronized-sendable-mock.py` now reports this mock CLEAN (deferral marker removed);
only 3 pre-existing latent notes remain.

### 3. resetShared ordering — PASS (regression)
New order (fresh instance published under sharedLock, then removeAll on the captured local ref) is STRONGER
than old: shared assignment is now atomic and removeAll runs on the local ref (no TOCTOU on a second shared
read). The window where `shared` points at fresh-but-not-yet-removeAll'd is benign — a fresh instance is
already nil-fields/.loggedOut; removeAll on it only bumps the call count. Concurrent readers see loggedOut
either way. No weaker-than-old window introduced.

### 4. R9 near-miss pytest — WARNING (coverage)
The 3 cases pin the fail path (near-miss named + rule), the suppression path (no overlap → count-only,
no near-miss block), and the match path (rc=0). Together they bracket the matcher: test 3 catches
under-matching, tests 1&2 catch over-matching; the `s > 0` guard mutant is killed by test 2. Verified:
`pytest ...nearmiss.py` 3/3 green; legacy `test_check_intent_recorded.py` still PASS (R9 count-only message
change did not regress the INTENT-MISSING assertion).
GAP: the fixture uses a SINGLE intent file, so the actual R9 value — ranking the closest of MANY candidates
and the `scored[:3]` top-3 selection/sort — is never exercised with >1 candidate. A regression in the sort
key or the top-3 slice among multiple candidates would NOT be caught. Recommend adding a multi-candidate
case asserting the closest name ranks first. Non-blocking (message-only tooling, not product code).

## Mechanical checks run
- git show origin/develop:removeAll vs HEAD — field set + signInGeneration=0 identical
- production TPPUserAccount.swift:343 / UserAccountAuthState.swift:77 — hasCredentials equivalence confirmed
- grep re-entrancy audit of _/__ credentials access — all in-lock uses raw form
- pytest test_check_intent_recorded_nearmiss.py — 3 passed
- python3 scripts/test_check_intent_recorded.py — PASS (no R9 regression)
- check-unsynchronized-sendable-mock.py — mock no longer flagged
