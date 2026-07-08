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
