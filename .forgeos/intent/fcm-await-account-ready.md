---
name: fcm-await-account-ready
created: 2026-08-14
author: claude-opus-5
---

**ADR refs:** none for push-token registration. `Account+State.swift` cites an
"ADR migration plan" for readiness gates; `docs/architecture/` records no
decision file covering it. ForgeOS ADR API not queried (governance OFF).

## Context — and a correction

Crashlytics `d63871fd373c6166be95ec63093588dc` (`[FCM_REG] token registration
deferred: profile fetch returned nil`) is the largest signal in the app:
~53,000 events / ~6,600 patrons in 30 days. Affected patrons receive no push
notifications, so "your hold is ready" never arrives.

**A first attempt at this (`fcm-profile-fetch-token-refresh`, commit a33aeba73)
was withdrawn as inert.** It flipped `getProfileDocument` to
`enableTokenRefresh: true` on the theory that an expired token caused a 401.
Review established the request never carries a bearer at all (only
`executor.request(for:)` attaches one), and re-reading the evidence showed the
request is never even issued. Recorded here so the wrong theory is not
re-derived.

The real cause, confirmed on three independent events:

| event | `currentAccountDetails` | authState | trigger |
|---|---|---|---|
| IL0502 | null | loggedIn | FCM registration callback at launch; auth doc +382ms |
| IL0083 | null | loggedIn | FCM registration callback at launch; auth doc +218ms |
| CT0020 | null | loggedOut | `TPPCurrentAccountDidChange` ← Settings library switch |

`updateToken()` runs while `account.details` is nil, because the account's
authentication document has not loaded yet. `Account.getProfileDocument` then
returns on its FIRST guard — `guard let profileHref = self.details?.userProfileUrl`
— with no network call and no log line. Registration is skipped and the
non-fatal fires.

It never self-heals: the retry added for PP-4275 requires a transition INTO
`.loggedIn`, which does not occur here.

Corroboration that the network is not involved: the network-failure branch logs
`Error retrieveing user profile document`, which stands at only ~155 events /
53 users — two orders of magnitude below the deferral count.

## Claims

- migrates `NotificationService.updateToken()` to await the current account's readiness via the existing bounded `Account.awaitReady(timeout:)` before attempting registration, so the profile URL exists by the time `getProfileDocument` is called
- adds a bounded readiness timeout constant to `NotificationService`; the BOUNDED overload is used deliberately, because an unbounded `awaitReady()` behind a background path is the documented HelpSpot #18414 load-forever wedge
- removes the Crashlytics non-fatal for the deferrals that are genuinely expected — patron signed out, and library switch — so the remaining signal means "registration genuinely failed" rather than "ran too early". The TIMEOUT is deliberately NOT silenced; see the `.residual` claim below
- adds corrected diagnostic wording to the `profile_doc_missing` branch, whose current text blames SAML-stale or missing credentials; the measured cause is an unloaded authentication document
- adds two NEW non-fatals that did not exist before: `account load failed` (the authentication document genuinely will not arrive) and `details nil after readiness` (the account reported ready but the live instance has no details). Both are narrow and are the residue left after the expected deferrals stop being reported
- adds `RegistrationClaims`, a per-account single-flight for the readiness wait, so concurrent triggers do not collapse into duplicate registrations AND a library switch does not have the incoming account's trigger swallowed by the outgoing account's attempt
- migrates `markTokenRegistered()` to `markTokenRegistered(for:)`, latching the flag on the account the attempt was FOR rather than whatever account is current when it lands
- adds `NotificationService.disposition(forReadinessFailure:)`, a pure classifier over all five `AccountLoadError` cases, so the routing decision is table-tested rather than buried in a Task
- adds `PalaceTests/MetaTests/FCMRegistrationReadinessLintTests` pinning that registration happens INSIDE the Task that awaits readiness AND after the await, exactly once, that no readiness error is swallowed (neither `try?` nor a catch that falls through), and that the registration flag is latched on the account passed in. Every check carries a synthetic violator, verified by deleting each check in turn rather than by inspection — four checks previously survived deletion with the whole suite green
- adds `PalaceTests/Notifications/NotificationServiceReadinessGateTests`, runtime coverage of the gate itself, observed through CLAIM LIFETIME. `RegistrationClaims` holds the account's slot from just after the account is captured until the awaiting Task body returns, so "still claimed after a real budget" means the wait is genuinely parked, and a same-uuid trigger is rejected before it can release the slot — the signal depends only on the mechanism under test. Mutation-proven: replacing the readiness await with a no-op releases the claim in milliseconds and fails the holding test
- restores `RegistrationClaims.isClaimed`, which is what that observation needs, and exposes it through a read-only `NotificationService.isRegistrationClaimed(_:)` forwarder. The claims table ITSELF is `private`: an earlier revision made it internal, which let any module code call `claim(_:)` and wedge push registration for an account permanently, since only the owning attempt's `defer` releases it. Tests only ever ask, so only asking is exposed. This is not the round-4 `profileDocumentProvider` mistake: that was new surface on a production path with no consumer, this is a read on a helper that exists solely for this fix and now has a test
- retypes `accountsManager` to `any TPPLibraryAccountsProvider & Sendable` and accepts a substitute on the existing test-only initializer, which is the seam the above test uses. Behaviour-neutral: `AccountsManager` already conforms and every member used is a protocol member. The `& Sendable` is load-bearing rather than decorative — the bare `@objc` protocol carries no such constraint, so without it this class's `@unchecked Sendable` argument rested on who injects rather than on the type. The substitute is passed as an optional defaulting to `nil`, NOT as `= AppContainer.production().accountsManager`: a default argument is evaluated at the call site, which is the documented AppContainer re-entrant-lock launch abort
- extracts `performTokenRegistration(for:)` so the post-gate work is one named call the structural lint can pin
- adds `NotificationService.shouldReportProfileFetchFailure(authState:)`, a pure predicate over the auth-state table, so a signed-out patron stops filing a failure
- splits the readiness-failure disposition three ways rather than two. `.readinessTimedOut` is now `.residual`, reported under its own summary, so the fix stays falsifiable: silencing it would drive the metric this change is judged by to near-zero whether registration succeeds or the account is simply never driven
- amends `docs/architecture/account-state-machine.md` with this call site's Bucket-A UX/timeout row and the PP-4958 rationale

