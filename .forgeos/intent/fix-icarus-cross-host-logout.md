---
name: fix-icarus-cross-host-logout
created: 2026-06-05
author: claude-opus-4-7
tracking: PP-4436 (3.2.0 regression pass — no dedicated Jira ticket per user direction)
related_prs: ["#1018 (regressing change, swarm_66819d80, commit f380e37c3)"]
---

## Summary

PR #1018 ("3.2.0 auth architecture: AuthErrorClassifier + AuthCoordinator + isBrowserBased") introduced a regression where a 401 from a foreign library's host is misattributed to the current OIDC/SAML account, dispatching `AuthCoordinator.refreshCredentialsIfNeeded(.oidcRefreshFailed)` → `.modal` for the wrong account every minute.

Device evidence ("Moes Max", iPhone 17 Pro Max): an Icarus (`minotaur.dev.palaceproject.io`) OIDC account is signed in. A previously borrowed A1QA audiobook on `gorgon.staging.palaceproject.io` uploads playtimes every minute and returns 401. The existing cross-domain guard in `AuthErrorClassifier` (and the two legacy sibling sites) uses BASE-DOMAIN matching (`URLResponse.isSameDomain`), so `gorgon.staging.palaceproject.io` and `minotaur.dev.palaceproject.io` both resolve to base `palaceproject.io` → "same domain" → 401 is treated as the current account's session expiry. Pre-#1018 this branch was a passive `markCredentialsStale` and user-invisible; post-#1018 it actively dispatches the coordinator and pops a sign-in modal for the WRONG account every minute.

Fix: add a current-account host-scoping check. `Account.authSurfaceHosts` exposes the lowercased set of hosts derived from `authenticationDocumentUrl + catalogUrl + loansUrl + homePageUrl`. `AuthErrorClassifier` gets a new `currentAccountHostsProvider: @Sendable () -> Set<String>?` closure (default `{ nil }` = legacy behavior). New Rule 4b in `classifyCore`: when the provider returns a non-empty set and the 401's original-request host is NOT in that set, return `.ok` ("not our account's session"). `TPPNetworkResponder` constructs the classifier with a closure that reads `AppContainer.production().accountsManager.currentAccount?.authSurfaceHosts`. The two legacy sibling sites (`TokenRefreshInterceptor:106`, `DownloadAuthRetryHandler:212`) that bypass the classifier get the same closure shape with an inline foreign-host guard before their mark-stale + coordinator-dispatch branches.

## Claims

- Adds `var authSurfaceHosts: Set<String>` computed property on `Account` (lowercased hosts from `authenticationDocumentUrl + catalogUrl + loansUrl + homePageUrl`, empty set when none available, malformed URLs skipped).
- Adds `currentAccountHostsProvider: @Sendable () -> Set<String>?` init parameter on `AuthErrorClassifier` (default `{ nil }`).
- Adds new Rule 4b in `AuthErrorClassifier.classifyCore`: foreign-host 401 → `.ok`.
- Wires the closure at `TPPNetworkResponder.swift:465` so the responder's `handleExpiredTokenIfNeeded` short-circuits on foreign-host 401 via the existing `outcome == .ok` check at line 477.
- Adds `currentAccountHostsProvider: (@Sendable () -> Set<String>?)? = nil` init parameter on `TokenRefreshInterceptor` and `DownloadAuthRetryHandler` (defaults to nil = legacy behavior).
- Adds an inline foreign-host guard before the existing `indicatesAuthenticationNeedsRefresh` branch at `TokenRefreshInterceptor.swift:106` and `DownloadAuthRetryHandler.swift:212`.
- Wires both sibling sites at their `MyBooksDownloadCenter` construction sites with the AppContainer-backed closure.
- Adds 6 new unit tests to `AuthErrorClassifierTests` (foreign-host, same-host, default-provider, empty-set, case-insensitive, Rule 4 + Rule 4b ordering pin).
- Adds Property-fuzz Invariant 8 to `AuthErrorClassifierPropertyTests` with a 50/50 in-set/foreign generator across 200 trials.
- Adds 7 new tests in `PalaceTests/Accounts/AccountAuthSurfaceHostsTests.swift`.
- Adds 1 classifier-seam test to `TPPNetworkResponderAuthCoordinatorTests`.
- Adds 2 integration tests each to `TokenRefreshInterceptorAuthCoordinatorTests` and `DownloadAuthRetryHandlerAuthCoordinatorTests` (foreign-host short-circuit + nil-provider fallback).
- Updates `docs/architecture/areas/auth/verification-checklist.md` § 7 and `docs/architecture/areas/network/verification-checklist.md` § 7 with the new "foreign-library cross-host 401" trap.
- Adds a CLAUDE.md clause under "Risk-driven rigor bar" documenting that any 401 / credentials-stale decision must consult a current-account host set.
- Creates wall-failure entry `.forgeos/wall-failures/2026-06-05-pr1018-icarus-cross-host-logout.md` with `walls: [contract, TDD, reviewer, stale-doc]`.

