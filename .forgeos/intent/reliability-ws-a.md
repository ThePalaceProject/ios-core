---
name: reliability-ws-a
created: 2026-07-07
author: claude-opus-4-8
type: feature
tracking: Bulletproof Ownership — Reliability Initiative, Workstream A (Durable Downloads). Contract .forgeos/reliability-plan.md §2.WS-A, seam S1, INV-4/6/7.
related_prs: []
---

# Intent: Reliability WS-A — Durable Downloads

## Claims
- NEW `Palace/MyBooks/DownloadTaskPersistence.swift`: `PersistedDownloadRecord`
  (Codable/Sendable, seam S1), `ReconcileDecision` (adopt/restart/markFailed/
  cleanup), PURE `DownloadReconciliation.reconcile(persisted:liveTaskIdentifiers:
  registryStates:)`, and `DownloadTaskPersistence` durable JSON store in
  Application Support (own file, NOT the registry file), NSLock-guarded,
  injectable URL.
- `MyBooksDownloadCenter`: static `backgroundSessionIdentifier` (single source of
  truth for the 3 inline literals); stored `backgroundCompletionHandler` +
  `setBackgroundCompletionHandler`; `urlSessionDidFinishEvents(forBackground
  URLSession:)` invoking+clearing once on main (INV-7); persistence write on task
  start + removal on terminal completion; guarded `reconcileDownloadsAtLaunch()`
  (runs after registry load, getAllTasks -> pure reconcile -> apply); bounded
  transient-transfer retry in `handleTaskCompletionError`.
- `DownloadStateManager`: injectable `taskPersistence` + persist/remove/list;
  cleanup/reset drop persisted records.
- `DownloadErrorRecovery`: `RetryPolicy.downloadTransfer` (policy-use only, reuses
  NSURLError classifier).
- `TPPAppDelegate` bg handler: route download-center id -> MBDC; all other ids
  keep byte-for-byte audiobook route (INV-7).

## Anti-claims
- Does NOT edit MyBooksViewModel / BookReturnService / BookRegistrySync /
  OfflineQueueService.
- Does NOT touch Adobe/LCP DRM fulfillment (INV-6) — retry wraps plain content
  transfer only; no edits in `#if FEATURE_DRM_CONNECTOR` / `#if LCP` blocks.
- Does NOT change the audiobook route for non-download-center ids (INV-7).
- Does NOT reuse the registry persistence file. Does NOT stage ios-audiobooktoolkit.

## Deviation from seam S1 (documented)
Seam typed `registryStates` as `[String: TPPBookRegistry.RegistryState]`, but that
enum is the whole-registry load state (unloaded/loading/loaded/...), not per-book
lifecycle. INV-4 healing references per-book `.downloading`, so `reconcile` takes
`[String: TPPBookState]` — the semantically-correct per-book state. Flagged for
architect review.

## Files in scope
- Palace/MyBooks/DownloadTaskPersistence.swift (new)
- Palace/MyBooks/DownloadStateManager.swift
- Palace/MyBooks/MyBooksDownloadCenter.swift
- Palace/MyBooks/DownloadErrorRecovery.swift
- Palace/AppInfrastructure/TPPAppDelegate.swift (bg handler only)
- PalaceTests/MyBooks/{DownloadTaskPersistenceTests,DownloadReconciliationTests,DownloadReconciliationLaunchOrderContractTests,BackgroundSessionRoutingTests}.swift (new)
- PalaceTests/MyBooks/DownloadStateManagerTests.swift (extend)
