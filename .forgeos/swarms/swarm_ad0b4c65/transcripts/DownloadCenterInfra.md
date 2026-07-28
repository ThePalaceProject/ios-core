# Transcript — DownloadCenterInfra (Wave 1, critical_path)

Worked in worktree `swarm_ad0b4c65-download` on branch
`swarm/swarm_ad0b4c65-download` at develop tip (a3c9d1f31, "world-class PR report
contract" #1324). Implemented against develop's ACTUAL current files (a prior
attempt off a stale base was discarded). Build is CI-gated — not built locally.

## Files changed (ONLY these two — nothing else touched)
- `Palace/MyBooks/MyBooksDownloadCenter.swift` (S4 seam + 14 wrapped spawn sites)
- `Palace/MyBooks/DownloadProgressPublisher.swift` (S11 injectable throttle)

`git diff --stat`: 2 files, +108 / -27.

## S4 — `_awaitDownloadDispatchForTesting()` deterministic-join seam

Added the canonical XCTest-gated retained-Task-handle seam, byte-for-byte the
shape of `TokenRefreshInterceptor.spawnAuthDispatch` /
`_awaitAuthDispatchForTesting`:

```swift
private static let _isRunningUnderXCTest =
    ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

private let _downloadDispatchLock = NSLock()
private var _downloadDispatchTasks: [Task<Void, Never>] = []

@discardableResult
private func _trackDownloadDispatch(_ task: Task<Void, Never>) -> Task<Void, Never> {
    if Self._isRunningUnderXCTest {
        _downloadDispatchLock.lock()
        _downloadDispatchTasks.append(task)
        _downloadDispatchLock.unlock()
    }
    return task
}

private func _snapshotDownloadDispatchForTesting() -> [Task<Void, Never>] {
    _downloadDispatchLock.lock(); defer { _downloadDispatchLock.unlock() }
    return _downloadDispatchTasks
}

func _awaitDownloadDispatchForTesting() async {
    var awaited = 0
    while true {
        let tasks = _snapshotDownloadDispatchForTesting()
        if awaited >= tasks.count { break }
        for i in awaited..<tasks.count { _ = await tasks[i].value }
        awaited = tasks.count
    }
}
```

### Retention strategy — wrap-the-created-Task, not a creating helper
The class's fire-and-forget `Task {}`s have **heterogeneous isolation**
(`Task {}` inheriting nonisolated, `Task { @MainActor in }`, `Task { [weak self]
in }`). A single creating-helper (like `spawnAuthDispatch`, whose sites were all
uniform `@MainActor`) could NOT preserve every site's isolation. So
`_trackDownloadDispatch(_:)` takes the ALREADY-created `Task` and returns it
unchanged — each call site still writes its exact original `Task { … }` (same
isolation, same closure body, same timing); the only added token is the wrapping
`_trackDownloadDispatch( … )` call, whose sole effect under XCTest is the gated
append. RELEASE: the `if Self._isRunningUnderXCTest` gate is false, so the helper
just returns the task — array never populated, never awaited.

### All fire-and-forget spawn sites found + wrapped (14 total)
`grep -nE '\bTask[ ]*[({.]'` on develop's current file located these spawn sites
(the `Task.sleep`/`Task.isCancelled` inside existing async retry methods are NOT
spawns and were left untouched):

1. `failActiveDownloadsForNetworkLoss` — the pre-existing
   `lastNetworkLossFailureTask = Task { … }` (generalized: now
   `= _trackDownloadDispatch(Task { … })`, property assignment preserved).
2. `startDownload` → `startDownloadAsync`
3. `failWithWifiRequired` → `registerCompletion`
4. `logInvalidURLRequest` → `Task { @MainActor in SignInWebSheetPresenter.presentOnTop }`
5. `urlSession didWriteData` → `handleDownloadProgress`
6. `urlSession didFinishDownloadingTo` → `handleDownloadCompletion`
7. `urlSession willPerformHTTPRedirection` → `redirectPolicy.decide`
8. `urlSession didCompleteWithError` → `handleTaskCompletionError`
9. `addDownloadTask` → `registerStartedTask(task, …)`
10. device-failure logging → `Task { [weak self] in logDownloadFailure }`
11. `handleAdobeDownloadProgress` (`#if FEATURE_DRM_CONNECTOR`)
12. `reissueTransferDownloadTask` → `registerStartedTask(newTask, …)`
13. `scheduleReconcileDownloadsAtLaunch` (registry-loaded) → `reconcileDownloadsAtLaunch`
14. `scheduleReconcileDownloadsAtLaunch` (deferred `.sink`) → `reconcileDownloadsAtLaunch`

(Prior attempt reportedly found 11; the actual current-develop count of
fire-and-forget spawns is 14 — including the DRM-gated Adobe-progress site, both
reconcile paths, and the already-retained network-loss task.)

`grep -cE '_trackDownloadDispatch\(Task'` → **14**. Every remaining `Task {`
match in the file is inside a comment/docstring.

### Verification (contract §41)
- **V2 XCTest gate:** the ONLY append is `_downloadDispatchTasks.append(task)`
  inside `if Self._isRunningUnderXCTest { … }`. RELEASE never populates it.
- **V3 bounded join:** grow-until-stable `while` re-snapshotting until
  `awaited >= tasks.count`, awaiting each retained `Task.value`. Each retained
  Task is the actual dispatched unit and completes — no bare never-resuming
  await, no `sleep`/poll/`Date()` on any added line.
- **V5 no RELEASE timing change:** default init path unchanged; array only
  populated under XCTest; each `Task` created identically.

## S11 — injectable throttle in `DownloadProgressPublisher.swift`

The throttle lives in `DownloadProgressReporter.broadcastUpdateOnMain()` (the
file is named `DownloadProgressPublisher.swift` but the type is
`DownloadProgressReporter`). It coalesces bursts via
`DispatchQueue.main.asyncAfter(deadline: .now() + delay, …)`, where
`delay = minimumBroadcastInterval - timeSinceLastBroadcast` and
`minimumBroadcastInterval` was a hard-coded `0.5`.

Change (throttle PRESERVED — only its interval is now injectable):
```swift
let throttleInterval: TimeInterval            // new stored, immutable `let`

init(… , throttleInterval: TimeInterval = 0.5) {   // production default 0.5
    …
    self.throttleInterval = throttleInterval
}

// in broadcastUpdateOnMain():
let minimumBroadcastInterval = throttleInterval    // was: = 0.5
// DispatchQueue.main.asyncAfter(deadline: .now() + delay, …) UNCHANGED
```

`grep -n 'throttleInterval\|asyncAfter'`:
- `throttleInterval: TimeInterval` (stored) / `throttleInterval: TimeInterval = 0.5` (init default) / `self.throttleInterval = throttleInterval`
- `let minimumBroadcastInterval = throttleInterval`
- `DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)` — still present.

Production default is still **0.5s** → a default-constructed reporter is
byte-identical in RELEASE. All 10 existing `DownloadProgressReporter(…)` call
sites (Palace + PalaceTests) use labeled args and the new param is defaulted, so
none break.

## Bounded / conservative rationale
- No completion semantics altered: every wrapped `Task` is the exact original
  spawn; the wrapper only retains a handle under XCTest.
- No new sleeps/polls/deadlines; the join awaits real `Task.value`s.
- NSLock held only for the synchronous append/snapshot — never across `await`.
- Throttle behavior identical at the default; only the constant became a param.

Build: **CI-gated** — cannot build locally (fresh worktree lacks DRM/Carthage
frameworks). Grep-verified per contract. Did NOT commit/push.
