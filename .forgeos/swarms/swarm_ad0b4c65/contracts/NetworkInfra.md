# Contract — NetworkInfra (Wave 1, risk: critical_path)

## Goal
Add a deterministic test-join seam so tests never wall-clock-wait on
`TPPNetworkExecutor`/`TPPNetworkResponder` completions that fire off the URLSession
`delegateQueue`. **Prod-only — no test files change here.** Fan-in: Network,
MyBooks downloads, Book, SignInLogic token refresh.

## Files in scope (edit ONLY these)
- `Palace/Network/TPPNetworkExecutor.swift`
- `Palace/Network/TPPNetworkResponder.swift`

## OFF-LIMITS
- Every `PalaceTests/**` file. Any other `Palace/**` file — STOP and report if needed.

## Seam to add

### S3 — `TPPNetworkExecutor._awaitInFlightForTesting() async`
The responder dispatches completion handlers off the session `delegateQueue`
(fire-and-forget relative to the caller). Extend the existing test-seam infra on
this class (`claimTokenRefreshSlotForTesting`/`currentTokenRefreshGenerationForTesting`,
~lines 280-283) with an XCTest-gated retained-handle join, mirroring
`TokenRefreshInterceptor._awaitAuthDispatchForTesting` (grow-until-stable loop):
- Add, guarded by the canonical gate:
  ```swift
  private static let _isRunningUnderXCTest =
      ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
  ```
- Where the responder/executor spawns each completion-dispatch `Task {}` (or
  `delegateQueue.async {}`), when `_isRunningUnderXCTest`, ALSO retain the unit
  of work as a `Task<Void, Never>` handle appended to an internal, lock-guarded
  `[Task<Void, Never>]`. Snapshot the array **synchronously** under an `NSLock`
  (NSLock across a suspension is a Swift 6 error), then `await` the handles in
  the caller, re-snapshotting until the set stops growing (mirror
  `_awaitAuthDispatchForTesting`, lines ~526-575 of TokenRefreshInterceptor).
  ```swift
  func _awaitInFlightForTesting() async {
      while true {
          let handles: [Task<Void, Never>] = { lock.lock(); defer { lock.unlock() }; let s = pendingTestTasks; pendingTestTasks.removeAll(); return s }()
          if handles.isEmpty { break }
          for h in handles { await h.value }
      }
  }
  ```
- If completions currently run via `delegateQueue.async` (not a `Task`), wrap the
  work so a retained `Task` awaits the same completion, OR bridge the queue hop
  via `await withCheckedContinuation { c in delegateQueue.async { …; c.resume() } }`.
  The REQUIREMENT: the seam resolves exactly when all in-flight completions have
  run. Do NOT change production timing when NOT under XCTest — RELEASE must spawn
  the identical work and never populate/read the array.

## Verification criteria (paste evidence)
1. `grep -n '_awaitInFlightForTesting\|_isRunningUnderXCTest\|pendingTestTasks' Palace/Network/TPPNetworkExecutor.swift Palace/Network/TPPNetworkResponder.swift`.
2. **XCTest gate proven:** every retain of a handle is inside an
   `if …_isRunningUnderXCTest` (or equivalent) guard — grep shows the guard
   wraps the append. RELEASE never appends.
3. **Bounded join:** the seam awaits retained `Task.value` handles in a
   grow-until-stable loop; NO bare `await` on a handle that could never resume,
   NO `sleep`/`Date()`/poll on the added lines.
4. **NSLock not held across `await`:** the snapshot is a synchronous closure;
   grep the seam to confirm no `lock()` spans an `await`.
5. Build compiles (CI-gated; state honestly if local build unavailable).

## Notes
- Canonical reference to copy: `Palace/MyBooks/TokenRefreshInterceptor.swift`
  `spawnAuthDispatch` (retain site) + `_awaitAuthDispatchForTesting` (join).
- No tests in this contract. Transcript →
  `.forgeos/swarms/swarm_ad0b4c65/transcripts/NetworkInfra.md`. Do NOT commit.
