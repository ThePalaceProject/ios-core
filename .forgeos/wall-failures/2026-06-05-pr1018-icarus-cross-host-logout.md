---
date: 2026-06-05
pr: "#1018"
source: shipped-bug
reviewer_ids: []
changeset_id: cs_TBD-on-promote
wall: contract
walls: [contract, TDD, reviewer, stale-doc]
severity: critical
wall_status: proposed
applied_in: ""
contributing_docs:
  - path: docs/architecture/areas/auth/verification-checklist.md
    last_refresh_at_failure: 2026-05-28
    decay_days: 8
  - path: docs/architecture/areas/network/verification-checklist.md
    last_refresh_at_failure: 2026-05-28
    decay_days: 8
# doc-lifecycle metadata
name: 2026-06-05-pr1018-icarus-cross-host-logout
type: evolving
status: active
created: 2026-06-05
last_refresh: 2026-06-05
freshness_window: 365d
owners: [auth, network]
description: Cross-host 401 from a foreign library's host mis-attributed to the current OIDC/SAML account — repeated sign-in modal driven by background A1QA audiobook playtimes upload while active account is Icarus.
---

# PR #1018 Icarus cross-host logout — auth-error classification missing current-account host scoping

## Finding (verbatim from bug report / handoff)

> Symptom: On device "Moes Max" (iPhone 17 Pro Max, iOS, signed into Icarus Test Library OIDC), the app repeatedly logs out / pops the sign-in modal — once per minute, indefinitely.
>
> Root cause: every minute, the audiobook playtimes tracker uploads listening time for an audiobook that was borrowed under A1QA:
> ```
> POST https://gorgon.staging.palaceproject.io/a1qa-test/playtimes/14/URI/urn:uuid:...
>      body: { libraryId: urn:uuid:965eb2f9... (A1QA), timeEntries: [...] }
> → 401 "Error uploading audiobook tracker data" (Code 902, problem doc)
> ```
> …but the active account is Icarus (`currentAccountAuthDocURL = https://minotaur.dev.palaceproject.io/icarus-test-library/authentication_document`, a different host, `minotaur.dev` ≠ `gorgon.staging`).
>
> `TPPNetworkResponder` handles that 401, `AuthErrorClassifier` does NOT short-circuit it (it's same-host gorgon→gorgon, so the existing redirect-based cross-domain guard doesn't fire), the account is browser-auth (OIDC) and the path isn't `/patrons/me`, so it dispatches:
>
> ```
> TPPNetworkResponder: Server returned 401 for browser-based auth on action endpoint
>   — dispatching coordinator with reason=oidcRefreshFailed (was: inline markCredentialsStale)
> → AuthCoordinator.refreshCredentialsIfNeeded(reason: .oidcRefreshFailed)
> → routes to .modal → presents the sign-in modal for the CURRENT (Icarus) account
> ```
>
> So a cross-library / cross-host 401 is misattributed to the current account's OIDC session, and now (post-#1018) it actively drives a reauth modal — every minute.

