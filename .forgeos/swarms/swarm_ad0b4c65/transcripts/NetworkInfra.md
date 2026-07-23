# Transcript — NetworkInfra (Wave 1, critical_path)

Worked in worktree `swarm_ad0b4c65-network` on **develop** tip (fresh files, not
the stale 210-behind base). Build is CI-gated — no local build attempted.

## Seam added: S3 — `TPPNetworkExecutor._awaitInFlightForTesting()`

An XCTest-gated, retained-`Task`-handle, grow-until-stable join over the
fire-and-forget completion work the executor + responder spawn off the caller's
thread / URLSession delegate queue. Public seam lives on the executor; it joins
its own retained refresh/retry `Task`s, then delegates to the responder's own
drain join.

## Files changed (ONLY these two)

- `Palace/Network/TPPNetworkExecutor.swift`  (+64 / -3)
- `Palace/Network/TPPNetworkResponder.swift` (+63 / -0)

Everything else untouched. No test files touched (prod-only contract).

## How develop dispatches completions today (studied before adapting)

- **Terminal completion** `info.completion(result)` in
  `TPPNetworkResponder.urlSession(_:task:didCompleteWithError:)` runs
  **synchronously** on the URLSession delegate queue. **Left untouched** (per
  instruction / prior-attempt judgment) — it has already run by the time the
  delegate callback returns, so it needs no join.
- **Async completion fan-out** in `didBecomeInvalidWithError` fires the pending
  cancel-completions via `taskInfoQueue.async` (serial queue). This is the only
  responder site that fires completions asynchronously -> made joinable.
- **Executor fire-and-forget `Task {}`** at three sites: refresh orchestration
  (`refreshTokenAndResume`), nested retry-queue drain, and the token request
  (`executeTokenRefresh`). These are the executor's async completion chain ->
  made joinable.
- **Watchdog `Task`** in `scheduleTokenRefreshWatchdog` does `Task.sleep(75s)` ->
  **deliberately NOT retained** (joining it would be unbounded).

## Seam code

### Executor — retain sites (byte-identical spawn + gated append)
```swift
private static let _isRunningUnderXCTest =
    ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
private let pendingTestTasksLock = NSLock()
private var pendingTestTasks: [Task<Void, Never>] = []

private func retainForTesting(_ task: Task<Void, Never>) {
    guard Self._isRunningUnderXCTest else { return }   // RELEASE: no-op
    pendingTestTasksLock.lock()
    pendingTestTasks.append(task)
    pendingTestTasksLock.unlock()
}

private func _snapshotInFlightForTesting() -> [Task<Void, Never>] {
    pendingTestTasksLock.lock(); defer { pendingTestTasksLock.unlock() }
    return pendingTestTasks                            // synchronous — no await under lock
}

func _awaitInFlightForTesting() async {
    var awaited = 0
    while true {
        let tasks = _snapshotInFlightForTesting()      // re-snapshot each pass (grow-until-stable)
        if awaited >= tasks.count { break }
        for i in awaited..<tasks.count { _ = await tasks[i].value }
        awaited = tasks.count
    }
    await responder._awaitInFlightForTesting()         // then join responder-owned drains
}
```
Spawn sites changed from `Task { ... }` to `let x = Task { ... }` + `retainForTesting(x)`:
- `let refreshTask = Task { [weak self] in ... }`      -> `retainForTesting(refreshTask)`
- `let retryDrainTask = Task { ... }` (nested, inside `guard let self`) -> `self.retainForTesting(retryDrainTask)`
- `let tokenRequestTask = Task { ... }`                 -> `retainForTesting(tokenRequestTask)`

Grow-until-stable coverage: awaiting `refreshTask` runs the orchestration, which
(during its own execution, before its handle resolves) spawns+appends
`tokenRequestTask`, whose completion synchronously spawns+appends
`retryDrainTask`. Re-snapshotting picks each up. Watchdog never appended.

### Responder — serial-queue drain bridge (no non-Sendable capture)
`didBecomeInvalidWithError`'s existing `taskInfoQueue.async { ... }` block is left
**byte-identical**; after it, under XCTest only:
```swift
private func retainTaskInfoQueueDrainForTesting() {
    guard Self._isRunningUnderXCTest else { return }   // RELEASE: no Task, no append
    let task = Task {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.taskInfoQueue.async { continuation.resume() }   // serial -> runs AFTER real work
        }
    }
    pendingTestTasksLock.lock(); pendingTestTasks.append(task); pendingTestTasksLock.unlock()
}
```
Because `taskInfoQueue` is serial, the trailing continuation-resume cannot run
until the real completion work ahead of it drains — a precise join, not a
heuristic. The `Task` captures only the `Sendable` `CheckedContinuation` + `self`
(`@unchecked Sendable`), so the non-`Sendable` `error`/completion state never
crosses into it (avoids the Swift 6 diagnostic that kills the naive
"wrap-the-body-in-a-Task" approach).

## Verification evidence (grep — build is CI-gated)

1. Identifiers in BOTH files: `_awaitInFlightForTesting`, `_isRunningUnderXCTest`,
   `pendingTestTasks` present in each (grep confirmed).
2. XCTest gate proven: every `pendingTestTasks.append` is preceded by
   `guard Self._isRunningUnderXCTest else { return }` — executor via
   `retainForTesting`; responder via `retainTaskInfoQueueDrainForTesting` (guard
   gates BOTH the `Task` spawn and the append). RELEASE never appends and never
   spawns the drain `Task`.
3. Bounded join: both `_awaitInFlightForTesting` grow-until-stable over
   `await tasks[i].value`; no bare never-resuming await, no sleep/`Date()`/poll on
   added lines; sleeping watchdog `Task` never retained.
4. NSLock never across await: `_snapshotInFlightForTesting` is a synchronous
   `lock(); defer unlock(); return`; every `await ...value` is outside the lock.
   `grep 'lock()' | grep await` -> empty.
5. Braces balance (executor 164/164, responder 108/108). Production spawn closures
   byte-identical (diff = bind-to-`let` + gated `retainForTesting` call only).
   RELEASE path: static gate false -> no populate/read -> byte-identical production.

## Judgment calls
- Left the terminal synchronous `info.completion(result)` untouched (matches the
  prior good attempt): it's not an async hop, and it's done when the delegate
  callback returns.
- Did not join `didReceive data:` (buffers, fires no completion; serial-queue
  ordering already sequences it before `didCompleteWithError`'s `sync`).
- Did not touch the free-function coordinator dispatch in
  `handleExpiredTokenIfNeeded` (browser-auth path; fires no completion, no
  responder-instance access).