## Anti-claims (out of scope)

- Does NOT modify `AuthCoordinator.swift` (dispatch matrix + recovery strategy unchanged; once the classifier returns `.ok` the coordinator is never called for this scenario).
- Does NOT modify `URLResponse+TPPAuthentication.isSameDomain` — the existing base-domain helper stays for the original biblioboard / CDN cross-domain CDN guard.
- Does NOT migrate `TokenRefreshInterceptor` / `DownloadAuthRetryHandler` off the legacy `indicatesAuthenticationNeedsRefresh`. This PR adds the foreign-host GUARD at both sites; the broader classifier migration stays as PR #1018's already-tracked deferral.
- Does NOT change behavior for any existing test that uses the default `AuthErrorClassifier()` constructor — the default `{ nil }` provider preserves legacy 401 classification.
- Does NOT add a new `AuthOutcome` case — reuses `.ok` (semantically equivalent to the existing cross-domain CDN carve-out: "not our account's session").
- Does NOT touch Bug B (audiobook playtimes tracker continuing to upload for an account that is no longer active in `PalaceAudiobookToolkit` submodule + Palace audiobook-session lifecycle). The classifier fix prevents the visible logout regardless; tracker fix is independent.
- Does NOT touch `AccountsManager.swift` — `currentAccount: Account?` is read through the existing public property by the closures at the call sites.

## Files in scope

Production:
- `Palace/Packages/PalaceAuth/Sources/PalaceAuth/AuthErrorClassifier.swift`
- `Palace/Network/TPPNetworkResponder.swift`
- `Palace/Accounts/Library/Account.swift`
- `Palace/MyBooks/TokenRefreshInterceptor.swift`
- `Palace/MyBooks/DownloadAuthRetryHandler.swift`
- `Palace/MyBooks/MyBooksDownloadCenter.swift`

Tests:
- `Palace/Packages/PalaceAuth/Tests/PalaceAuthTests/AuthErrorClassifierTests.swift`
- `Palace/Packages/PalaceAuth/Tests/PalaceAuthTests/AuthErrorClassifierPropertyTests.swift`
- `PalaceTests/Network/TPPNetworkResponderAuthCoordinatorTests.swift`
- `PalaceTests/MyBooks/TokenRefreshInterceptorAuthCoordinatorTests.swift`
- `PalaceTests/MyBooks/DownloadAuthRetryHandlerAuthCoordinatorTests.swift`
- `PalaceTests/Accounts/AccountAuthSurfaceHostsTests.swift` (new)

Docs / governance:
- `CLAUDE.md` (Risk-driven rigor bar clause)
- `docs/architecture/areas/auth/verification-checklist.md` (§ 7 trap)
- `docs/architecture/areas/network/verification-checklist.md` (§ 7 trap)
- `.forgeos/wall-failures/2026-06-05-pr1018-icarus-cross-host-logout.md` (new)
- `.forgeos/changesets/fix-icarus-cross-host-logout/fix-contract.md` (already created)
- `.forgeos/changesets/fix-icarus-cross-host-logout/architect-review.md` (already created)
- `Palace.xcodeproj/project.pbxproj` (new AccountAuthSurfaceHostsTests.swift entry)
