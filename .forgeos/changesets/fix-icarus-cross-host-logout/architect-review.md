# Architect post-review — fix/icarus-cross-host-logout fix-contract

**Reviewer:** forge-architect-reviewer subagent
**Date:** 2026-06-05
**Verdict:** APPROVED-WITH-CHANGES

The contract is well-scoped for the visible regression (the per-minute Icarus modal driven by the TPPNetworkResponder path). The classifier-level fix is the correct seam — small, additive, and respects the network-area-checklist rule that "the network layer routes; it does not classify." Three issues need to be resolved before Phase 2 — none are deal-breakers; all are clarifications that the author can put into the contract in <30 minutes of edits.

---

## Findings

### Check 1: Scope-vs-reality

**Verdict:** MOSTLY-PASS, one significant gap.

- The contract's claim that `Palace/Network/TPPNetworkResponder.swift:465` is the only `AuthErrorClassifier()` construction site in **production** is **correct**. Verified via `grep -rn "AuthErrorClassifier(" Palace/`: the only non-test hit is line 465 of the responder. All other hits are in test files (`AuthErrorClassifierTests.swift`, `AuthErrorClassifierPropertyTests.swift`, `AuthDecisionPayloadTests.swift`, `TPPNetworkResponderAuthCoordinatorTests.swift:205`).
- The `Account` URL surface is real and present at the line numbers cited (`authenticationDocumentUrl` :553, `catalogUrl` :546, `homePageUrl` :548, `loansUrl` proxied via `details?.loansUrl` :566–568). The `authSurfaceHosts` computed property is a reasonable home — it derives from data Account already owns, and Account already exposes equivalent string-URL accessors. `AccountsManager` would be the wrong home (AccountsManager is a per-process manager of accounts, not a per-account aggregator). **APPROVED for location.**
- **GAP — sibling auth-classification sites:** The network area checklist explicitly enumerates two **STILL UNMIGRATED** sites that bypass the classifier:
  - `Palace/MyBooks/TokenRefreshInterceptor.swift:106` calls `httpResponse?.indicatesAuthenticationNeedsRefresh(with: problemDoc, originalRequestURL: originalURL)` and, on `true`, marks credentials stale (line 108) and dispatches through the coordinator (line 122) — **the exact same blast-radius path the contract is fixing in the responder.**
  - `Palace/MyBooks/DownloadAuthRetryHandler.swift:212` does the same shape (line 216 markStale, line 220 coordinator dispatch).

  Both use `URLResponse+TPPAuthentication.isSameDomain` which is **base-domain** (line 80–84 of that file: "last two parts of the host"), so the SAME `gorgon.staging.palaceproject.io` vs `minotaur.dev.palaceproject.io` mismatch returns "same-domain" and the 401 is classified as ours. If a download retry or token refresh for a foreign-host audiobook ever flows through these handlers while a different account is current, the regression class fires there too — and would dispatch the same modal-prompting coordinator path.

  The contract's Scope (out) doesn't acknowledge these. They are **arguably out of scope for this specific PR** (the device-reproduced bug is via the responder seam), but the author needs to make that decision **explicit**:
  - **Option A** (recommended): explicitly defer to a follow-up Jira ticket and reference it in Scope (out). Add an inline comment in MyBooks/ at both sites flagging the same regression class so the next refactorer doesn't lose context.
  - **Option B**: expand scope to add the same host-scoping check at both legacy call sites. ~6 prod LOC each; uses the same `Account.authSurfaceHosts` once it exists. Worth considering because the bug class is identical and shipping the fix in two places would close the wall completely.

  This is the only **scope-meaningful** finding in the review. Without resolution, the wall-failure entry will document a regression class that's still latent in the codebase.

### Check 2: Off-limits completeness

**Verdict:** MOSTLY-PASS, one ordering concern.

