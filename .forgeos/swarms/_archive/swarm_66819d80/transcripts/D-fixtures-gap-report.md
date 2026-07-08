---
name: swarm_66819d80-transcript-D-fixtures-gap-report
type: ephemeral
status: active
created: 2026-05-27
last_refresh: 2026-05-28
freshness_window: 180d
owners: [auth]
description: Auth fixture gap report (Module D, swarm_66819d80)
---

# Auth fixture gap report (Module D, swarm_66819d80)

**Generated:** 2026-05-27  •  **Inventory source:** `~/.simdrive/recordings/` (67 directories total; 5 auth-relevant)  •  **Catalog source:** `docs/3.2.0-auth-idp-catalog.md` (38 grounded rows + 11 UNKNOWN-pending-recording)

This is the bridge deliverable to Phase 7 of `palace-3.2.0-auth-architecture.md` — Module D writes the report; recording the missing flows is a separate operator session that requires backend credentials + the typing chokepoint workaround (see `feedback_simdrive_credential_typing_gap.md`).

---

## Method

```bash
ls ~/.simdrive/recordings/ | grep -iE "saml|oauth|oidc|signin|sign-in|basic|signout|sign-out|reauth"
```

Returned 5 matches; cross-referenced against the IdP × scenario matrix in the catalog. Recording filenames + journey paths are the authoritative metadata for what each fixture covers — `last-validated` per the recording's `recording.yaml` metadata (not refreshed by this audit).

---

## Have recordings (5)

| IdP × scenario                              | recording name                | last-validated         | notes |
|---------------------------------------------|-------------------------------|------------------------|-------|
| **Basic × Sign-in success**                 | `a1qa-basic-signin`           | per simdrive metadata  | a1qa fixture library; baseline coverage for the simplest IdP |
| **SAML × Sign-in (gorgon library)**         | `pr907-saml-signin-gorgon`    | PR #907 verification   | Specific to gorgon's Shibboleth flavor; not generic SAML |
| **SAML × Sign-in (Danny / library X)**      | `danny-saml-signin-init`      | per simdrive metadata  | Init-flow capture; doesn't cover session-expired re-auth |
| **OIDC × Sign-in (Icarus library)**         | `icarus-oidc-signin`          | per simdrive metadata  | Only OIDC fixture; doesn't cover IdP-session-expired or refresh-token loop |
| **Generic × Sign-out (a1qa)**               | `a1qa-sign-out`               | per simdrive metadata  | Generic sign-out; out of swarm scope (sign-out is OFF-LIMITS per Module C contract) but listed for completeness |

**Coverage summary:** 3 of 7 IdP types have at least one sign-in fixture (Basic / SAML / OIDC). 0 fixtures for token-refresh, OAuth-intermediary (Clever), SAML cookie-expiry-mid-borrow, license-expired, geo-restriction, or account-suspended scenarios. **5 of 42 cells (7 IdPs × 6 baseline scenarios) covered.**

---

## Gaps (cross-referenced against catalog UNKNOWN rows + critical-path tests)

### HIGH priority — gaps with shipped HelpSpot tickets or 3.0.x regression fixes

| # | IdP × scenario                                   | catalog § | priority | rationale + ticket / PR linkage |
|---|--------------------------------------------------|-----------|----------|---------------------------------|
| 1 | **Token × Silent refresh (near-expiry)**          | § 7       | HIGH     | `TokenRefreshOnForegroundTests` covers it at unit level but NO behavioral fixture exists. PR #931/#935 regressed this in 3.0.x; a fixture would have caught it. Frida library has test creds for Token IdP. |
| 2 | **SAML × Cookie expiry mid-borrow**               | § 4, § 6.3 | HIGH     | HelpSpot 17727 (Sonoma library); was the reason 3.0.2 hotfix shipped. PR #933 patched the audiobook-side detection; we have NO replay that simulates the mid-flow cookie expiry. |
| 3 | **OAuth-intermediary × Sign-in (Clever)**         | § 2       | HIGH     | Clever uses `palace-clever://` Universal Link callback, distinct from SAML/OIDC flows. Module B's broadening (3 sites add OAuth-intermediary to browser-based) is **untested behaviorally** — only 2 unit tests in `BorrowOperationCleverReauthTests`. Without a recording, the broadening could regress silently. |
| 4 | **SAML × Sign-in (Cornell Shibboleth)**           | § 6.1     | HIGH     | HelpSpot 17680 surfaced push-registration 401 cascade specifically against Cornell's Shibboleth. We have generic SAML (`pr907-saml-signin-gorgon`) and `danny-saml-signin-init` but neither is Cornell-shaped. PR #909 patched the push-reg side; the IdP-side replay is missing. |

### MEDIUM priority — gaps in IdP coverage that have shipped tickets but lower-frequency

