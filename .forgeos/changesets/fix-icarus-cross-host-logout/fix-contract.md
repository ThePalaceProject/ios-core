# Fix-contract — Icarus cross-host logout regression (auth-error host scoping)

**Branch:** `fix/icarus-cross-host-logout`
**Author:** Claude (Opus 4.7 1M) for Maurice Carrier
**Created:** 2026-06-05
**Handoff:** `.forgeos/handoffs/2026-06-05-icarus-cross-host-logout-regression.md`
**Wall-failure entry (to be created):** `.forgeos/wall-failures/2026-06-05-pr1018-icarus-cross-host-logout.md`
**Regression commit:** `f380e37c3` (PR #1018, swarm_66819d80)

---

## 1. Problem (one paragraph)

On device, an Icarus (`minotaur.dev.palaceproject.io`) OIDC account is signed in. A previously borrowed A1QA audiobook (`gorgon.staging.palaceproject.io`) is still active in the audiobook session manager; its playtimes tracker uploads listening time every minute. Each upload returns 401 (the A1QA session is no longer authoritative). `AuthErrorClassifier.classify(...)` reaches the 401 branch — the existing cross-domain guard (`!response.isSameDomain(as: originalRequestURL)`) is **base-domain** scoped, and both hosts share `palaceproject.io`, so the cross-domain guard does NOT fire. The classifier returns `.reauthRequired(reason: .unknown401)`. `TPPNetworkResponder.handleExpiredTokenIfNeeded(...)` reads the current (Icarus) account's `authDef`, sees `.browser` + OIDC, and dispatches `AuthCoordinator.refreshCredentialsIfNeeded(reason: .oidcRefreshFailed)`. The coordinator's `recoveryStrategy` maps `.oidcRefreshFailed` → `.modal` → a sign-in modal for the wrong account, every minute.

The root mis-attribution is OLD (since well before PR #1018). PR #1018 turned a passive `markCredentialsStale` into an active coordinator dispatch — *making* the mis-attribution visible.

---

## 2. Scope (in)

**Architect-review v1 (2026-06-05) chose Option B** — expand scope to also close the bug class at the two unmigrated sibling sites (`TokenRefreshInterceptor.swift:106`, `DownloadAuthRetryHandler.swift:212`). Both call legacy `indicatesAuthenticationNeedsRefresh(with:originalRequestURL:)` and dispatch the same `AuthCoordinator.refreshCredentialsIfNeeded(...)` modal path that the responder does. Same regression class; closing the wall completely.

| File | Change | Approx LOC |
|------|--------|-----------|
| `Palace/Packages/PalaceAuth/Sources/PalaceAuth/AuthErrorClassifier.swift` | Add `currentAccountHostsProvider: @Sendable () -> Set<String>?` init parameter (default `{ nil }`). Add Rule 4b in `classifyCore` after the existing cross-domain check: 401 + non-nil hosts + non-empty + request host ∉ set → `.ok`. PUBLIC_INTENT annotated. | +15 prod LOC |
| `Palace/Network/TPPNetworkResponder.swift` | Update the `AuthErrorClassifier()` construction at line 465 to pass a closure that reads `AppContainer.production().accountsManager.currentAccount?.authSurfaceHosts`. | +6 prod LOC |
| `Palace/Accounts/Library/Account.swift` | Add `var authSurfaceHosts: Set<String>` computed property — lowercased hosts derived from `authenticationDocumentUrl`, `catalogUrl`, `loansUrl`, `homePageUrl`. Empty set when none available. PUBLIC_INTENT annotated. | +12 prod LOC |
| `Palace/MyBooks/TokenRefreshInterceptor.swift` | **Sibling-site fix.** Before the `indicatesAuthenticationNeedsRefresh == true` branch at line 106 enters its mark-stale + coordinator-dispatch path, add a host-scope guard: if `currentAccount?.authSurfaceHosts` is non-empty AND the response's `originalURL.host` is NOT in the set, log + return without dispatching. Same closure shape as the classifier consumer; reads `AppContainer.production().accountsManager.currentAccount`. | +8 prod LOC |
| `Palace/MyBooks/DownloadAuthRetryHandler.swift` | **Sibling-site fix.** Same shape as above at line 212. | +8 prod LOC |
| `Palace/Packages/PalaceAuth/Tests/PalaceAuthTests/AuthErrorClassifierTests.swift` | Add five new tests: foreign-host 401 → `.ok`; same-host 401 (in set) → `.reauthRequired`; nil provider → legacy; empty-set → legacy; case-insensitive host match. AND a sixth — `testClassify_401_baseDomainCrossOrigin_andForeignHost_returnsOkViaRule4` — to lock the Rule 4 → Rule 4b ordering. | +75 test LOC |
| `Palace/Packages/PalaceAuth/Tests/PalaceAuthTests/AuthErrorClassifierPropertyTests.swift` | Add Invariant 8: when `currentAccountHostsProvider` returns a non-empty set, a 401 from a host outside that set MUST yield `.ok`. Fuzzer wired so ~50% of trials use an in-set host and ~50% use foreign (per Risk Highlight 4 of architect-review v1). | +30 test LOC |
| `PalaceTests/Network/TPPNetworkResponderAuthCoordinatorTests.swift` | Add one integration test driving a real `TPPNetworkResponder` + `URLSession` + `HTTPStubURLProtocol`: with a current account whose `authSurfaceHosts` is `{minotaur.dev.palaceproject.io}`, a 401 to `gorgon.staging.palaceproject.io/...` must NOT mark the URL retried, must NOT dispatch coordinator, AND `handleExpiredTokenIfNeeded` must return `false`. | +40 test LOC |
| `PalaceTests/MyBooks/TokenRefreshInterceptorAuthCoordinatorTests.swift` (extend) | Add one test: foreign-host 401 + current-account hosts set ⇒ no `markCredentialsStale` on current account + no `coordinator.refreshCredentialsIfNeeded` dispatch. Uses existing spy scaffolding in the file. | +30 test LOC |
| `PalaceTests/MyBooks/DownloadAuthRetryHandlerAuthCoordinatorTests.swift` (extend) | Same shape as above. | +30 test LOC |
| `PalaceTests/Accounts/AccountAuthSurfaceHostsTests.swift` (NEW) | Tests for `Account.authSurfaceHosts`: derives hosts from each populated URL; lowercased at producer; handles missing/malformed URLs; returns empty set when all URLs absent. | +50 test LOC |

**Total:** ~49 prod LOC + ~255 test LOC (+ ~16 prod / +75 test vs v1 for the sibling sites + extra ordering test + fuzzer-split).

---

## 3. Scope (out — DO NOT touch)

Named explicitly to prevent silent expansion:

- `Palace/Network/TPPNetworkResponder.swift` lines 482-534 — the 401 branch routing (browser vs. non-browser, `/patrons/me` bypass, `tokenRefreshAttempts` budget). The classifier short-circuit at line 477 (`outcome == .ok` → return false) is the existing seam; the new Rule 4b funnels into that same branch with no responder-side change. Touching the routing past 482 is *out of scope* and would expand blast radius.
- `Palace/Packages/PalaceAuth/Sources/PalaceAuth/AuthCoordinator.swift` — the dispatch matrix + recovery strategy. The fix prevents the dispatch from happening; once the classifier returns `.ok`, the coordinator is never called for this scenario. NO coordinator change.
- `Palace/Packages/PalaceAuth/Sources/PalaceAuth/URLResponse+TPPAuthentication.swift` — the existing `isSameDomain` base-domain helper. The new rule is HOST-EQUALITY, not BASE-DOMAIN. Leave the base-domain helper for the existing cross-domain CDN guard.
- `Palace/Accounts/Library/AccountsManager.swift` — no API change needed; `currentAccount: Account?` is read through the existing public property. The closure in TPPNetworkResponder + sibling sites does `AppContainer.production().accountsManager.currentAccount?.authSurfaceHosts`.
- `Palace/Packages/PalaceAuth/Sources/PalaceAuth/AuthOutcome.swift` — no new enum case. Reuse `.ok` (matches the existing cross-domain CDN carve-out's semantics: "not our account's session").
- **TokenRefreshInterceptor / DownloadAuthRetryHandler migration to AuthErrorClassifier.** Sibling-site fixes here are FOREIGN-HOST GUARDS only, not full classifier-migration. The PR #1018 deferral (network checklist §1) stands; the classifier-migration of these two sites remains a separate refactor.
- **The unrelated playtimes tracker bug (Bug B in the handoff)** — the audiobook playtimes upload should stop or scope on active-account switch. That lives in `PalaceAudiobookToolkit` submodule + the Palace audiobook-session lifecycle. **Tracked in a separate follow-up Jira ticket; out of scope for THIS PR.** This PR fixes the classifier so that, even if the tracker continues firing, the cross-host 401 is correctly classified as foreign and never modal-prompts.

---

## 4. Verification criteria (grep-able assertions)

Run these before declaring done. Each is an exact assertion.

1. **SUT instantiation in new tests** —
   ```bash
   grep -c "AuthErrorClassifier(" Palace/Packages/PalaceAuth/Tests/PalaceAuthTests/AuthErrorClassifierTests.swift
   ```
   ≥ existing count + 4 (one instantiation per new host-scoping test, or shared private fixture used by all four).

2. **Production wiring** —
   ```bash
   grep -n "currentAccountHostsProvider" Palace/Network/TPPNetworkResponder.swift
   ```
   ≥ 1 line — confirms the responder passes a non-nil provider (the whole point).

3. **Closure body reaches AccountsManager** —
   ```bash
   grep -n "accountsManager.currentAccount?.authSurfaceHosts\|authSurfaceHosts" Palace/Network/TPPNetworkResponder.swift
   ```
   ≥ 1 line — confirms the responder calls into the new Account API.

4. **No new 401 branch added in responder** —
   ```bash
   grep -c "statusCode == 40[13]" Palace/Network/TPPNetworkResponder.swift
   ```
   Equal to the pre-existing count (currently **5 lines**: 221, 230, 291, 367, 482 — corrected from "4 lines" per architect-review v1 Check 3). The fix MUST happen inside the classifier; the responder MUST NOT grow another inline auth-classification branch.

5. **Rule 4b is reachable from the public classify entry point** — the new tests in `AuthErrorClassifierTests` must drive `classifier.classify(...)` (not `classifyCore` — private). The TPPNetworkResponder integration test must drive a real responder via `HTTPStubURLProtocol`, not the classifier in isolation. Method-level body check:
   ```bash
   python3 scripts/check-test-name-vs-body.py Palace/Packages/PalaceAuth/Tests/PalaceAuthTests/AuthErrorClassifierTests.swift
   python3 scripts/check-test-name-vs-body.py PalaceTests/Network/TPPNetworkResponderAuthCoordinatorTests.swift
   ```
   Exit 0 required.

6. **Multi-step test bodies match names** — any new test named `*foreignHost*` or `*currentAccountHostsProvider*` must drive the classifier with a foreign-host URL AND assert the outcome equals `.ok`. No half-step. The cross-host integration test (`testResponder_401_foreignHost_*`) must literally configure the host-provider closure to return a host SET that does NOT contain the request host, and must assert at least one observable consequence of the `.ok` short-circuit (no `markRetried`, or `handleExpiredTokenIfNeeded` returns false).

7. **Mutation kill (diff-only) on the touched files** —
   ```bash
   python3 scripts/palace_mutate.py \
     --file Palace/Packages/PalaceAuth/Sources/PalaceAuth/AuthErrorClassifier.swift \
     --tests PalaceAuthTests/AuthErrorClassifierTests \
     --diff-only

   python3 scripts/palace_mutate.py \
     --file Palace/Network/TPPNetworkResponder.swift \
     --tests PalaceTests/TPPNetworkResponderAuthCoordinatorTests \
     --diff-only

   python3 scripts/palace_mutate.py \
     --file Palace/Accounts/Library/Account.swift \
     --tests PalaceTests/AccountAuthSurfaceHostsTests \
     --diff-only

   python3 scripts/palace_mutate.py \
     --file Palace/MyBooks/TokenRefreshInterceptor.swift \
     --tests PalaceTests/TokenRefreshInterceptorAuthCoordinatorTests \
     --diff-only

   python3 scripts/palace_mutate.py \
     --file Palace/MyBooks/DownloadAuthRetryHandler.swift \
     --tests PalaceTests/DownloadAuthRetryHandlerAuthCoordinatorTests \
     --diff-only
   ```
   AuthErrorClassifier: **100%** on diff-only (matches the existing file-level mandate at `AuthErrorClassifierTests.swift:10` — per architect-review v1 Check 3, do not undercut the existing bar).
   Account.swift diff-only: ≥ 80% on the new property.
   Responder diff-only: ≥ 50% (single closure injection; the new rule lives in the classifier).
   TokenRefreshInterceptor / DownloadAuthRetryHandler diff-only: ≥ 80% on the new host-scope guard (small, branchy, easy to kill all mutants).

8. **Contract reconciliation** —
   ```bash
   python3 scripts/check-contract-reconciliation.py --commit-msg /tmp/icarus-commit-msg.txt
   ```
   Exit 0 required.

9. **Blast radius** —
   ```bash
   python3 scripts/check-blast-radius.py --quiet
   ```
   Exit 0 (or all findings annotated with `// PUBLIC_INTENT:` if any new public surface added — the new closure on classifier IS new public surface; annotate with `// PUBLIC_INTENT: enables current-account host scoping to prevent cross-host 401 mis-attribution (PR #1018 regression fix)`).

10. **Adjacency staleness** —
    ```bash
    python3 scripts/check-adjacency-staleness.py --quiet
    ```
    Warn-only; paste output.

11. **Superpartner spectrum (test-pairing)** —
    ```bash
    python3 scripts/check-superpartner-spectrum.py --quiet
    ```
    Exit 0 required for high-severity findings on the changed files.

12. **Build + verify-pr** —
    ```bash
    scripts/verify-pr.sh --quick
    ```
    PASS. Paste tail.

---

## 5. Tests required

### 5.1 Unit (classifier-level) — in `AuthErrorClassifierTests`

- `testClassify_401FromForeignHost_withCurrentAccountHostsProvider_returnsOk`
  - host-set = `{"minotaur.dev.palaceproject.io"}`
  - request URL = `https://gorgon.staging.palaceproject.io/a1qa-test/playtimes/...`
  - assert outcome `== .ok`
- `testClassify_401FromCurrentAccountHost_withCurrentAccountHostsProvider_returnsReauthRequired`
  - host-set = `{"minotaur.dev.palaceproject.io"}`
  - request URL = `https://minotaur.dev.palaceproject.io/icarus-test-library/borrow/...`
  - assert outcome `== .reauthRequired(reason: .unknown401)` (host is in set → no short-circuit; legacy 401 handling)
- `testClassify_401WithNilCurrentAccountHostsProvider_fallsBackToLegacyBehavior`
  - default provider (returns nil)
  - request URL = `https://gorgon.staging.palaceproject.io/...`
  - assert outcome `== .reauthRequired(reason: .unknown401)` (nil → no host scoping)
- `testClassify_401WithEmptyCurrentAccountHostsSet_fallsBackToLegacyBehavior`
  - provider returns empty Set<String>()
  - assert outcome `== .reauthRequired(reason: .unknown401)` (empty → treat as nil, don't false-block)
- `testClassify_401FromCurrentAccountHost_caseInsensitiveMatch`
  - host-set = `{"minotaur.dev.palaceproject.io"}` (lowercase)
  - request URL has uppercase letters in host: `https://Minotaur.Dev.PalaceProject.io/...`
  - assert `.reauthRequired` — confirms case-insensitive matching prevents accidental false-foreign
- `testClassify_401_baseDomainCrossOrigin_andForeignHost_returnsOkViaRule4` (Rule 4 + Rule 4b co-applicability)
  - request to `https://gorgon.staging.palaceproject.io/...` (palaceproject.io base-domain)
  - response from `https://library.biblioboard.com/...` (biblioboard.com base-domain) — TRUE cross-base-domain
  - host-set = `{"minotaur.dev.palaceproject.io"}` (request host also foreign to this set)
  - assert `.ok` — both Rule 4 (base-domain cross-domain) and Rule 4b (foreign host) would yield `.ok`. Rule 4 fires first because it's checked first; the test pins the order and prevents a future refactor from accidentally swapping them.

### 5.2 Property fuzz — extend `AuthErrorClassifierPropertyTests`

- Add Invariant 8: when `currentAccountHostsProvider` returns a non-empty Set<String> AND status == 401 AND original-request host is NOT in that set, outcome MUST be `.ok`. Per architect-review v1 Risk Highlight 4: split the 200-trial budget so ~half produce in-set hosts (verifying the negative case — outcome is NOT forced to `.ok` when host IS in set) and ~half produce foreign hosts (verifying the positive case — outcome IS `.ok`). Without this split a "always-returns-.ok" regression in Rule 4b would silently pass.

### 5.3 Account-level — in `AccountAuthSurfaceHostsTests` (NEW)

- `testAuthSurfaceHosts_derivesHostFromAuthenticationDocumentUrl`
- `testAuthSurfaceHosts_derivesHostFromCatalogUrl`
- `testAuthSurfaceHosts_derivesHostFromLoansUrl` (via details)
- `testAuthSurfaceHosts_returnsLowercasedHosts`
- `testAuthSurfaceHosts_returnsEmptySetWhenAllURLsAbsent`
- `testAuthSurfaceHosts_skipsMalformedURLs`

### 5.4 Integration (responder seam) — extend `TPPNetworkResponderAuthCoordinatorTests`

- `testResponder_401_foreignHost_classifiesAsOk_doesNotMarkRetried_doesNotDispatchCoordinator`
  - Configure a real `TPPNetworkResponder` + `URLSession` with `HTTPStubURLProtocol`.
  - Inject a host-set via the classifier (drive through the wiring path — this is the air-tight test that proves the production seam works end-to-end).
  - 401 from `gorgon.staging.palaceproject.io/a1qa-test/playtimes/...`.
  - Assert: `responder.canRetry(url:)` stays true post-completion (no `markRetried` consumed); the completion fires with failure (the responder returns false from `handleExpiredTokenIfNeeded`, and the no-coordinator-dispatch path bubbles up the 401 as a completion failure).
  - **Architect-review v1 Risk Highlight 3**: confirm `HTTPStubURLProtocol` + the existing test scaffolding supports injecting a test AccountsManager OR the host-set via a different seam (e.g. swizzling AppContainer.production() for the test scope). If not, the integration test will need a small refactor to make host-provider injectable at responder construction. The simpler path: have `TPPNetworkResponder` read the closure from a configurable property with a default that goes through AppContainer; tests override the property.

### 5.5 Sibling-site integration — extend `TokenRefreshInterceptorAuthCoordinatorTests` + `DownloadAuthRetryHandlerAuthCoordinatorTests`

- `testInterceptor_401_foreignHost_doesNotMarkCredentialsStale_doesNotDispatchCoordinator`
  - Configure the interceptor with a spy `AuthCoordinator` and a spy `TPPUserAccount`.
  - Inject a current-account hosts set of `{minotaur.dev.palaceproject.io}` via the same closure pattern as the classifier.
  - Drive a 401 with `originalRequestURL` = `https://gorgon.staging.palaceproject.io/a1qa-test/loans/...`.
  - Assert: spy account's `markCredentialsStale` count == 0; spy coordinator's `refreshCredentialsIfNeeded` count == 0.
- Same shape for `testDownloadRetry_401_foreignHost_doesNotMarkCredentialsStale_doesNotDispatchCoordinator` on `DownloadAuthRetryHandler`.

---

## 6. Acceptance

- All 12 Verification criteria pass.
- All new tests (≥ 12 across the four touched test files) pass.
- Existing tests pass: `AuthErrorClassifierTests`, `AuthErrorClassifierPropertyTests` (Invariants 1-7 still hold), `TPPNetworkResponderAuthCoordinatorTests`, `CrossDomain401Tests`, `URLResponseAuthenticationTests`.
- Mutation kill rate per criterion #7 met.
- `scripts/verify-pr.sh --quick` PASS.
- Wall-failure entry written at `.forgeos/wall-failures/2026-06-05-pr1018-icarus-cross-host-logout.md` with structural-prevention proposal (CLAUDE.md clause + classifier test invariant) AND the commit referenced from the entry.
- A separate Jira ticket filed for Bug B (playtimes-tracker stop on account switch) and linked from the wall-failure entry and this PR's body as the explicit follow-up.

---

## 7. Risk notes

- **The new closure adds a hidden dependency on `AppContainer.production()` at classifier-call time.** Tests that don't inject a custom provider use the default `{ nil }` → fallback to legacy behavior. This is the conservative direction: existing tests STILL pass even after the fix lands, because their `AuthErrorClassifier()` calls the default-init.
- **`Account.authSurfaceHosts` may return an empty set during cold launch** (auth document not yet loaded). The classifier MUST treat empty-set same as nil — fall back to legacy behavior so we don't false-block real account 401s while the auth doc loads.
- **Lowercasing matters.** The host comparison must be case-insensitive. `URL.host` returns whatever case the URL string used; we explicitly lowercase both sides.
- **No new public-surface drift** — the new init parameter on `AuthErrorClassifier` HAS a default value (`{ nil }`), so existing callers' source compiles unchanged. The new property on Account IS new public surface; annotate with `// PUBLIC_INTENT:`.

---

## 8. Not done (deferred)

- **Bug B — playtimes tracker doesn't stop on account switch.** Separate Jira ticket; out of scope for this PR. The classifier fix prevents the visible logout regardless; the tracker fix is independent hygiene (and may live in `ios-audiobooktoolkit` submodule).
- **TokenRefreshInterceptor / DownloadAuthRetryHandler full classifier-migration.** Scope expansion in §2 adds the foreign-host GUARD at both sites but does NOT migrate them off `indicatesAuthenticationNeedsRefresh` to `AuthErrorClassifier.classify(...)`. The PR #1018 deferral (network checklist §1) stands; the full migration is a separate refactor.
- **Per-IdP auth-surface coverage.** This PR uses `authenticationDocumentUrl + catalogUrl + loansUrl + homePageUrl`. A future pass may add more URLs (e.g., DRM-fulfillment hosts, sign-in service hosts) as they're identified. The empty-set fallback keeps the fix safe in the meantime.
- **3.1.0 baseline confirmation re: did playtimes route through TPPNetworkResponder at all in 3.1.0.** The handoff notes this as a secondary thread — confirm in a follow-up that the passive→active responder change is the sole regression vector (alternative: the audiobooktoolkit's networking changed too). Not blocking for this fix.

## 9. Architect-review trail

| Iteration | Verdict | Findings addressed | File |
|-----------|---------|-------------------|------|
| v1 (2026-06-05) | APPROVED-WITH-CHANGES | (1) sibling-site gap → Option B (expand scope) chosen, see §2/§3; (2) Criterion #4 miscount fixed (4→5); (3) AuthErrorClassifier mutation threshold raised 80%→100% to match existing file mandate; (4) Rule 4 + Rule 4b ordering test added to §5.1; (5) Property-fuzz invariant 8 split into in-set/foreign halves per Risk Highlight 4 | `.forgeos/changesets/fix-icarus-cross-host-logout/architect-review.md` |
