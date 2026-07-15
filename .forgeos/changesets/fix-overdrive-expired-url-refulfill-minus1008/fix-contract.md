# Fix-contract — OverDrive expired signed-URL playback recovery fires on AVPlayer -1008

## Problem (empirically confirmed)
OverDrive audiobooks stream their tracks from time-limited signed URLs baked into the
on-disk OverDrive manifest (`links.contentlinks`, ~24h `URLExpirationUTC`). When the
local track download did NOT complete (large books over background URLSession) OR the
URLs have since expired, playback falls back to streaming those stale URLs → server
returns HTTP 410 Gone → AVFoundation surfaces it to the app as `NSURLErrorDomain -1008`
(NSURLErrorResourceUnavailable) with NO `httpStatusCode` in the error. Symptoms: open
hangs / "A Problem Has Occurred", and skipping across tracks breaks (each track's URL
is dead). Real repro captured on device (Moes Max, Mi historia / A1QA), 2026-07-15.

The 3.2.0 recovery `AudiobookSessionManager.shouldTriggerOverdriveRefulfillForPlaybackFailure`
re-fulfills fresh URLs — but gates on `httpStatusCode(from:error) == 410`, which is
`nil` for the -1008 shape, so the bounded one-shot re-fulfill NEVER fires in the field.

## Scope (in)
- File: `Palace/Audiobooks/AudiobookSessionManager.swift`, `#if FEATURE_OVERDRIVE`
  region (~1981-2021).
  - Add `isResourceUnavailable(from:) -> Bool` helper: true iff the error is
    `NSURLErrorDomain` code `NSURLErrorResourceUnavailable` (-1008) at top level, via
    the flattened `underlyingDomain`/`underlyingCode` userInfo scalars (the
    `buildPlaybackFailureRecord` shape), or one level down `NSUnderlyingErrorKey`.
  - `shouldTriggerOverdriveRefulfillForPlaybackFailure`: keep OverDrive-only +
    !alreadyAttempted guards; return true when `httpStatusCode == 410` **OR**
    `isResourceUnavailable(error)`.
- File: `PalaceTests/DRM/OverdriveFulfillmentTests.swift` — add tests for the new shapes.

## Scope (out) — DO NOT touch
- `httpStatusCode(from:)` — unchanged (410 path preserved).
- `shouldTriggerSAMLReauthForPlaybackFailure` — sibling; NOT broadened to -1008 (a
  -1008 on a SAML book must not loop into a revoked session).
- The proactive "re-fulfill on open before streaming stale URLs" layer — deferred
  (reactive -1008 recovery already resolves the open-hangup AND skip-break, since both
  surface as -1008 → trigger the bounded re-fulfill → fresh contentlinks). Documented
  as a follow-up, not silently dropped.
- `ios-audiobooktoolkit` submodule — no change (app-side fix only).

## Conservative exclusions (preserved)
No re-fulfill on: 401/auth, 403 (ambiguous), -1009 (no network), -1001 (timeout), or
any error with neither a 410 nor a -1008 resource-unavailable signal. One attempt per
book per session (`alreadyAttempted`).

## Tests required (TDD, red first)
- `-1008` at top level (domain NSURLErrorDomain) on OverDrive book → true.
- `-1008` via flattened `underlyingCode`/`underlyingDomain` scalars → true.
- `-1008` nested in `NSUnderlyingErrorKey` → true.
- `-1009` (not-connected) on OverDrive book → false (no network is not expiry).
- `-1001` (timeout) → false.
- `-1008` but `alreadyAttempted` → false (bounded).
- `-1008` but non-OverDrive distributor → false.
- Existing 410 / 403 / 401 / no-status tests stay green (additive change).

## Verification criteria
- `grep -c "AudiobookSessionManager(" ...` not required (static-method SUT; tests call
  `AudiobookSessionManager.shouldTriggerOverdriveRefulfillForPlaybackFailure(...)`).
- New tests fail against current code (return false for -1008), pass after the change.
- Mutation on the two edited functions ≥ 50% diff-scoped (critical path → aim 100%).
- Build clean; OverdriveFulfillmentTests green; no existing test regresses.

## Release targeting
develop (3.3.0) + cherry-pick to `release/3.2.0` (blocker-class OverDrive regression
present in 3.2.0).