| # | IdP × scenario                                   | catalog § | priority | rationale |
|---|--------------------------------------------------|-----------|----------|-----------|
| 5 | **SAML × Sign-in (RAILS)**                        | § 6.2     | MEDIUM   | HelpSpot 17716 — account reset triggered cross-library logout. Different cookie behavior from generic Shibboleth. Memory: `feedback_cross_library_signout.md`. |
| 6 | **SAML × Sign-in (NJStateLib)**                   | § 6.4     | MEDIUM   | Partner library; cookie-rotation interval is shorter than Shibboleth default, leading to more frequent 401s. Sibling of HelpSpot 17680. |
| 7 | **Forbidden × License expired (any IdP)**         | § 1, § 2  | MEDIUM   | Catalog row for Basic + OAuth shows `UNKNOWN — capture via simdrive recording`. Classifier `forbidden(.licenseExpired)` outcome is defined but no behavioral fixture validates the user-facing error path. |
| 8 | **OIDC × Sign-out**                               | § 3       | MEDIUM   | We have `a1qa-sign-out` (generic), `TPPSAMLLogoutTests` for SAML, but no OIDC sign-out replay. Sign-out is OFF-LIMITS for the swarm but a future regression here would be invisible. |
| 9 | **SAML × Bearer-token-invalid (IdP attribute mismatch)** | § 4 | MEDIUM   | Catalog row pinned to `URLResponseAuthenticationTests.testProblemDocument_recoverableSAMLBearerTokenInvalid_isRecoverable`. Unit-level. No replay shows the user experience when the IdP returns a 401 mid-session due to attribute change. |

### LOW priority — gaps better served by unit tests; recording would add little

| #  | IdP × scenario                                  | catalog § | priority | rationale |
|----|-------------------------------------------------|-----------|----------|-----------|
| 10 | **Any × Server 5xx during sign-in**              | § 1–7     | LOW      | Classifier returns `.serverError(status:)`; no IdP-specific branch fires. Unit tests in `AuthErrorClassifierTests` already pin every status; a recording would mostly screenshot a generic error sheet. |
| 11 | **Any × Network failure during sign-in**         | § 1–7     | LOW      | Same as above — classifier returns `.networkError`; unit tested. Recording would capture the "no internet" toast, useful for QA but not regression-killing. |
| 12 | **OIDC × IdP-session-expired**                   | § 3       | LOW      | Catalog row is grounded against `TokenRefreshInterceptor` + `DownloadAuthRetryHandler` + `TPPSignInOIDCTests`. Unit coverage is comprehensive. Replay would be high-effort (real OIDC IdP cooperation required) for low signal. |
| 13 | **OIDC × Callback URL malformed**                | § 3       | LOW      | Catalog calls out `TPPSignInOIDCTests.testHandleOIDCCallback_withMalformedPatronJSON_doesNotSetToken` — unit-test path. Recording the failure would require deliberately bad IdP config, hard to set up. |

---

## Recommended next session (the actual recording work)

Order of operations for a 90-min recording session (one operator, one device):

1. **Token × Silent refresh** (~20 min) — fastest setup. Use Frida library. Sign in normally, wait for token near-expiry, foreground the app, record the proactive refresh path. This single recording would have caught the 3.0.x token-refresh regressions (PRs #931, #935).
2. **SAML × Cookie expiry mid-borrow** (~30 min) — highest user impact. Use Sonoma library (matches HelpSpot 17727). Sign in, start a borrow, manually invalidate the SAML cookie (Settings → clear cookies for the IdP domain), continue the borrow. Captures the actual UX that 3.0.2 hotfix landed for.
3. **OAuth-intermediary × Sign-in (Clever)** (~20 min) — Clever test creds via partner. Records the Universal Link callback path; validates Module B's OAuth broadening behaviorally.
4. **SAML × Sign-in (Cornell Shibboleth)** (~20 min) — paired with HelpSpot 17680 retest. Cornell test creds via partner. Different attribute set than generic Shibboleth.

Each is `scripts/record-auth-flow.sh` (from PR #940) plus credential typing — note that simdrive credential-typing has a known chokepoint requiring `Bash → simdrive-input with shell var` workaround.

After these 4, coverage jumps from 5/42 → 9/42 (21%), and the 4 highest-impact UNKNOWN rows have behavioral fixtures.

---

## What Module D does NOT do

- **Does NOT record any new flows.** Recording requires backend credentials, partner library test accounts, and operator presence. This module's deliverable is the gap report + the telemetry seam; the recording session is separate work.
- **Does NOT create fixtures from existing replays.** The 5 existing recordings cover what they cover — extending one (e.g., adding cookie expiry to `pr907-saml-signin-gorgon`) is a new recording, not a fixture edit.
- **Does NOT prioritize the 4 SAML library variants together as one task.** Cornell/RAILS/NJStateLib/Sonoma each have distinct cookie behavior and distinct HelpSpot tickets; one recording per variant. Treating them as a batch would mask per-variant regressions.

---

## Cross-cut with Module D's telemetry deliverable

The `AuthDecisionEvent` non-fatal pattern (now wired through `AuthErrorClassifier` and `AuthCoordinator`) gives us a Crashlytics-side signal for **every** auth decision in production, regardless of whether a simdrive recording covers it. The gap report describes WHERE we lack pre-release behavioral fixtures; the telemetry describes WHERE in production decisions are happening (and crucially: which IdP × library × status_code cells get hit at what rate).

After the next regression class lands, the dashboard partition will tell us which of the 11 UNKNOWN rows the regression came from — and therefore which recording to prioritize next session. The two deliverables are complementary: fixtures prevent regressions, telemetry surfaces them when they slip through.
