# Contract: DownloadThrottlingVerify  [CRITICAL PATH — verify-first]  (root cause A victim)

## Root cause (victim of pool starvation — cause A)
DownloadThrottlingServiceTests.testPauseAllDownloads_suspendsAllNonAudiobookTasks flakes because
`pauseAllDownloads()` (`DownloadThrottlingService.swift` ~114-118) is fire-and-forget
`Task { await self?.pauseAllDownloadsAsync() }` hopping to an actor; the test polls with a timeout
that the starved cooperative pool (leaked awaitReady tasks — see AccountStateStore-Isolation) blows.

## Required fix — VERIFY-FIRST, minimal touch
1. After AccountStateStore-Isolation lands, run testPauseAllDownloads in the FULL suite under
   `-test-timeouts-enabled YES`. If it now passes consistently (expected — same starvation source),
   this contract is satisfied with ZERO production change. Paste the green tail.
2. ONLY IF it still flakes: convert the fire-and-forget paths to expose an awaitable/structured
   completion the test can deterministically await, without changing observable suspend/resume
   behavior. Critical-path: SoD review + mutation ≥50%.
DO NOT add Task.sleep, raise the poll timeout, or XCTSkip.

## Files in scope
- `Palace/MyBooks/DownloadThrottlingService.swift`  (ONLY if step 1 fails)
OFF-LIMITS: all other MyBooks/Download* files.

## Verification criteria (grep-able)
- Preferred: `git diff origin/develop -- Palace/MyBooks/DownloadThrottlingService.swift` EMPTY and the
  test passes in the full suite (cite AccountStateStore-Isolation as the cause).
- No XCTSkip / no raised timeout / no Task.sleep in the test.
- If production IS touched: mutation kill-rate + SoD review evidence pasted.
- FULL-suite green tail under `-test-timeouts-enabled YES`.
