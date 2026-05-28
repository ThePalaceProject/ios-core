---
name: swarm_66819d80-plan
type: immutable
status: active
created: 2026-05-27
last_refresh: 2026-05-28
freshness_window: never
owners: [auth]
description: "Plan — swarm_66819d80: 3.2.0 auth architecture remediation (classifier + coordinator + isBrowserBased)"
---

# Plan — swarm_66819d80: 3.2.0 auth architecture remediation (classifier + coordinator + isBrowserBased)

**Architect:** Maurice Carrier (this session)  •  **Base:** `origin/develop` @ `d7f115adeb69032fb3abed33ba07b3deeb245f4b`  •  **Branch:** `swarm/swarm_66819d80-scaffold`

---

## Goal

Make the next regression class structurally impossible rather than
individually patchable. SAML auth required fixes in every release
2.0.4–2.2.2. 3.0.0 added a new failure pattern: per-call-site
401/403 handling. Every network consumer (audiobook open #910,
BookReturnService #930, token sign-in #931/#935, push registration
#909, audiobook 403 #933) hits the same logic in subtle variations
and patches in isolation.

This swarm delivers the **single seam** that future call sites can
ONLY hit: `AuthErrorClassifier` (input-driven outcome typing) +
`AuthCoordinator` (output-driven re-auth dispatch). Plus the
`isBrowserBased` predicate that retires 6 scattered duplications. Plus
the telemetry instrumentation that makes the next regression's
signature obvious from the Crashlytics dashboard.

Per `palace-3.2.0-auth-architecture.md` Phases 1, 2, 4, 5 condensed
into a 4-module swarm. Phase 3 (trunk move) and Phase 6 (SAML
internals from calm-knitting-thunder) are explicit NON-GOALS for this
swarm — they ship in follow-up sessions.

---

## Modules

### Module A — `PalaceAuth: AuthErrorClassifier + AuthCoordinator`

Add the two new public types in PalaceAuth that become the only seam
every network consumer + every re-auth caller will hit. Extends (not
duplicates) the existing `URLResponse+TPPAuthentication` classifier
boolean into a typed `AuthOutcome`. Adds the `AuthCoordinator` actor
that owns IdP dispatch.

**Contract:** `.forgeos/swarms/swarm_66819d80/contracts/A-PalaceAuth.md`

**Depends on:** none. Runs Day 1 parallel with Module B.

**Files in scope:** Palace/Packages/PalaceAuth/ only.

**Acceptance:** 50 new tests green; 33 existing
URLResponseAuthenticationTests preserved; classifier mutation 100%
kill; coordinator ≥80%.

### Module B — `AccountDetails.Authentication.isBrowserBased`

Add a single computed property; substitute at 6 valid sites; leave 4
false-positive sites untouched (recon § Section 4 documents which is
which). Includes a behavior-broadening at 3 sites (SAML+OIDC →
SAML+OIDC+OAuth) — explicitly tested.

**Contract:** `.forgeos/swarms/swarm_66819d80/contracts/B-isBrowserBased.md`

**Depends on:** none. Runs Day 1 parallel with Module A.

**Files in scope:** Palace/Packages/PalaceCatalog/Sources/PalaceCatalog/Accounts/AccountDetails.swift + 4 production sites + 2 new test files.

**Acceptance:** 7 truth-table tests + 2 broadening tests green;
grep verifies the 4 off-limits sites untouched; mutation 100% kill
on the property line.

### Module C — Caller migration through `AuthCoordinator`

Wire 7 network consumers + 7 modal-presentation sites through
`AuthCoordinator`. Highest-risk module — touches the critical-path
borrow/return/download/audiobook code. Sign-out, DRM activation,
sign-in success paths are explicitly OFF-LIMITS.

**Contract:** `.forgeos/swarms/swarm_66819d80/contracts/C-CallerMigration.md`

**Depends on:** Module A must merge first.

**Files in scope:** 7 production files (TPPNetworkResponder,
TokenRefreshInterceptor, DownloadAuthRetryHandler, BorrowOperation,
BookReturnService, AudiobookSessionManager, AppContainer) + 3
conformance extension files + 7 new test files + 1 spy mock.

**Acceptance:** All migrated sites compile + tests green; sign-out
suite (14 tests) untouched; critical-path tests #1–10 green;
mutation ≥50% per file (100% on Download* files); grep verifies no
ad-hoc `markCredentialsStale + trigger*Reauth` patterns remain.

### Module D — Telemetry + simdrive fixture gap report

Instrument every auth decision with structured Crashlytics non-fatal
`(idp_type, library_uuid, status_code, problem_doc_type, decision)` —
mirrors PR #933 playback-failure pattern. Plus inventory
`~/.simdrive/recordings/` against the IdP catalog and write a
prioritized gap report for follow-up recording sessions.

**Contract:** `.forgeos/swarms/swarm_66819d80/contracts/D-TelemetryFixtures.md`

**Depends on:** Module A must merge first. Runs Day 2 parallel with
Module C.

**Files in scope:** 2 new main-target Telemetry files + 2 PalaceAuth
recording-protocol additions + AppContainer wire-up + 2 new test
files + 1 spy + 1 gap-report markdown.

**Acceptance:** 9 new tests green; PalaceAuth still doesn't link
FirebaseCrashlytics; gap report exists with prioritized table.

---

## Parallelism plan

```
Day 1 AM  → Module A implementer starts (PalaceAuth, AuthErrorClassifier)
          → Module B implementer starts (AccountDetails.isBrowserBased)
          (parallel — zero file overlap)

Day 1 PM  → Module A: AuthCoordinator + AuthCoordinatorWiringTests
          → Module B: substitutions land + 2 broadening tests
          → Module A PR up for review by EOD
          → Module B PR up for review by EOD

Day 2 AM  → Module A merges (after forge-review)
          → Module B merges (after forge-review)
          → Module C implementer starts (caller migration)
          → Module D implementer starts (telemetry + gap report)
          (Module C + D parallel; both depend on A but not each other)

Day 2 PM  → Module C: all 7 sites migrated + tests green
          → Module D: telemetry wired + gap report written
          → Module C PR up for review
          → Module D PR up for review

Day 2 EOD → verify-pr.sh --quick green
          → forge-review green (architect + qa_test)
          → All 4 module PRs merged
          → Swarm complete; promote release_check
```

Buffer day available if any module overruns.

---

## Risks

### High

1. **Per-call-site behavior drift in Module C.** The migration
   replaces dense decision-tree code with a switch on a typed enum.
   If the enum's mapping from problem-doc types is wrong, every
   consumer regresses simultaneously. Mitigation: Module C MUST run
   all 10 critical-path tests on every commit, and run mutation
   diff-scoped on each file. If a Module-C-introduced test passes but
   a critical-path test fails, the migration is wrong — revert and
   investigate.

2. **Sign-out path accidentally pulled into coordinator.** Multiple
   recon sites (1.15, 2.2.16, the entire `+SignOut` extension) are
   explicit OFF-LIMITS. If Module C's implementer touches sign-out,
   the 14 `TPPIdleSignOutRegressionTests` will fail. Mitigation:
   contract enumerates off-limits; reviewer asserts in
   forge-review.

3. **Mock-coordinator scope creep in Module C.** The `SpyAuthCoordinator`
   helper risks growing to mirror the real coordinator's API, then
   subtly diverging. Mitigation: spy is dumb — records calls + returns
   stubbed result. Behavior assertions live in tests, not spy.

### Medium

4. **OAuth-intermediary broadening (Module B) breaks real users.**
   Sites 4.5/4.6/4.10 currently use `(isSaml || isOidc)`; substitution
   broadens to include OAuth-intermediary. Per the architectural
   intent (Clever IS browser-based), this is correct, but it's a
   user-visible behavior change. Mitigation: 2 new tests
   (BorrowOperationCleverReauthTests) pin the change; architect
   review must explicitly affirm the broadening is intended.

5. **`AuthErrorClassifier` duplicates instead of extends.** Module A
   contract says extend; if the implementer creates a parallel
   classifier, the 33 existing URLResponseAuthenticationTests will
   pass but real callers will be inconsistent. Mitigation: contract
   spells out the delegation pattern; mutation test exposes
   inconsistencies; forge-review verifies via code reading.

### Low

6. **Telemetry over-emission (Module D).** If the recorder is called
   per-network-request instead of per-decision, Crashlytics non-fatal
   quota fills fast. Mitigation: emission contract enumerates
   exactly 6 surface points; tests assert event count per scenario.

7. **simdrive recording gap report under-prioritizes.** The 11
   `UNKNOWN` rows in the IdP catalog represent 6 IdPs × multiple
   scenarios. If Module D's gap report doesn't surface the HIGH
   priority ones (Token silent refresh, SAML cookie expiry mid-borrow,
   Clever sign-in, Cornell), the next session optimizes the wrong
   recordings. Mitigation: gap report cross-references HelpSpot ticket
   IDs explicitly.

---

## Acceptance criteria (whole swarm)

After all 4 modules merge:

- ✅ `AuthErrorClassifier.classify(response:, problemDocument:, body:, originalRequestURL:) -> AuthOutcome` exists in PalaceAuth, mutation 100%.
- ✅ `AuthCoordinator.refreshCredentialsIfNeeded(reason:) async -> Result<Void, AuthRefreshCancellation>` exists in PalaceAuth.
- ✅ `AccountDetails.Authentication.isBrowserBased: Bool` exists.
- ✅ Zero ad-hoc 401/403 handling in Palace/MyBooks/ outside `+SignOut` and inside coordinator. Verified by grep.
- ✅ Every auth decision emits an `AuthDecisionEvent` to Crashlytics.
- ✅ Fixture gap report written and prioritized.
- ✅ 50 + 9 + 9 + ~28 = **~96 new tests** green; all existing 385+
  auth-touching tests green.
- ✅ `scripts/verify-pr.sh --quick` green.
- ✅ `forge_release_check` returns `can_release: true` for the
  swarm bundle.
- ✅ Mutation gate green per CLAUDE.md rules.

---

## Timing target

- **Day 1 EOD:** Modules A + B PR-ready (contracts implemented, tests green, mutation green).
- **Day 2 noon:** Module C PR-ready.
- **Day 2 EOD:** Module D PR-ready + verify-pr/forge-review all green.
- **Day 3:** buffer (rebases, merge order, integration smoke).

Total: 2 working days for implementation; 1 day buffer.

---

## Non-goals (deferred to follow-up swarms or sessions)

1. **Trunk move into PalaceAuth.** Phase 3 of parent plan. Out of
   scope per task brief; recon doc `docs/3.2.0-auth-deps.md` documents
   it for the next session.
2. **SAML internals from calm-knitting-thunder.** Phase 6 of parent
   plan. The classifier + coordinator surface needs to exist BEFORE
   SAML internals refactor; this swarm provides that surface.
3. **`TPPUserAccountWriting` / `TPPUserAccountReading` full split.**
   This swarm declares only the slice the coordinator needs (~5
   methods). Full ~17-method split is trunk-move scope.
4. **Recording new simdrive flows.** Module D writes a gap report;
   the recording session itself is a separate operator session.
5. **Crashlytics dashboard tuning.** Module D emits the events;
   filtering/tagging configuration is post-merge ops work.
6. **Strategy pattern across auth types.** Explicitly rejected in
   `calm-knitting-thunder.md`; the classifier + coordinator solve
   the cross-cutting concern without it.

---

## Reviewer matrix (forge-review)

- **Module A:** architect + qa_test
- **Module B:** architect + qa_test (qa_test verifies OAuth-intermediary broadening)
- **Module C:** architect + qa_test (qa_test runs critical-path test list locally + 1 simdrive replay)
- **Module D:** architect + qa_test (qa_test verifies gap report against IdP catalog)

---

## Self-block triggers

If any of these surface during implementation, STOP and escalate:

1. A 401 site exists in production that wasn't enumerated in recon
   (out of scope but currently un-migrated).
2. CM contract drift detected via `cm_status` (auth-related field
   appeared/disappeared since 2026-05-04).
3. Mutation kill rate cannot reach the threshold even with new tests
   — indicates the classifier abstraction is wrong.
4. An ObjC-side caller still uses
   `indicatesAuthenticationNeedsRefresh:` directly after Module C
   migration (would mean the migration is incomplete and ObjC code
   bypasses the coordinator).

The orchestrator's `BLOCKED.md` mechanism handles these; do not paper
over.
