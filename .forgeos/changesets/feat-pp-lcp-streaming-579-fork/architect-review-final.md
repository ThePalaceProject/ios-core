# Architect SoD Review — LCP audiobook streaming-from-license (PP-4957)

**Verdict: BLOCKED**
Reviewer: architect-review (heka signed) · Branch: feat/pp-lcp-streaming-579-fork · Base: origin/develop
Changeset state: UNCOMMITTED working tree over HEAD b4365d10a (HEAD is behind origin/develop; the
real changeset is `git diff HEAD`, 13 files. `git diff origin/develop` is polluted by unrelated
develop divergence — Adobe-activation deletions, CLAUDE.md, palace_mutate — none of which are this change).

## What is correct
- **Flag-OFF invariance holds (verified).** All three new branches are guarded on
  `streamingEnabledProvider()`/`streamingEnabled` and fall through to byte-identical prior logic when
  false; the shared accessor defaults false (PalaceFeatureFlag `default:` arm + FirebaseManager
  `setDefaults` false + RemoteFeatureFlags override>remote>false). Production wires through the
  AppContainer convenience init (designated-init required param is defaulted there), no compile break.
- **Early-return placement is correct (Q2).** The streaming branch lands after the `.lcpl` rename but
  BEFORE `sendLCPContentDownloadActive(active:true)`, transfer registration, and `lcpService.fulfill`.
  It sets fulfillmentId, copies the license, marks successful, broadcasts, and returns with no transfer
  registered. `testFulfill_streamingEnabled_audiobook...` asserts fulfill count 0 + no active cue.
- **Seam-level tests are strong (Q4).** Each of the three seams has a flag-ON vs flag-OFF pair whose
  ON test fails if the branch is deleted (fulfill-count flip / gate-returns-true / re-fetch fires).
  The audiobook-vs-EPUB test pins the `.audiobook`-only condition. Good mutation posture on the seams.

## BLOCKERS

### 1. [architecture/correctness — FAIL] Flag-ON book is downgraded to `.downloadNeeded` on the next reconcile → not durably playable (Q3)
The streaming branch persists state `.downloadSuccessful` with only the `.lcpl` on disk (no `.lcpa`).
On the next `BookRegistrySync.load()` (fires on cold launch, foreground, account change):
- `MyBooksDownloadCenter+RegistryDownloadServicing.contentPresence` returns `.licenseOnly`
  (content file absent, license present) — file+RegistryDownloadServicing.swift:80-96.
- `BookRegistrySync.reconcile(entryState: .downloadSuccessful, presence: .licenseOnly, inFlight: false)`
  → `armDecision` `.downloadSuccessful`/`.licenseOnly` → `decision(.downloadNeeded, content: true)`
  — BookRegistrySync.swift:1007-1012.

Effect with flag ON: the book flips `.downloadSuccessful → .downloadNeeded` (loses "Listen", shows
"Download"), AND is queued for a background content re-download (schedulesContentRedownload) which the
new LocalBookContentService guard now no-ops — so it never heals and is stranded. This contradicts the
acceptance criterion "flag ON → book goes straight to Listen → plays" after the very first sync cycle.
The reconciliation table + the `lcpBooksNeedingBackgroundRedownload` scheduler are flag-blind consumers
of the new `(.downloadSuccessful, .licenseOnly)` producer and were not reconciled with the flag — the
exact "producer-not-helper / enumerate every state cell" wall-failure class.
**Recommendation:** make reconcile (and the background-redownload scheduler) streaming-aware so a
license-only LCP audiobook is treated as `.present`/playable when streaming is ON — OR have the
streaming path not depend on a state the reconciler downgrades. Add a reconciliation-table test cell
for `(.downloadSuccessful, .licenseOnly, streaming ON)` asserting the book stays playable and no
re-download is scheduled. No current test exercises a load()/reconcile cycle for a streaming book.

### 2. [dependency/risk — CONCERN] swift-toolkit pinned to a local `file://` path + rider transitive bumps
`project.pbxproj` / `Package.resolved` point swift-toolkit at
`file:///Users/mauricework/PalaceProject/readium-fork-579` (branch `fork/3.11.0-issue-579`). This cannot
build for anyone else or in CI. The fix-contract "Scope (out)" documents the final mergeable repin to a
GitHub fork by exact revision — acknowledged, but as-is the tree is unmergeable. The same resolve also
drags unrelated transitive bumps (nanopb, promises, swift-atomics, swift-protobuf 1.36→1.38,
swift-syntax 602→603, snapshot-testing, custom-dump, xctest-dynamic-overlay, std-uritemplate) that
recompile into every build regardless of flag state; these should be minimized/justified on the repin.
**Recommendation:** repin to the exact-revision GitHub fork and re-resolve to isolate only the toolkit
change before merge; confirm the transitive deltas are intended.

## Accepted follow-up (not blocking)
- **Q5 resource-loader over-fetch:** documented, flag defaults OFF; acceptable as a tracked follow-up
  rather than a merge blocker — provided Blocker 1 is fixed so flag-ON is actually shippable for QA.

## Summary
Flag-OFF is safe and the three seams are clean and well-tested, but the feature's own happy path
(flag ON) is not durable: the registry reconciler downgrades the streaming book to `.downloadNeeded`
on the next launch and the heal is gated off, stranding it. That is a correctness defect on a critical
DRM path, untested, and must be fixed (with a reconciliation-table test) before this is "done" — even
behind a default-OFF flag, because the dev/QA toggle exposes it immediately. Plus the local file://
toolkit pin blocks merge mechanically. BLOCKED.
