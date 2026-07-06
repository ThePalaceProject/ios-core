# Architect Review — fix/useraccount-mock-lock

**Verdict: APPROVED**

Reviewer: independent architect (ForgeOS gates OFF — file-only verdict, no MCP submission)
Base: origin/develop  •  Commits: 2 (TPPUserAccountMock locking + intent-gate R9 message)
Scope: PalaceTests/Mocks/TPPUserAccountMock.swift (+225/-84), scripts/check-intent-recorded.py
(message-only), new pytest, wall-entry note. No production code.

## Scrutiny findings

1. **Lock-ordering (one-directional, no inversion) — PASS.** Confirmed in
   Palace/Accounts/User/TPPUserAccount.swift: `controlLock` (lines 67–114,
   incrementSignInGeneration 97–101) is a *leaf* lock used ONLY by the three
   control accessors (notifyAccountChange, signInGeneration, sessionIdentifier)
   and the increment helper — none call an overridable member (credentials /
   authState / hasCredentials). Production `atomicUpdate` (625) and `removeAll`
   (639) are both OVERRIDDEN by the mock, so their controlLock-adjacent seams
   never run on the mock. The mock never holds `mockLock` while touching a
   controlLock member: `removeAll()` releases mockLock, then sets
   `signInGeneration = 0` sequentially (not nested). No path produces
   mockLock→controlLock and controlLock→mockLock simultaneously. Inversion is
   structurally impossible.

2. **Re-entrancy eliminated — PASS.** authState, markCredentialsStale, and
   credentialSnapshot now derive from `UserAccountAuthHelper.hasCredentials(_:)`
   on single-acquisition locked snapshots instead of `self.hasCredentials()`
   (which routes through the overridden `credentials` getter → mockLock, a
   deadlock/re-entry). Verified the helper (UserAccountAuthState.swift:77–79) is
   pure — enum switch only, no locking, no overridable calls. markCredentialsStale
   replicates production's derive-then-guard semantics atomically under one lock;
   behavior is preserved.

3. **Source compatibility — PASS.** `_credentials` / `_authDefinition` remain
   public `var` computed properties (get+set, same types), now backed by
   `__`-prefixed storage under mockLock. ~40 test call sites across
   PalaceTests set/get these directly; all remain valid (settable var contract
   unchanged). Direct `_credentials` writes land in `__credentials`, which the
   overridden `credentials` getter reads — consistent.

4. **atomicUpdate weaker atomicity — PASS (documented, unused).** Block runs
   outside mockLock (required — setters re-lock individually; holding across
   would self-deadlock). Weaker than production's whole-block barrier, but grep
   shows NO external test references atomicUpdateCallCount / atomicUpdateLibraryUUIDs
   or relies on cross-field atomicity — the only references are inside the mock.
   Acceptable and clearly documented in the class doc.

5. **R9 script change — PASS (no behavioral drift).** `_near_miss_score` is a
   new pure helper used ONLY in the already-failing INTENT-MISSING branch;
   `_has_consecutive_token_match` (the matcher) is untouched. New 3-case pytest
   pins exit 0 on match-path-unchanged, exit 1 on near-miss, and count-only
   candidate dump — ran green locally (3 passed).

## Minor (non-blocking) observations
- `removeAllCallCount`'s computed `private(set)` setter is now effectively dead
  (removeAll increments `_removeAllCallCount` directly under lock); the getter is
  the live surface. Harmless.

## Verification posture
Tests-only change; guard is the check-unsynchronized-sendable-mock.py detector
(re-covers this mock with the deferral marker removed) plus the author's
10-iteration soak of the mock-heavy classes (TEST SUCCEEDED, 0 failures). No
production code, so no mutation gate applies. Appropriate for a mock hardening.

Clean, faithful application of the approved TPPBookRegistryMock recipe to the
harder subclass case. No concern/fail findings.
