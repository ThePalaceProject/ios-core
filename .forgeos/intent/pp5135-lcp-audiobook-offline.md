---
name: pp5135-lcp-audiobook-offline
created: 2026-09-15
author: Maurice Carrier
branch: fix/PP-5135-lcp-audiobook-offline
priority: PP-5135 / 3.3.0 release blocker (critical-path)
supersedes: lcp-open-latency-492.md (Claim B — see "Relationship to prior intent")
---

# Intent: a downloaded LCP audiobook must have its audio on the device, and offline must not read as signed-out

## Context

QA on TestFlight 3.3.0 (502): a fully downloaded audiobook will not play offline.
Reproduced on device against A1QA Test Library and Main Street City Library.

Two independent defects sit on that path. Both were found by instrumenting the
open path on a device and reading `Documents/Logs/palace_error.log`, not by
reasoning about the code.

**1. The `.lcpa` audio is never fetched.** PP-4957 shipped streaming-from-license
behind a remote flag that is ON at 100%. Its premise — a streaming LCP audiobook
is "intentionally content-absent" because the license alone makes it playable —
holds only while online, and FOUR sites encoded it, so nothing ever fetched the
archive. The shelf said Downloaded, the book played on wifi, and offline it could
not be opened at all. Measured on 502: every borrowed LCP audiobook held its
2–3 KB `.lcpl` and NOT ONE `.lcpa`; the open routed past `LocalFileAdapter` to
`LCPAdapter` and dead-ended in `ReadiumStreamer.PublicationOpenError`.

**2. Offline was reported to the patron as "please sign in".**
`isUserAuthenticated()` gates on `Account.awaitReady()`, which resolves the
`authentication_document`. Offline that fetch cannot complete, the account parks
at `.detailsFailed`, and the gate returned false. Device log, airplane mode,
build 505: three `Authentication Document request failed to load Code=700`, then
SEVEN consecutive `Validation failed: notAuthenticated`. Every tap refused until
a relaunch on wifi. Not a race — total, while the account cannot resolve.

## Relationship to prior intent (supersedes `lcp-open-latency-492.md`, Claim B)

Claim B of the 3.2.3/492 intent reads: *"An LCP audiobook stays `.downloading`
until its `.lcpa` is on disk … 'Listen' is not offered for a book with no
audio."* PP-4957 later inverted that for the streaming flag — a license-only book
IS marked successful and Listen IS offered — and this change does not restore
Claim B. It adopts the half of it that matters and drops the half that fights
streaming:

- **Kept:** a book the shelf calls Downloaded must have its audio on the device.
- **Dropped:** the requirement that it stay `.downloading` until the archive
  lands. Playback starts immediately on the license and the archive arrives
  behind it, so the patron never waits on a multi-gigabyte transfer to press
  play.

That is the reconciliation the 492 intent never got, and its absence is why four
sites drifted apart.

## Claims

- **A.** After an LCP audiobook is fulfilled and marked downloaded, the `.lcpa`
  is fetched in the background, so the book can be opened offline. Triggered from
  `MyBooksDownloadCenter.startLCPContentFetchIfNeeded`, called from the
  download-completion path AFTER `bookIdentifierToDownloadInfo.remove`.
- **B.** The placement in Claim A is load-bearing and is pinned by test. Before
  that removal, `downloadCenterHasTransfer` is still true and
  `redownloadLCPContentFile` returns at its duplicate-suppression guard, fetching
  nothing. An earlier revision did exactly that and was inert for every fresh
  borrow.
- **C.** A readiness failure that cannot be resolved offline no longer surfaces
  as "not authenticated" when the patron has stored credentials for that library.
  The decision is the pure `offlineAuthFallback(error:hasStoredCredentials:)`.
- **D.** `.evicted` is excluded from C. A library switch is not an offline
  condition, and the credential lookup is scoped to the library uuid captured
  BEFORE the await, so a switch cannot answer with another library's credentials.
- **E.** Neither trigger site starts a transfer against `downloadOnlyOnWiFi`.

## Anti-claims

- **Does NOT restore Claim B of the 492 intent.** A license-only book still shows
  Listen and still streams; the archive lands behind it.
- **Does NOT change `contentPresence`.** The load-time reconciliation state table
  is untouched, so the `BookRegistrySync` self-heal stays dormant while streaming
  is ON. Consequence accepted and stated: the archive lands via the completion
  path for a new borrow, or the open gate for a book borrowed before this fix.
- **Does NOT add a retry.** A background fetch that starts and FAILS (observed on
  device: "The network connection was lost.") leaves the book
  `.downloadSuccessful` with no `.lcpa`, and only a later online, wifi-allowed
  open re-arms it. Same for a borrow made on cellular with the wifi-only
  preference set. Narrower populations of the same symptom; a retry policy is a
  larger change than a release fix should carry.
- **Does NOT bump the build number.** The branch inherits 504 from the base.
- **Claim C IS covered end to end.** An earlier revision of this intent asserted
  the opposite — that no test in this target could populate `currentAccount`, so
  only the pure decision could be covered. That was FALSE.
  `AccountsManager._seedAccountForTesting` exists, nine suites use it, and
  `CredentialSnapshotInvalidationTests` already seeds an account, parks a
  terminal state and sets per-uuid credentials. Three fixture attempts failed and
  the conclusion generalised from those failures to impossibility instead of
  searching for the seam. Corrected: three wiring tests now drive
  `isUserAuthenticated()` itself (offline+credentials, offline+none, evicted),
  and the pure decision is enumerated over the whole error x credentials table
  rather than sampled.

## Files in scope

- `Palace/MyBooks/MyBooksDownloadCenter.swift` — the completion-path trigger
- `Palace/MyBooks/LocalBookContentService.swift` — self-heal un-gated; wifi policy
- `Palace/Audiobooks/AudiobookSessionManager.swift` — open gate; offline auth fallback
- `PalaceTests/MyBooks/LocalBookContentServiceTests.swift`
- `PalaceTests/Audiobook/AudiobookContentGateTests.swift`
- `PalaceTests/Audiobooks/AudiobookPositionRestoreTests.swift`
- `docs/architecture/account-state-machine.md`, `readium-money-path-validation.md`

## Verification plan

- Scoped suites green: `AudiobookContentGateTests`, `AudiobookPositionRestoreTests`,
  `LocalBookContentServiceTests`. Counts move as tests are added; the run output
  is the record, not a number frozen here.
- Full suite (8798 tests, 14 skipped, 0 failures, no timeouts) measured at
  `da014757e`. Production code is byte-identical since; the tests added after it
  have only run scoped. CI settles that.
- Both guards proven by REINTRODUCING the defect, not by asserting green:
  - deleting the `.evicted` narrowing fails three tests, including the end-to-end
    `testIsUserAuthenticated_evictedByLibrarySwitch_isNotAuthenticated`;
  - deleting the WiFi guard in `startLCPContentFetchIfNeeded` fails
    `testDownloadCentreFetch_whenNotOnWiFiAndWiFiOnlySet_doesNotFetch`.
- Claim E is verified at BOTH trigger sites: the DownloadCentre twin above and
  `testGate_streamingEnabled_wifiOnlyPreferenceSet_doesNotFetchButStillProceeds`.
  Review found this hole twice, mirrored — fixing one site left the other
  asserted-but-unverified.
- Device (release owner, build 504/505): a 1.18 GB `.lcpa` lands for a freshly
  borrowed title where 502 had zero, and offline playback works.
- Mutation over the changed files is OWED once the full suite runs in CI.