- `AuthCoordinator.recoveryStrategy` — explicit out, correct. The classifier returning `.ok` short-circuits before the coordinator is reached, so no coordinator change is needed.
- `/patrons/me` browser-auth bypass at lines 485–495 — verified in the responder. The new Rule 4b in the classifier returns `.ok` BEFORE the responder's `if response.statusCode == 401 { ... }` branch at line 482 is even entered (line 477 already has the `outcome == .ok → return false` short-circuit). So the new rule and the bypass do not interact — `.ok` skips both. **CORRECT.**
- `URLResponse+TPPAuthentication.isSameDomain` left alone — correct. The author's choice to do **HOST-equality** (not base-domain) for Rule 4b is deliberate and right: the existing base-domain helper protects against biblioboard.com / palaceproject.io CDN cross-domain; the new check is the orthogonal "same base-domain but DIFFERENT host belongs to a different library" case.
- **CONCERN — Rule 4 / Rule 4b ordering:** The contract describes Rule 4b as "AFTER Rule 4 (base-domain cross-domain at lines 142–147)." Let's trace what that means:
  - Rule 4: `if statusCode == 401, original != nil, !response.isSameDomain(as: original) → .ok` (different BASE DOMAIN).
  - Rule 4b (proposed): `if statusCode == 401, hosts != nil, !hosts.isEmpty, request.host ∉ hosts → .ok` (different HOST WITHIN same base domain).

  Sequencing Rule 4 → Rule 4b is correct for the bug at hand. **But consider this hypothetical**: a SAML library account on `minotaur.dev.palaceproject.io` whose `authSurfaceHosts` resolved to `{minotaur.dev.palaceproject.io}`, and a 401 comes in for `https://different-cdn.example.com/...` (true cross-base-domain). Rule 4 fires `.ok` (good). Rule 4b would also have fired `.ok` (also good). No conflict.

  **Now the inverse**: a 401 for `https://minotaur.dev.palaceproject.io/icarus-test-library/borrow/...` while currentAccount's `authSurfaceHosts` resolves to `{}` (empty — auth doc not yet loaded on cold launch). Rule 4 doesn't fire (same base domain). Rule 4b correctly falls through (empty set → legacy behavior per contract §7). The 401 reaches `classify401()` and yields `.reauthRequired(.unknown401)`. **CORRECT.**

  **Edge case worth pinning in a test**: Rule 4b fires when `authSurfaceHosts` is non-empty AND request host is NOT in the set. What if the auth surface is `{minotaur.dev.palaceproject.io, alt-cdn.othervendor.com}` (some libraries' auth-doc links span hosts), and the 401 comes from `cdn.palaceproject.io` (a Palace CDN that's neither in the set nor the request's base-domain)? Rule 4 would fire first because `cdn.palaceproject.io` shares base-domain with the original-request URL (if original was a palaceproject.io URL). Result: `.ok` via Rule 4 — never reaches 4b. That's fine because base-domain matching IS broader than host matching. **No ordering bug.**

  Recommendation: the contract's `testClassify_401FromForeignHost_*` set should include an explicit "Rule 4 and Rule 4b can both apply; Rule 4 wins because it comes first" assertion to lock the order. One additional test (~10 LOC).

### Check 3: Verification criteria validity

**Verdict:** PASS with one correction.

- **Criterion #4 — pre-existing count of `statusCode == 40[13]`:** The contract says "4 lines: 221, 230, 367, 482." Actual count is **5 lines: 221, 230, 291, 367, 482** (verified via `grep -n "statusCode == 40[13]" Palace/Network/TPPNetworkResponder.swift`). Line 291 is `if !isFailedRetry || http.statusCode == 401 {` (an unrelated retry guard). The contract's verification criterion should say **"equal to pre-existing count of 5"** so it doesn't fail accidentally if the author counts what's really there. **One-line fix to the contract.**
- **Criterion #7 mutation thresholds (80% / 50% / 80%):** Auth checklist Section 6 doesn't actually mandate 100% on `AuthErrorClassifier` — the file header comment in `AuthErrorClassifierTests.swift:10` does ("Mutation gate: AuthErrorClassifier.swift must hit 100% kill rate"). The contract's 80% threshold is **below the existing file-level bar.** Recommend: set the AuthErrorClassifier threshold to **100% (matching the existing in-file mandate)** rather than 80%, since the file already meets that bar and the new rule is small and isolated enough to make 100% achievable. The 50% for the responder closure and 80% for the new Account property are reasonable.
- All other grep commands are syntactically valid and target the right files. `check-test-name-vs-body.py`, `check-contract-reconciliation.py`, `check-blast-radius.py`, `check-adjacency-staleness.py`, `check-superpartner-spectrum.py` are all canonical CLAUDE.md DoD checks.
- **`// PUBLIC_INTENT` annotation in §7 risk notes:** The new closure parameter on `AuthErrorClassifier.init` is in fact NEW public surface on a public SPM type. The contract correctly identifies this and pre-empts the BR-1 hook block. **APPROVED.** Make sure the annotation actually appears in both decl sites — on the new init param AND on the new `Account.authSurfaceHosts` property.

### Check 4: Single-module judgement

**Verdict:** PASS — `/rigorous-fix` (single-cause critical path) is correct.

The contract touches three modules by file path: `Palace/Packages/PalaceAuth/`, `Palace/Network/`, `Palace/Accounts/`. By LOC the work is concentrated almost entirely in PalaceAuth (the classifier rule + 4 new tests + property fuzz invariant ≈ ~110 LOC of the ~213-LOC total), with two ~10–12-LOC ancillary touches:
- `Palace/Accounts/Library/Account.swift` — a single computed property that aggregates URLs Account already owns. No new dependency, no new behavior on Account itself. It's an **accessor**, not a module change.
- `Palace/Network/TPPNetworkResponder.swift` — passing a closure into the classifier. Six LOC. No new branch, no new decision logic.

These are not three "modules of work" in the rigor-bar sense — they're one classifier change + one one-line accessor + one wiring tweak. The blast radius is entirely contained inside the existing classifier seam that PR #1018 made the single decision point.

`/swarm` would add 3-module triage + contract negotiation + integrator merge overhead that exceeds the actual work. The fix is single-cause (one rule, one boolean: "is this request's host in the current account's auth-surface?"), critical-path (auth-error decisions are exactly where /rigorous-fix's architect + SoD review provides value), and small (~33 prod LOC). **`/rigorous-fix` is the right tool.**

The author's existing decision to use `/rigorous-fix` stands.

---

## Required changes before Phase 2 (APPROVED-WITH-CHANGES)

1. **Address sibling unmigrated sites (Check 1 gap).** Update Scope (out) section to explicitly either:
   - **Defer** `TokenRefreshInterceptor.swift:106` and `DownloadAuthRetryHandler.swift:212` to a follow-up Jira ticket. File the ticket as part of this PR's wall-failure entry. Add inline comments at both sites flagging the same regression class. OR
   - **Expand scope** to add the same `authSurfaceHosts`-based check at both sites. This would add ~12 prod LOC + ~30 test LOC and would close the regression class completely.

   Either choice is defensible; the author must make it explicit. If deferring, the wall-failure entry needs to name the residual risk and the follow-up ticket.

2. **Fix the count in Verification Criterion #4.** Change "4 lines: 221, 230, 367, 482" to "5 lines: 221, 230, 291, 367, 482" (line 291 is `if !isFailedRetry || http.statusCode == 401 {`, an unrelated retry guard).

3. **Raise the AuthErrorClassifier mutation threshold to 100% (Criterion #7).** The existing file-level mandate in `AuthErrorClassifierTests.swift:10` already says "100% kill rate"; the contract's 80% is below the established bar. Either match the bar or document why the new rule is exempt (it shouldn't be — it's small and pure).

4. **Add an explicit "Rule 4 + Rule 4b co-applicability" test** to lock the ordering. Suggested name: `testClassify_401_baseDomainCrossOriginAndForeignHost_returnsOkViaRule4_notRule4b` — drives a request where both rules would yield `.ok` and asserts Rule 4 fires first (verifiable via telemetry-recorder spy ordering or by leaving Rule 4b's `authSurfaceHosts` provider nil).

---

## Risk highlights for the author

- **The new `Account.authSurfaceHosts` property must lowercase consistently** — `URL.host` returns case-as-given. The contract notes this in §7 and the test `testClassify_401FromCurrentAccountHost_caseInsensitiveMatch` exercises it. Belt-and-braces: lowercase BOTH the set entries AND the comparison input. Pin in the `Account` test as well — case-insensitive at the producer (`Account.authSurfaceHosts`) is a defense-in-depth against a future consumer that forgets to lowercase.

- **Cold-launch empty-set fallback (§7 of contract) is correct but fragile.** Currently the auth document loads asynchronously after current-account switch. If a 401 lands in that window and the classifier defaults to legacy behavior, the bug recurs briefly. Acceptable trade-off (false-block on cold launch would be much worse), but worth noting: the wall-failure entry should call out the residual window so future readers don't think the fix is total.

- **The closure dependency on `AppContainer.production()` adds a hidden coupling at the classifier-call site in the responder.** The classifier itself stays pure (closure injection), but the closure body reads a static singleton. Tests that exercise the responder seam end-to-end (per Section 5.4) need a way to inject a test AccountsManager — verify `HTTPStubURLProtocol` + responder construction in the existing `TPPNetworkResponderAuthCoordinatorTests.swift` already supports this. If not, the integration test will need a small refactor to make AccountsManager injectable at the responder construction.

- **Property-fuzz Invariant 8** (random host sets + random URLs, 200 trials) — make sure the fuzzer's random URL generator can produce URLs whose host is BOTH in the set (to verify the negative case) AND outside it (to verify the positive case). A fuzzer that only ever produces foreign hosts won't catch a future "always returns .ok" regression. Recommend: split the existing 200-trial budget so ~half produce in-set hosts and ~half produce foreign hosts, asserting the appropriate outcome in each half.

- **3.1.0 baseline behavior thread (handoff §3 secondary note).** The handoff notes uncertainty about whether the playtimes POST routed through TPPNetworkResponder in 3.1.0 at all. Confirming this matters for the wall-failure entry's "what changed" classification — if 3.1.0 didn't route the POST through the responder, the regression vector is "PalaceAudiobookToolkit submodule networking shifted AND PR #1018 made the responder's auth-dispatch active" (compound), not just the PR #1018 passive→active change. Not blocking for this fix, but the wall-failure analysis should resolve it.

- **The new public-surface init parameter has a default value, so source-compat is preserved.** Confirm at write time that the default is `{ nil }` (matching the `mechanismProvider` and `libraryUUIDProvider` pattern at line 54–55 of the existing init). The classifier's existing tests construct `AuthErrorClassifier()` with no args; that should continue to work and yield legacy behavior.