Source: `.forgeos/handoffs/2026-06-05-icarus-cross-host-logout-regression.md` § 1–2. Regression commit: `f380e37c3` (PR #1018, swarm_66819d80).

## What actually happened

Two compounding bugs, only one of which PR #1018 introduced:

**Bug A (latent mis-attribution, OLD — pre-#1018).** `AuthErrorClassifier.classify(...)` and the two sibling sites that bypass it (`TokenRefreshInterceptor:106`, `DownloadAuthRetryHandler:212`) use `URLResponse.isSameDomain(as:)` for their cross-domain guard. That helper compares BASE DOMAINS (last two host components — e.g. `palaceproject.io`). `gorgon.staging.palaceproject.io` and `minotaur.dev.palaceproject.io` share base domain `palaceproject.io`, so the guard treats them as same-domain. A 401 from a *different library backend host* but the *same Palace base domain* is therefore mis-classified as "ours" (the current account's). This has been latent for as long as the base-domain helper has existed.

**Bug B (visible regression — INTRODUCED by PR #1018).** Before PR #1018, the browser-auth-on-action-endpoint 401 branch of `TPPNetworkResponder.handleExpiredTokenIfNeeded(...)` looked like:

```swift
// 3.1.0 (TPPNetworkResponder.swift ~line 459)
accountsManager.userAccount(for: accountId ?? "").markCredentialsStale()
Log.info("... credentials marked stale; user-action paths will surface re-auth on next interaction")
return false
```

This was **passive** — the 401 set a flag; the next real user action (borrow, fulfillment) would surface re-auth, and a `/patrons/me` success could reconcile. A background playtimes upload would set the flag silently. User-invisible.

PR #1018 / swarm_66819d80 rewrote this branch as:

```swift
// post-#1018 (TPPNetworkResponder.swift ~line 510)
let coordinator = AppContainer.production().authCoordinator
let reason: ReauthReason = ... .oidcRefreshFailed ...
Task { _ = await coordinator.refreshCredentialsIfNeeded(reason: reason) }
return false
```

`.oidcRefreshFailed` routes to `.modal` in `AuthCoordinator.recoveryStrategy`. So the background playtimes 401 now ACTIVELY pops a sign-in modal — every minute, for the wrong account.

PR #1018's intent was to unify auth-error dispatch through the new `AuthCoordinator` so all paths get IdP-appropriate routing + single-flight + telemetry. The intent is correct; the side effect on the cross-host case is what shipped. The classifier and the responder both lacked any consideration of "is this 401's host even our current account's surface?"

## Walls that should have caught it (and why they didn't)

- **contract** — PR #1018's swarm contract (`swarm_66819d80`, Module C TPPNetworkResponder migration) specified the migration shape — route the 401 through `AuthErrorClassifier`, dispatch via `AuthCoordinator`. It did NOT specify a host-scoping invariant. The cross-domain carve-out was preserved by copy-paste of the base-domain `isSameDomain` predicate; no contract clause asked "does this 401's host belong to the current account's auth surface?" Without that clause, the implementer had no reason to add the check.

- **TDD** — PR #1018's `AuthErrorClassifierPropertyTests` and `AuthErrorClassifierTests` exercise cross-domain via REDIRECT (different base domains: gorgon / cdn / biblioboard / icarus, comparing `response.url.host` vs `originalRequest.url.host`). They never test the **same-base-domain-but-different-account-host** case (e.g. `gorgon/<other-library>/playtimes` 401 while account = `minotaur/<this-library>`). The 11-cell IdP × scenario table in `docs/architecture/areas/auth/verification-checklist.md` § 4 enumerates per-IdP scenarios; it does not enumerate per-host or cross-account scenarios.

  Also: no test pinned the BEHAVIORAL CHANGE passive → active. The migration tests assert that the coordinator is dispatched with the right `reason`; they do not assert that the coordinator is NOT dispatched when the 401 is foreign-host. Without a negative-case test, the activation became invisible to the test suite.

- **reviewer** — Both the architect and qa_test reviewers on PR #1018 (per the `swarm_66819d80` review trail in `.forgeos/wall-failures/2026-05-27-pr1018-*.md`) verified the migration shape, the dispatch matrix, the single-flight semantics, and the test count growth. Neither asked "what host is this 401 from?" because the original `TPPNetworkResponder` 401 branch never asked that either — the change preserved existing semantics with respect to host scoping (which was wrong, just newly visible).

  The reviewer prompts under `~/harness/agents/forge-*-reviewer/` enumerate dispatch-matrix coverage and IdP catalog completeness; they do not enumerate cross-account / cross-host scenarios. The reviewers had no checklist item that would have flagged this.

- **stale-doc** — Auth + network verification checklists were last refreshed 2026-05-28 (8 days before this finding). They both document Bug B's net result accurately: the network checklist § 5 emits `Log.info — "Server returned 401 for browser-based auth on action endpoint — credentials marked stale"` as the post-migration telemetry signal — confirming the migration's intent. **Neither checklist mentions the cross-account / cross-host scenario** as a known trap. The "Known traps" sections (auth § 7, network § 7) call out the two-surface auth model, redirect-based cross-domain, and `/patrons/me` — but not foreign-library hosts. A reviewer or implementer reading the checklist would not be primed to ask the host-scoping question.

  Decay is short (8 days), but the omission is structural: the checklists describe what PR #1018 did, not what it MISSED. The wall-failure entry below proposes adding the trap explicitly.

## Proposed permanent fix

**Code fix (this PR):** add a `currentAccountHostsProvider: @Sendable () -> Set<String>?` to `AuthErrorClassifier` and a new Rule 4b in `classifyCore`: when the provider returns a non-empty set AND the 401's original-request host is NOT in that set, return `.ok`. Add an equivalent host-scope guard to the two legacy sibling sites (`TokenRefreshInterceptor:106`, `DownloadAuthRetryHandler:212`). Add `Account.authSurfaceHosts: Set<String>` to expose the data. Full plan at `.forgeos/changesets/fix-icarus-cross-host-logout/fix-contract.md`. Tracked in PP-4436 (3.2.0 regression pass — no dedicated ticket per user 2026-06-05).

**Structural prevention (the actual wall-failure work — makes this class of finding impossible to recur):**

1. **CLAUDE.md clause under "Risk-driven rigor bar":**
   > **"Any 401/credentials-stale decision must be scoped to the current account's auth-surface host; a 401 from a non-account host is never an account session expiry. Reviewers BLOCK any auth-error decision path that does not provably consult a current-account host set."**

2. **Auth verification checklist (§ 7 Known traps) — add a clause:**
   > **"Foreign-library cross-host 401. A 401 from a host that shares base-domain with the current account but DOES NOT belong to the current account's auth surface (different library backend within `*.palaceproject.io`) must NOT be classified as `.reauthRequired`. The base-domain `isSameDomain` helper does NOT catch this — host-equality scoping via `Account.authSurfaceHosts` does. See PR for PP-4436 (3.2.0 regression pass — no dedicated ticket per user 2026-06-05) + wall-failure 2026-06-05-pr1018-icarus-cross-host-logout."**

3. **Network verification checklist (§ 7 Known traps) — pair with auth:**
   > **"When routing a 401 through `AuthErrorClassifier`, the classifier MUST be constructed with a non-nil `currentAccountHostsProvider` in production. The default `{ nil }` provider is a TEST CONVENIENCE; a production call site that omits it is shipping the latent foreign-host mis-attribution bug."**

4. **Auth verification checklist (§ 4 IdP × scenario truth table) — add a NEW column "Foreign-host 401":**
   > The expected outcome for every IdP × foreign-host-401 cell is `.ok` (not a reauth). Property-fuzz Invariant 8 in `AuthErrorClassifierPropertyTests` enforces this; the truth-table column makes the invariant discoverable from the checklist.

5. **Property-fuzz invariant pin (cannot regress without a fuzz failure):**
   > Invariant 8 in `AuthErrorClassifierPropertyTests`: when `currentAccountHostsProvider` returns a non-empty set AND status == 401 AND original-request host is NOT in that set, outcome MUST be `.ok`. 200 trials split 50/50 in-set vs foreign. Any future regression that silently drops the foreign-host check fails the fuzz.

6. **forge-architect-reviewer prompt enhancement** at `~/harness/agents/forge-architect-reviewer.md` (or equivalent): add to the "Architectural smells to flag" list:
   > **"Cross-account / cross-host scoping. If the review touches an auth-error decision path (`AuthErrorClassifier`, any `indicatesAuthenticationNeedsRefresh` caller, `TPPNetworkResponder.handleExpiredTokenIfNeeded`, `TokenRefreshInterceptor`, `DownloadAuthRetryHandler`, `BorrowOperation` auth branches, `BookReturnService` auth branches), verify the decision is HOST-scoped to the current account's auth surface. Base-domain matching alone is insufficient when multiple library backends share a base domain (true for `*.palaceproject.io`). Wall-failure reference: `2026-06-05-pr1018-icarus-cross-host-logout.md`."**

The class is closed when:
- (a) the foreign-host guard exists at all auth-error decision sites (this PR's diff covers 3 sites; classifier-migration of the legacy 2 sites is deferred to a separate refactor but the foreign-host guard lands at all 3 now),
- (b) the property-fuzz invariant is in place,
- (c) the CLAUDE.md clause + checklist traps + architect-prompt amendment land in the same PR (so the next architect review CANNOT miss the question).

## Stale-doc contribution

- **Doc path:** `docs/architecture/areas/auth/verification-checklist.md`
  **Last refresh before failure:** 2026-05-28
  **Decay at failure:** 8 days
  **What the doc said vs reality:** Section 4 (IdP × scenario truth table) enumerates per-IdP scenarios but has no foreign-host column. Section 7 (Known traps) covers the two-surface auth model, redirect-based cross-domain, the per-book circuit breaker, per-task token-refresh budget, SAML cookie sync, and the `.accountNotFound` conflation — but says nothing about cross-account / cross-host scoping. A reader of the checklist would not be primed to ask whether a 401 belongs to the current account's host. The doc accurately describes what PR #1018 did; it does not describe what PR #1018 MISSED.
  **Freshness-window implication:** the 180d freshness window is too long for a doc that codifies "Known traps" — adding a trap should be possible AT THE TIME the trap is discovered, not at the next sweep. Proposed: keep the 180d freshness window for routine refresh, but require a `last_trap_update` field; an entry to § 7 bumps THAT field independently. Tracks "this checklist's trap-catalog is current as of <date>" separately from "this checklist's call-site map is current as of <date>." Tracked as a follow-up to this wall-failure.

- **Doc path:** `docs/architecture/areas/network/verification-checklist.md`
  **Last refresh before failure:** 2026-05-28
  **Decay at failure:** 8 days
  **What the doc said vs reality:** Section 4 (Decision boundary) calls out cross-domain detection as a responder-owned concern, but the "cross-domain" terminology means BASE-DOMAIN matching throughout the file. Section 7 mentions "Do NOT route cross-domain 401 through the coordinator" — which is good guidance for biblioboard / cdn cross-domain, but doesn't extend to the foreign-library cross-host scenario where base-domain matching incorrectly returns "same domain." A reader could conclude (correctly!) that the network layer routes the 401 through the classifier — and (incorrectly!) assume the classifier handles host scoping.
  **Freshness-window implication:** same as auth-area. The trap belongs in § 7; the decay is short but the omission is structural.

## Application log

- 2026-06-05 — wall-failure entry created from `.forgeos/handoffs/2026-06-05-icarus-cross-host-logout-regression.md`. Fix proposed at `.forgeos/changesets/fix-icarus-cross-host-logout/fix-contract.md`. Jira: PP-4436 (3.2.0 regression pass — no dedicated ticket per user 2026-06-05).
- 2026-06-05 — architect post-review verdict APPROVED-WITH-CHANGES; changes applied to fix-contract (sibling-site scope expansion, mutation threshold to 100%, Rule 4 + Rule 4b ordering test, property-fuzz 50/50 split, count corrected 4→5). Trail in fix-contract.md § 9.
- TBD — fix landed in `<commit-SHA>` (PR #TBD). Update `applied_in:` frontmatter.
- TBD — next swarm review of an auth-error decision path: confirm the architect-reviewer prompt enforces the host-scoping question per Proposed Fix item 6.
- TBD — observation pass: did Wall-failure class recur in next ≥3 auth-touching PRs?

## Related entries

- `.forgeos/wall-failures/2026-05-27-pr1018-arch1.md` — sibling PR #1018 architect finding (different gap class).
- `.forgeos/wall-failures/2026-05-27-pr1018-arch2.md`, `arch3.md`, `qa1.md`, `qa2.md`, `qa3.md` — all PR #1018 reviewer-block findings, all about the auth-architecture migration's coverage gaps. This entry is the FIRST PR #1018 finding sourced from a SHIPPED-BUG (post-merge regression) rather than a pre-merge reviewer block — meaning the PR #1018 walls DID catch six gap classes during review, but missed this seventh class entirely.
- `.forgeos/wall-failures/2026-05-28-cs847892e8-arch1.md` — fake-wiring-test pattern. Related theme: tests pin a destination state without proving the production path reaches it (PR #1018's classifier tests pinned the cross-domain `.ok` for redirect-based cross-domain but never exercised the foreign-host-within-same-base-domain path).
- `.forgeos/wall-failures/2026-05-28-cs9a267b63-arch1.md` — same fake-wiring-test class; CLAUDE.md state-machine rule and `scripts/check-test-name-vs-body.py` added as the structural fix. The foreign-host fuzz invariant 8 here is the analogous structural fix for auth-error classification.
- Memory entry: `saml_two_surface_auth_model.md` — adjacent: bearer + IdP cookie expire independently. Worth cross-linking from the auth-area checklist trap once the new "cross-account host scoping" trap lands.
- Memory entry: `enum_conflation_account_not_found.md` — adjacent: `.accountNotFound` overload (real-failure vs eviction-marker). Different class but same theme — auth state machine carries hidden ambiguity that surfaces months later.
