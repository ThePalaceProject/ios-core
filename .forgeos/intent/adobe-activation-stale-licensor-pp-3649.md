---
name: adobe-activation-stale-licensor-pp-3649
created: 2026-09-09
author: claude-opus-5
type: bugfix
tracking: PP-3649 — Adobe borrow fails with misleading "sign out and sign in again". Reproduced and fixed on device (Moes Max, A1QA, build 498), confirmed by device log before/after.
related_prs: []
---

# Intent: PP-3649 — the Adobe licensor goes stale, and every failure lied about why

## Context — measured, not theorised

The circulation manager mints a short client token with a **60-minute** TTL and
enforces it (`adobe_vendor_id.py`: `expires = {"minutes": 60}`, and
`_decode_short_client_token` raises past expiry). iOS wrote that token to the
keychain exactly once, on the user-profile leg of sign-in, and never refreshed
it. PP-3649 (3.0.0) then moved Adobe device activation OFF sign-in and onto the
first Adobe borrow, which can be arbitrarily later — so by activation time the
token is usually dead. Android does not have this bug: `BorrowACSM.adobeDeviceActivate`
re-runs the patron profile request and activates with the token it just received.

Crashlytics: ~25,421 events / ~4,013 users, first seen in 3.0.0.

Device evidence (2026-09-09): activation failed 555ms into the borrow against a
15s licensor grace period — the credential was present and simply old.

## Reproduction

On device (Moes Max, A1QA Test Library, build 498):

1. Sign in to A1QA. The circulation manager mints a short client token; iOS
   stores it once and never refreshes it.
2. Wait past the token's 60-minute TTL, or simply come back to the app later.
3. Borrow any Adobe-DRM title (used here: *Endless Summer*,
   `urn:isbn:9781488097300`).

Observed: the borrow fails ~555ms in. The alert reads "Borrowing Endless Summer
could not be completed. Please sign out and sign in again." The book row keeps
spinning after the alert is dismissed.

`Documents/Logs/palace_error.log` at the time:

    Palace/AdobeCertificate.swift: On-demand Adobe activation failed:
      (org.nypl.labs.ADEPTErrorDomain error 5.)
    adobeOriginalCode=E_ACT_TOO_MANY_ACTIVATIONS ... /adept/Activate 7528:528:7528
    Palace/DownloadStartCoordinator.swift: Borrow failed: DRM authentication failed

The last line is the defect in miniature: Adobe said "too many activations",
the patron was told to sign out and back in, and following that advice consumes
another activation.

Following the advice reproduces the escalation: each sign-in spends a slot,
sign-out fails to return one, and the account walks to the ceiling.

## Root cause

Two independent defects that compounded.

**1. The licensor is written once and never refreshed.** `TPPUserAccount.setLicensor`
is the only writer, called on the user-profile leg of sign-in. The CM's token
carries a 60-minute expiry it enforces on decode. PP-3649 (3.0.0) moved device
activation off sign-in and onto the first Adobe borrow, so the gap between mint
and use became unbounded. Nothing in between re-mints it. Android avoids this by
re-running the patron profile request immediately before activating.

The deeper shape: `hasLicensor()` reports PRESENCE, never VALIDITY. An expired
credential is indistinguishable from a good one at every call site, so staleness
was unrepresentable in the type and no amount of testing the callers would have
surfaced it. The same shape as `hasCredentials()` vs `authTokenHasExpired`.

**2. The error was mapped after the discriminator was destroyed.**
`AdobeCertificate` threw a hardcoded `PalaceError.drm(.authenticationFailed)`.
By the time `BorrowOperation` tried to read `NYPLADEPTErrorDomain` off the
NSError, the domain was `Palace.PalaceError` and the ADEPT code no longer
existed, so the mapping took its fallback branch on every input. It compiled,
ran, and did nothing — and the fallback was a plausible value, which is why it
read as working code.

**3. Sign-out's deauthorization failed silently.** It is the only thing that
frees an activation slot. It ran with the stored (possibly expired) licensor on
every non-success path, split the client token with code that could not fail,
and logged every failure as `warn` with the word "(expected)". A leaked
activation and a harmless no-op produced identical output.

## Claims

- `AdobeLicensorRefresh.resolve(stored:fetch:)` re-fetches the profile document
  before activation and prefers a usable fresh licensor, falling back to the
  stored one when the fetch yields nothing usable, so an unreachable refresh
  cannot turn a working borrow into a broken one.
