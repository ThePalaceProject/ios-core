# Module A — Audiobook (CI-flake migration)

## Files in scope (5)

| Path | FLAKE-001 (sleep) | FLAKE-002 (asyncAfter+fulfill) | FLAKE-003 (≥15s) |
|------|------------------|--------------------------------|------------------|
| PalaceTests/Audiobook/AudiobookBookmarkBusinessLogicTests.swift | — | L452 | — |
| PalaceTests/Audiobook/AudiobookDataManagerSyncTests.swift | — | L96 | L274, L523, L533 (each 10s — verify by re-running linter; only ≥15s blocks) |
| PalaceTests/Audiobook/AudiobookLoaderTests.swift | — | — | L63 (10s — same caveat) |
| PalaceTests/Audiobooks/NowPlayingCoordinatorTests.swift | — | L344 | — |
| PalaceTests/Audiobooks/NowPlayingCoordinatorBackgroundTests.swift | — | L133 | — |

Authoritative violation list: `python3 scripts/lint-test-quality.py --per-file --file <path>` for each file. Only fix what the linter flags.

## Migration patterns

Use `XCTestCase+drainMainQueue` helpers already in `PalaceTests/XCTestCase+drainMainQueue.swift`:
- Main-queue work: `drainMainQueue()`.
- Task-based async: `awaitCondition(timeout: 5) { <predicate> }` or `await awaitConditionAsync(timeout: 5) { ... }`.

`Thread.sleep` / `usleep`: replace with an `XCTestExpectation` driven by the real production signal (Combine sink, delegate callback, Notification), OR `awaitCondition` polling the actual state.

Timeouts ≥15s: drop to ≤5s once the asyncAfter migration removes the need. If a long timeout is genuinely needed (real audiobook decoder warmup, etc.), add `// FLAKE-003-OK: <reason>` on the same line.

## Out of scope

- `Palace/Audiobooks/*` — production code is **read-only**.
- Adding new tests for coverage.
- SHALLOW-001 / FLUFF-001-003 cleanup in these files (separate Phase 4).
- AudiobookSessionManager singleton refactor (Phase 2).

## Verification before reporting done

1. For each file in scope:
   ```bash
   python3 scripts/lint-test-quality.py --per-file --file PalaceTests/Audiobook/<file>.swift \
     | grep -cE ':(FLAKE|MISSING|FLUFF|TIMEOUT)-'
   ```
   Returns 0 (or only counted MISSING/FLAKE-OK-suppressed lines).

2. Each migrated test class still passes:
   ```bash
   xcodebuild test -project Palace.xcodeproj -scheme Palace \
     -destination "id=$HARNESS_SESSION_SIM_UDID" \
     -only-testing:PalaceTests/<TestClassName>
   ```

3. Write `.forgeos/swarms/swarm_9d3d2fab/transcripts/module-a-audiobook.md` with: files modified, key migration decisions, any FLAKE-003-OK additions with the documented reason, any gaps.

Do NOT commit. Do NOT push. Leave changes staged.