## Anti-claims

- does NOT change `Account.getProfileDocument`, its `enableTokenRefresh` argument, or any network behavior — the withdrawn attempt did, and was wrong
- does NOT change `shouldRetryTokenRegistration` or the auth-state retry subscription
- does NOT change the auth-document load path, `AuthDocumentLoader`, or `Account+State`
- does NOT change any endpoint, request shape, or Circulation Manager contract
- does NOT address the separate `fcm_token_unavailable` (APNS-not-yet-issued) failure
- does NOT gate `deleteToken(for:)`, which calls `getProfileDocument` ungated and shares the same nil-`details` no-op. Deliberately out of scope: it removes a registration rather than failing to create one, so a no-op there does not cost a patron notifications. Named here because review found it unrecorded.
- does NOT introduce an unbounded await anywhere
- does NOT duplicate `PalaceTests/Accounts/AccountStateMachineTests.testAwaitReadyTimeout_wedgedAtDetailsLoading_throwsReadinessTimedOut`, which already pins — more strongly — that `awaitReady(timeout:)` does not return while the account sits at `.detailsLoading`. A round-6 file restating that weaker was written and deleted; the primitive is covered there, and this change covers the gate
- does NOT observe the gate by counting provider reads. Two attempts did and both were unusable, recorded so neither is re-derived: counting `userAccount(for:)` is ambiguous because `updateToken()`'s prologue resolves the same uuid, and counting `currentAccount` — even by parity, which survives whole extra triggers — is defeated because the test host re-enters `updateToken()` through `installNotificationObservers` AND `decideHoldNavigation` reads `currentAccount` on its own. The parity version passed in isolation and failed intermittently in the suite. An earlier round concluded from the first failure that NO observable existed and deleted the tests; that conclusion was wrong, and two reviewers said so

## Files in scope

- Palace/Notifications/NotificationService.swift
- PalaceTests/Notifications/NotificationServiceTokenTests.swift
- PalaceTests/MetaTests/FCMRegistrationReadinessLintTests.swift
- PalaceTests/Notifications/NotificationServiceReadinessGateTests.swift
- Palace.xcodeproj/project.pbxproj
- docs/architecture/account-state-machine.md

## Call-site census

`updateToken()` has four triggers, all of which benefit and none of which change
contract:

| trigger | today | after |
|---|---|---|
| `messaging(_:didReceiveRegistrationToken:)` (launch) | runs before auth doc loads → skipped | waits for readiness → registers |
| `TPPCurrentAccountDidChange` (library switch) | same | same |
| `TPPIsSigningIn` (sign-in completes) | usually already ready | fast path, but now returns early if another attempt already holds this account's claim |
| auth-state recovery subscription | usually already ready | fast path, but now returns early if another attempt already holds this account's claim |

Known, accepted trade: a SAME-account trigger arriving while an attempt holds the
claim is dropped rather than queued. The cross-account arm of this was a real
defect and is fixed by keying per uuid; the same-account arm is benign, because
the in-flight attempt is already doing the work the dropped trigger would have
done. It is recorded here rather than left unstated.

`awaitReady` fast-paths when the account is already terminal, so a ready account
pays nothing.