- Adobe's error is mapped to `DRMError` through the SINGLE table on
  `PalaceError.drmError(for:)`, called at the throw site in `AdobeCertificate`
  where the `NYPLADEPTErrorDomain` code still exists. Round 1 of this branch
  added a SECOND table on `AdobeDRMService` that disagreed with the existing
  one on `userNotActivated`/`invalidUserActivation` and on the unknown-code
  fallback; the copy is gone and the new arms live on the original. The
  previous mapping sat downstream in `BorrowOperation`, after the error had been
  flattened to a hardcoded `PalaceError.drm(.authenticationFailed)`, so it took
  its fallback branch on every input and told a patron at the activation ceiling
  to sign out and back in — which consumes another activation.
- `AdobeDeauthorization.attempt(...)` returns nil only when there is no
  licensor at all, and reports `canReleaseServerSlot == false` for a client
  token that cannot be split. Round 1 refused outright on an unparseable token,
  which ALSO skipped RMSDK's clear of the LOCAL activation — the repair Reset
  Account exists to perform, withheld from exactly the malformed-token patron
  who needs it. `AdobeDeauthorization.outcome(...)` has **no benign case**: a
  deauthorization that did not succeed leaves the slot consumed regardless of
  cause. Sign-out reports the failure at error level plus Crashlytics.
- The BORROW-side profile fetch enables token refresh too
  (`Account.getProfileDocument(enableTokenRefresh:)`, opted into only by
  `freshLicensorFromProfileDocument`). `canAuthenticateProfileRequest`
  deliberately lets an expired-but-repairable token through on the reasoning a
  refresh will fix it; with the flag hardcoded false nothing did the fixing
  before the request went out.
- That fetch is bounded (`AdobeDRMService.boundedLicensor`, one-shot latch, 20s).
  It sits on the borrow path and OUTSIDE the activation deadline, so an
  unresumed continuation there would wedge the borrow — the shape that already
  cost this branch a ten-hour hang.
- The sign-out profile request enables token refresh. Its response body carries
  the fresh licensor and is the only chance to obtain one before deauthorizing;
  refusing to refresh an about-to-expire bearer token traded one round trip for
  a permanently leaked activation slot.
- Three copies of an inline client-token split (sign-in, sign-out, Reset Account)
  share `AdobeClientToken.split`. The inline version could not fail —
  a token with no separator yielded an empty username and the whole token as the
  password, and that was sent to Adobe. The owner is `AdobeClientToken`, a new
  UNGATED type: round 1 put the split on `AdobeDRMService`, which lives inside
  `#if FEATURE_DRM_CONNECTOR`, while its two ungated callers are compiled into
  `Palace-noDRM` — so that target did not build, and PR CI (DRM scheme only)
  would not have said so.
- The Adobe client token is redacted in the device log
  (`Documents/Logs/palace_error.log`, patron-exportable and routinely attached
  to support tickets). Library, expiry and signature length survive; the
  signature and the patron identifier do not. The sign-out path's
  `profileDoc.toJson()` — which encoded the patron's BARCODE and the whole
  client token into a `Log.error`, and fires whenever `drm:vendor` is nil —
  is replaced by `UserProfileDocument.loggableSummary`.
- `BookCellModel` observes `TPPBookProcessingDidChange` so the list-row spinner
  clears when the borrow ends, including when it ends in an error alert.

## Anti-claims

- **Does NOT free an activation slot.** A patron at the ceiling gets an accurate
  message and no in-app lever. No device-management UI is added — that is a
  deliberate product decision, not an oversight.
- Does NOT change LCP or unencrypted borrow paths.
- Does NOT retry the profile fetch on the sign-out error paths. A genuinely
  unreachable server still deauthorizes with the stored licensor; it is now
  logged as a leak rather than passing silently.
- Does NOT change the "Please deauthorize a device and try again" copy, which is
  accurate but not actionable without device management. Flagged, not decided.
- Does NOT audit `_cookies` or `_adobeToken`, which remain presence-only
  accessors with no expiry check — the same shape as the licensor bug.

## Files in scope

