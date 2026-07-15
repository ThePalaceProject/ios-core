---
name: ws3-overdrive-expired-url-refulfill
created: 2026-06-11
author: Maurice Carrier
branch: fleet/w-lane-overdrive
initiative: init_17bfe690
priority: WS-3 / 3.2.0 crash-triage follow-up (critical-path)
---

# Intent: bounded re-fulfill recovery for OverDrive audiobook expired-signed-URL playback dead-end

## Context

WS-3 / deferred 3.2.0 crash-triage item (Crashlytics `04373e48` / `d2c9e0ef`).
OverDrive audiobook manifests carry time-limited SIGNED audio URLs. For a
DOWNLOADED OverDrive book, `LocalFileAdapter.resolveManifest`
(`Palace/Audiobooks/Vendors/LocalFileAdapter.swift:84`) reads the on-disk
manifest whose signed URLs may have expired → AVPlayer streams → 403/410 →
`AudiobookManagerState.playbackFailed`. `handleManagerState`'s `.playbackFailed`
case (`Palace/Audiobooks/AudiobookSessionManager.swift:1574`) records the failure
and has ONLY a SAML-reauth recovery branch (`:1600`). OverDrive is not SAML, so
it falls through to `errorPublisher.send(.unknown("Playback failed"))` (`:1625`)
+ cold-load dismiss — a dead-end with no recovery.

Pinned approach (memory `project_3_2_0_crash_triage`): re-fulfill branch in
`.playbackFailed`, mirroring `shouldTriggerSAMLReauthForPlaybackFailure`, that
yields FRESH signed URLs (not cached manifest replay), bounded to ONE attempt.

Critical-path (audiobook playback + OverDrive fulfillment). Toolkit-fragile —
cross-vendor smoke required.

## Claims

- Adds a boundary predicate
  `shouldTriggerOverdriveRefulfillForPlaybackFailure(error:book:alreadyAttempted:)`
  that returns true iff the book is OverDrive (distributor / `bearerTokenFulfillURL`)
  AND the error is a URL-EXPIRY signal — **the predicate is 410-ONLY: HTTP 410
  (Gone) = clean signed-URL expiry → re-fulfill; ALL 403s (ambiguous signed-URL
  expiry vs entitlement denial) and 401/loan-revoked fall through, NEVER
  re-fulfilled** — a false dead-end-shown is safer than retrying into a revoked
  loan — AND a re-fulfill has not already been attempted this playback session.
- Adds an OverDrive re-fulfill recovery branch in `.playbackFailed` PARALLEL to
  the SAML branch: re-fulfill to obtain FRESH signed URLs, then re-attempt the
  open; bounded to ONE attempt per book (reset on a fresh user-initiated open).
- Genuine/permanent failures (401 loan-revoked, cancelled, non-OverDrive) are NOT
  retried. Exhausted/failed re-fulfill surfaces the existing explicit error — no
  infinite loop.
- Re-fulfill yields fresh signed URLs that are actually CONSUMED by the re-opened
  player (not a cached-manifest replay) — pinned by a red-first test.

## Anti-claims

- Does NOT retry on permanent errors (401/loan-revoked/cancelled) or for
  non-OverDrive vendors.
- Does NOT loop: bounded to one attempt per book per session.
- Does NOT add new user-facing copy (reuses the existing playback-failed/error UX
  on exhaustion).
- Does NOT change the SAML-reauth branch or other vendors' playback paths.

## Open decision (reported to coordinator before implementation)

Cached-manifest-replay fork:
- (A) DURABLE: re-fulfill → overwrite the on-disk manifest with fresh signed URLs
  → re-open (subsequent opens stay fresh within the new TTL). Larger blast radius
  (MBDC fulfillment + manifest persistence).
- (B) SIMPLE: recovery re-open bypasses `LocalFileAdapter` (force a fresh
  BearerTokenAdapter fulfillment in-memory) → plays fresh now; on-disk manifest
  stays stale (re-fulfills again, bounded, on a later open). Smaller blast radius;
  lives in the session-manager recovery + a loader `forceRefulfill` flag.

## Files in scope (pending A/B)

- `Palace/Audiobooks/AudiobookSessionManager.swift` (the `.playbackFailed`
  recovery branch + predicate)
- (B) `Palace/Audiobooks/AudiobookLoader.swift` (a `forceRefulfill` open path that
  bypasses `LocalFileAdapter` for OverDrive) — OR (A) the MBDC fulfillment +
  manifest-persistence path.
- Tests: `PalaceTests/DRM/OverdriveFulfillmentTests.swift` +
  `AudiobookSessionManager` playback-failed tests.

---

# Follow-up (2026-07-15): recovery fires on AVPlayer -1008 (the real field shape)

branch: `fix/overdrive-expired-url-refulfill-minus1008`

## Context

The 410-only predicate above NEVER fired in the field. OverDrive streams tracks
through AVFoundation, which collapses the CDN's HTTP 410 (expired signed URL) into
`NSURLErrorDomain -1008` (NSURLErrorResourceUnavailable) with NO `httpStatusCode`, so
`httpStatusCode(from:error) == 410` is nil → the bounded re-fulfill never triggered.
Device repro captured on Moes Max (Mi historia / A1QA staging, 2026-07-15): expired
`links.contentlinks` → 410 → surfaced as -1008 → dead-ended to "A Problem Has Occurred",
and skip-across-tracks broke identically (each track's URL dead).

## Claims

- broadens `shouldTriggerOverdriveRefulfillForPlaybackFailure` to also return true on an
  `NSURLErrorResourceUnavailable` (-1008) signal, IN ADDITION TO the existing 410 path
- adds `static func isResourceUnavailable(from:)` matching -1008 in three shapes:
  top-level `NSURLErrorDomain`, the flattened `underlyingCode`/`underlyingDomain` userInfo
  scalars, and one level down the `NSUnderlyingError` chain
- adds unit tests in `OverdriveFulfillmentTests.swift` for the three recover shapes plus
  the negative/guard cases (offline -1009, timeout -1001, already-attempted bound,
  non-OverDrive distributor, non-URL-domain -1008, nil)

## Anti-claims

- does NOT touch `httpStatusCode(from:)`; the 410 path is byte-preserved
- does NOT broaden the SAML sibling to -1008 (a -1008 on a SAML book must not loop a
  revoked session)
- does NOT re-fulfill on -1009 (offline), -1001 (timeout), 401, or 403; the
  one-attempt-per-book-per-session bound is preserved
- does NOT add the proactive re-fulfill-on-open layer (deferred) and does NOT modify the
  `ios-audiobooktoolkit` submodule (app-side only)

## Files in scope

- `Palace/Audiobooks/AudiobookSessionManager.swift`
- `PalaceTests/DRM/OverdriveFulfillmentTests.swift`
