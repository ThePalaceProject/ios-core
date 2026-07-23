# Contract — DownloadCenterInfra (Wave 1, risk: critical_path)

## Goal
Add a deterministic download-dispatch join seam (S4) and make the progress
throttle injectable (S11) so tests never wall-clock-wait on
`MyBooksDownloadCenter`'s fire-and-forget `Task {}`s or the +0.5s progress
throttle. **Prod-only — no test files change here.** Fan-in: MyBooks, Book.

## Files in scope (edit ONLY these)
- `Palace/MyBooks/MyBooksDownloadCenter.swift`
- `Palace/MyBooks/DownloadProgressPublisher.swift`

## OFF-LIMITS
- Every `PalaceTests/**` file. Any other `Palace/**` — STOP and report if needed.

## Seams to add

### S4 — `MyBooksDownloadCenter._awaitDownloadDispatchForTesting() async`
The class already retains one handle (`lastNetworkLossFailureTask`, ~line 217)
and spawns many fire-and-forget `Task {}` (~lines 1197/1228/1290/1371/1419).
Generalize to an XCTest-gated `[Task<Void, Never>]` + grow-until-stable join,
identical in shape to S3 / `_awaitAuthDispatchForTesting`:
- Add the canonical gate `_isRunningUnderXCTest`.
- At each fire-and-forget `Task { … }` spawn site, when under XCTest, append the
  `Task` handle to a lock-guarded array (synchronous snapshot; NSLock never held
  across `await`).
- `func _awaitDownloadDispatchForTesting() async` drains the array in a
  re-snapshotting loop until empty. Bounded because each retained `Task` is the
  actual dispatched unit and completes.
- RELEASE spawns the identical `Task`s and never populates/reads the array.

### S11 — injectable throttle in `DownloadProgressPublisher`
The publisher broadcasts via `asyncAfter(+0.5s)` (an intrinsic throttle, NOT a
flake — do NOT delete it). Make the interval injectable so tests set it to 0:
- Add a stored `throttleInterval: TimeInterval` (or inject a scheduler),
  defaulting to the current 0.5s in the production initializer so behavior is
  byte-identical in RELEASE.
- Replace the hard-coded `0.5` in the `asyncAfter` with the stored interval.
- Do NOT remove the throttle; only make its interval configurable.

## Verification criteria (paste evidence)
1. `grep -n '_awaitDownloadDispatchForTesting\|_isRunningUnderXCTest' Palace/MyBooks/MyBooksDownloadCenter.swift`.
2. **XCTest gate proven:** each handle append is guarded by `_isRunningUnderXCTest`.
3. **Bounded join:** grow-until-stable over retained `Task.value`; no bare
   never-resuming `await`, no `sleep`/poll on added lines.
4. **Throttle preserved, not deleted:** `grep -n 'throttleInterval\|asyncAfter' Palace/MyBooks/DownloadProgressPublisher.swift` shows the asyncAfter still present, now driven by the injectable interval; the production default is still 0.5s (`grep` the initializer default).
5. **No RELEASE timing change:** the default initializer path is unchanged; the array is only populated under XCTest.
6. Build compiles (CI-gated; state honestly if unavailable).

## Notes
- Canonical reference: `TokenRefreshInterceptor.spawnAuthDispatch` +
  `_awaitAuthDispatchForTesting`. This is critical-path (borrow/download) — a
  broken seam corrupts download completion under CI. Be conservative.
- No tests here. Transcript →
  `.forgeos/swarms/swarm_ad0b4c65/transcripts/DownloadCenterInfra.md`. Do NOT commit.