- Palace/MyBooks/BorrowAdobeActivationStep.swift
- Palace/MyBooks/BorrowOperation.swift
- Palace/MyBooks/MyBooks/BookCell/BookCellModel.swift
- Palace/Reader2/ReaderStackConfiguration/AdobeDRM/AdobeActivationCoordinator.swift
- Palace/Reader2/ReaderStackConfiguration/AdobeDRM/AdobeCertificate.swift
- Palace/Reader2/ReaderStackConfiguration/AdobeDRM/AdobeDeauthorization.swift
- Palace/Reader2/ReaderStackConfiguration/AdobeDRM/AdobeLicensorRefresh.swift
- Palace/SignInLogic/TPPSignInBusinessLogic+DRM.swift
- Palace/SignInLogic/TPPSignInBusinessLogic+ForceReset.swift
- Palace/SignInLogic/TPPSignInBusinessLogic+SignOut.swift
- Palace/Reader2/ReaderStackConfiguration/AdobeDRM/AdobeClientToken.swift
- Palace/Accounts/Library/Account+profileDocument.swift
- Palace/Accounts/User/UserProfileDocument.swift
- Palace/ErrorHandling/PalaceError.swift
- PalaceTests/DRM/AdobeClientTokenSplitTests.swift
- PalaceTests/DRM/AdobeDRMErrorMappingTests.swift
- PalaceTests/DRM/AdobeDeauthorizationTests.swift
- PalaceTests/DRM/AdobeLicensorRefreshTests.swift
- PalaceTests/DRM/AdobeActivationDedupTests.swift
- PalaceTests/DRM/AdobeActivationLicensorGraceTests.swift
- PalaceTests/MyBooks/BorrowAdobeActivationStepTests.swift
- PalaceTests/DRM/AdobeActivationRefreshLicensorTests.swift
- PalaceTests/MyBooks/BookCellModelProcessingStateTests.swift
- PalaceTests/Mocks/TPPDRMAuthorizingMockTimeoutTests.swift
- PalaceTests/Mocks/TPPDRMAuthorizingMock.swift
- PalaceTests/Accounts/AccountProfileDocumentTests.swift
- PalaceTests/UserProfileDocumentTests.swift
- scripts/dev/reset-adobe-activations.sh
- .claude/skills/reset-adobe-activations/SKILL.md

## Verification

### Round 2 — the SoD review fixes

`Palace-noDRM` did not compile before this round and does now, verified by
building the scheme rather than by reading: 4 errors / `** BUILD FAILED **`
before, 0 errors / `** BUILD SUCCEEDED **` after.

Mutation, per changed file (mechanically derived, `palace_mutate.py`):

| File | Result |
|---|---|
| `AdobeLicensorRefresh.swift` | 7/7 killed (100%) |
| `AdobeClientToken.swift` | 4/4 killed (100%) |
| `AdobeDeauthorization.swift` | 1/1 killed (100%) |
| `PalaceError.swift` (diff-scoped) | 1/1 killed (100%) |
| `BookCellModel.swift` (diff-scoped) | 1/1 killed (100%) |
| `AdobeCertificate.swift` (diff-scoped) | 1 survivor, see below |

Two survivors were fixed by changing the CODE, not by adding a test: a
`stored != nil` guard in `resolve` that gated only a log line, and a `Bool`
return on the licensor latch that no caller outside consumed — both were
distinctions no test could justify, and both are gone (the latch now returns
`timedOut` to its caller, where it is asserted). One survivor is
DELIBERATELY left: `separatorCount` inside a `TPPErrorLogger.logError` metadata
dictionary in `AdobeCertificate`. It feeds a Crashlytics non-fatal and nothing
else; `TPPErrorLogger` is a static with no seam at that call site, so killing it
would take a coverage-only test, which this project bans.

### Round 1

`AdobeDeauthorization.swift` has **no mutation points** — `palace_mutate.py`
reports none, because the file is guard/switch shaped with no comparison or
boolean operators to flip. A mutation score is therefore not available and is
not claimed. The guards were proven the other way instead: each defect was
reintroduced and required to produce a NAMED failing test.

| Defect reintroduced | Test that caught it |
|---|---|
| split that cannot fail | `test_split_noSeparator_returnsNilRatherThanAnEmptyUsername` |
| every failure treated as benign | `test_outcome_failure_isALeakedActivation_notAnExpectedNoOp` (+2) |
| token logged in plaintext | `test_redacted_neverContainsTheSignature` |

(The first two test names moved in round 2 — the split and the redaction now
live on `AdobeClientToken`, so their tests live in
`AdobeClientTokenSplitTests`. The reintroduction result is unchanged.)

12 tests → 5 failures with the defects in, 12 → 0 with them out.

Device confirmation (A1QA, Moes Max): the log line
`DownloadStartCoordinator: Borrow failed: DRM authentication failed` became
`Borrow failed: Too many device activations`, carrying `errorCode=5` and
`adobeOriginalCode=E_ACT_TOO_MANY_ACTIVATIONS`. Spinner clears on dismiss.
After resetting the Adobe identity server-side, the borrow and download
succeeded.
