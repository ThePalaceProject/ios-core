# Blast-Radius Review — LCP audiobook streaming-from-license (PP-4957)

Role: blast_radius (universal floor)  ·  Verdict: **BLOCKED**
Branch: feat/pp-lcp-streaming-579-fork  ·  Base: origin/develop
Critical path: DRM/LCP audiobook fulfillment

## Scope reviewed
Uncommitted working-tree changeset (13 files) adding a Firebase-gated flag
`lcp_audiobook_streaming_enabled` (default OFF) that makes an LCP audiobook
playable on its `.lcpl` license alone, skipping the `.lcpa` download.

## Verdict rationale
Production at flag-default-OFF is unaffected (every new branch is behind
`if streamingEnabled`). BLOCK is on the **flag-ON path**, which is broken by a
reconcile state downgrade that is remotely enable-able via Firebase without a
build.

---

## BLOCKING

### F1 (concern · side-effect scope) — reconcile downgrades a streaming book `.downloadSuccessful` → `.downloadNeeded` on every registry load
The streaming short-circuit in `LCPFulfillmentHandler.fulfill`
(LCPFulfillmentHandler.swift:119-140) sets state `.downloadSuccessful`, copies
the `.lcpl` to the content dir, and returns — no `.lcpa` on disk.

On the next `BookRegistrySync.load()` (cold launch, CarPlay bootstrap,
`HoldsViewModel` no-auth hold change, account change):
- `contentPresence` (MyBooksDownloadCenter+RegistryDownloadServicing.swift:86-92)
  finds `.lcpl` but no `.lcpa` → returns `.licenseOnly`.
- `armDecision` (BookRegistrySync.swift:1007-1012 `.downloadSuccessful` arm; also
  :1014-1019 `.used` arm) maps `.licenseOnly` → `decision(.downloadNeeded, content: true)`.
- `load` applies it (BookRegistrySync.swift:321) and schedules a content
  re-download (:322-324).

The re-download call itself is guarded — routes through
`MyBooksDownloadCenter.redownloadLCPContentFile` → `LocalBookContentService.redownloadLCPContentFile`,
which the diff short-circuits when streaming is ON (LocalBookContentService.swift:345-351)
— so the `.lcpa` is NOT re-fetched. **But the STATE FLIP is not guarded.** The guard
was placed at the terminal download seam only; the reconcile state machine
(`armDecision` / `contentPresence`) is not streaming-aware.

Impact (flag ON): every streaming audiobook reverts to `.downloadNeeded` after any
load → My Books shows a "Download" affordance instead of "Listen" for a book that
is supposed to be immediately playable, and logs
`'…' has a license but no .lcpa content — scheduling content re-download` on every
launch, burning a scheduled-redownload timer slot each time. The feature does not
survive its own reconcile pass.

No test covers this interaction. Added tests pin the local guards
(LCPFulfillmentHandlerTests, LocalBookContentServiceTests) but none exercise
`BookRegistrySync.reconcile` with a streaming book — the classic producer-vs-helper gap.

**Recommendation:** make `reconcile`/`contentPresence` streaming-aware. When the
flag is ON and the book is an LCP audiobook whose license is present, treat
`.licenseOnly` as terminal-healthy: do not downgrade `.downloadSuccessful`/`.used`,
do not schedule a content re-download. Add a BookRegistry reconciliation-table
case for the streaming dimension (the table tests are the right home — this is a
new (state × presence) meaning, not a scenario).

---

## WARNING

### F2 (warning · side-effect scope) — failed license copy routes to an UNGUARDED full download
`copyLicenseForStreaming` swallows a copy failure (LCPFulfillmentHandler.swift:352-361,
`catch` logs only), yet the streaming path still calls `markDownloadSuccessful`
and returns. If the `.lcpl` copy failed, `contentPresence` = `.absent` →
reconcile `.downloadSuccessful` + `.absent` → `decision(.downloadNeeded, orphan: true)`
→ `downloadService.startDownload(for:)` (BookRegistrySync.swift:418), which is NOT
streaming-guarded → a full fresh fulfillment kicks off. Rare, but a real unguarded
path in the ON state.
**Recommendation:** on copy failure in the streaming path, do not mark successful —
fall through to download-first so state stays coherent.

### F3 (warning · adjacency-staleness) — stale base; work uncommitted
Branch HEAD (b4365d10a) is 1 commit behind `origin/develop` (missing c3b799dae,
the Adobe single-flight DRM fix PP-4952). `git diff origin/develop` therefore shows
large unrelated DELETIONS (AdobeActivationCoordinator, AdobeCertificate, CLAUDE.md,
palace_mutate.py, .forgeos intent + Adobe tests) — a **stale-base artifact, not part
of the changeset**. The LCP streaming work is also entirely uncommitted working-tree
changes. Consequence: the 5 universal scripts all exited 0, but they evaluate the
committed delta (empty here) — their clean result is low-signal for this changeset.
**Recommendation:** rebase onto the develop tip, commit, and re-run this review on
the committed diff.

---

## PASS (deliberate, confirmed clean)

### P1 (surface/abi) — signature changes are additive and safe
- `AudiobookSessionManager` designated init is `private`; only the convenience
  init calls it and was updated; convenience `lcpStreamingEnabledProvider` is
  defaulted (reads `RemoteFeatureFlags.shared`). AppContainer + all test callers
  use the convenience init → compile clean. `AudiobookSessionManager` is `public`
  but its init is private → no public ABI change.
- `shouldTriggerContentDownloadBeforeOpen` new non-defaulted `streamingEnabled`:
  all 6 test call sites in AudiobookContentGateTests updated; the single prod call
  passes `lcpStreamingEnabledProvider()`. No missed site.
- `LCPFulfillmentHandler.init` / `LocalBookContentService.init` new params are
  defaulted (trailing/mid with labels) → existing callers unaffected. All types
  `internal final` → no ABI surface.

### P2 (surface) — flag wiring correct and auto-OFF
- `PalaceFeatureFlag.lcpAudiobookStreamingEnabled` falls through `default: return false`
  in `defaultValue` → auto-OFF.
- FirebaseManager: `RemoteConfigKey` case + `setDefaults` NSNumber(false) added.
- `managerKey` mapping: explicit case added (both PalaceFeatureFlag switches retain
  `default:` arms → no exhaustiveness break anywhere).
- `RemoteFeatureFlags.isLCPAudiobookStreamingEnabled` + local-override key + the
  DeveloperSettings toggle mirror existing patterns with matching keys.
- Default-OFF ⇒ zero production behavior change; all new logic behind `if streamingEnabled`.

### P3 (test_seam / debug_reachability) — none found
No `#if DEBUG` reachability, no test-only symbol promoted to public, no static
factory bypassing an injection seam. Injection is via defaulted closures reading
`RemoteFeatureFlags.shared` in production and overridable in tests — the documented pattern.

## Script evidence
check-contract-reconciliation / check-blast-radius / check-adjacency-staleness /
check-intent-recorded / check-superpartner-spectrum → all exit 0 (low signal: work
is uncommitted; scripts see an empty committed delta — see F3).
