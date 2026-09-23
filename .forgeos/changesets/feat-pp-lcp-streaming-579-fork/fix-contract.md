# Fix-contract — Feature-flagged LCP audiobook streaming-from-license (PP-4957)

## Summary
Restore LCP audiobook streaming (broken since 3.2.0's Readium bump, upstream #579) behind a
Firebase-gated feature flag, **default OFF**. Flag OFF = today's download-first behavior, byte-for-byte.
Flag ON = the book becomes playable on the license alone and the player streams via the pinned
`swift-toolkit 3.11.0 + fix-issue-579` fork. One flag flips all three download-vs-stream decision
points coherently.

## Scope (in)
- `Palace/Packages/PalaceFeatureFlags/.../PalaceFeatureFlag.swift` — add case
  `lcpAudiobookStreamingEnabled = "lcp_audiobook_streaming_enabled"` (defaultValue auto-false via
  the existing `default:` arm).
- `Palace/AppInfrastructure/FirebaseManager.swift` — add `RemoteConfigKey.lcpAudiobookStreamingEnabled`
  + register `false` in `setDefaults`.
- `Palace/FeatureFlags/RemoteFeatureFlags.swift` — add `lcpAudiobookStreamingLocalOverrideKey`,
  `isLCPAudiobookStreamingEnabled` accessor (override > remote, default false), and the `managerKey` arm.
  Mirrors `isInAppPlaybackNavEnabled` exactly.
- `Palace/MyBooks/LCPFulfillmentHandler.swift` — inject `streamingEnabledProvider: () -> Bool`
  (default `{ RemoteFeatureFlags.shared.isLCPAudiobookStreamingEnabled }`). In `fulfillLCPLicense`,
  **before** the `lcpService.fulfill(...)` content download, add an early branch:
  `if streamingEnabledProvider() && book.defaultBookContentType == .audiobook` →
  set fulfillmentId, `copyLicenseForStreaming(...)`, `delegate?.markDownloadSuccessful(for:)`,
  broadcastUpdate, `return` (NO content download, NO transfer registration, NO active cue).
- `Palace/Audiobooks/AudiobookSessionManager.swift` — `shouldTriggerContentDownloadBeforeOpen`
  gains a `streamingEnabled: Bool` param; returns `false` when `streamingEnabled` (proceed → stream).
  Remove SPIKE #1 (hardcoded `return false`) and SPIKE #2 (no-op `lcpContentDownloadTrigger` default);
  the caller `gateOnLCPContentDownload` passes the flag. SPIKE #2's trigger never fires when
  shouldTrigger=false, so the default closure is restored to original.
- `Palace/MyBooks/LocalBookContentService.swift` — replace SPIKE #3 (hardcoded early return) with a
  flag-gated skip: `if streamingEnabledProvider() && LCPAudiobooks.canOpenBook(book) { return }`
  (self-heal must not re-download content for a streaming audiobook).

## Scope (out)
- **Do NOT flip the flag default to true** — that is David's product call (ticket-deferred).
- Readium fork pins — already set; the final mergeable step repins from local `file://` to
  `mauricecarrier7/swift-toolkit` by exact revision. No logic change.
- PDF LCP path (line 234) — untouched; streaming branch is `.audiobook`-only.
- `lcpCompletion` error/replace guards — untouched (unreachable on the streaming path, which returns early).

## Known traps (from docs/architecture/areas/mybooks/verification-checklist.md)
- **Cross-host token scoping (BiblioBoard):** streaming issues HTTP range requests to the license's
  content URL (often a distributor CDN ≠ manifest host). Auth must be scoped to CM-authorized hosts.
  → Manual sim verify must confirm streaming actually serves bytes (not a 403). This is the #579 path.
- **Marketplace LCP MIME-nesting:** `LCPAudiobooks.canOpenBook` is the recursive predicate the
  streaming branch relies on to identify an LCP audiobook — reuse it, do not re-derive.

## Verification criteria (grep-able before done)
- `grep -c "SPIKE(PP-4957)" Palace/**/*.swift` == 0 (all three spikes removed).
- `grep -c "isLCPAudiobookStreamingEnabled" Palace/FeatureFlags/RemoteFeatureFlags.swift` >= 1
- `grep -c "streamingEnabledProvider" Palace/MyBooks/LCPFulfillmentHandler.swift` >= 2
- New flag registered in BOTH tables: `PalaceFeatureFlag` (contract) AND `FirebaseManager.setDefaults`.
- `LCPFulfillmentHandlerTests` covers BOTH flag states (see Tests).
- Mutation kill on the changed `LCPFulfillmentHandler` streaming branch (diff-only) >= 80%.
- `scripts/verify-pr.sh --quick` PASS.

## Tests required (TDD)
- `LCPFulfillmentHandlerTests`:
  - flag OFF, audiobook → `lcpService.fulfill` IS called; NO early markDownloadSuccessful; behavior == today.
  - flag ON, audiobook → early branch: `markDownloadSuccessful` called, `copyLicenseForStreaming` invoked,
    `lcpService.fulfill` NOT called, no content-transfer registered. (Spy the LCP service + delegate.)
  - flag ON, **PDF** → NOT streamed (fulfill still called) — proves the branch is audiobook-only.
- `AudiobookSessionManager` gate: `shouldTriggerContentDownloadBeforeOpen(streamingEnabled: true, ...)` == false
  for the case that returns true when `streamingEnabled: false` (the canOpen && !contentLocal case).
- `LocalBookContentService`: flag ON + LCP audiobook → `redownloadLCPContentFile` no-ops (no fulfiller call).
- Contract-snapshot the flag-ON fulfillment call order if it fits (setFulfillmentId → copyLicense → markSuccessful).

## Acceptance
- All verification criteria pass; full suite green against the fork (baseline 8248/0).
- Manual sim (iPhone Air / A1QA / Palace Marketplace LCP audiobook):
  - flag ON → borrow → book goes straight to **Listen** → plays with `.lcpa` staying **0 bytes** on disk (streaming).
  - flag OFF → download-first unchanged (full `.lcpa` lands, then Listen).
- Prove-the-guard: with flag ON, deleting the guard branch must fail a named test (mutation).
