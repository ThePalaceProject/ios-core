---
name: swarm_9d3d2fab-transcript-module-b-mybooks
type: ephemeral
status: active
created: 2026-05-21
last_refresh: 2026-05-22
freshness_window: 180d
owners: [mybooks]
description: Module B — MyBooks (FLAKE migration + URLSession.shared sweep)
---

# Module B — MyBooks (FLAKE migration + URLSession.shared sweep)

Branch: `swarm/swarm_9d3d2fab-b-mybooks`
Worktree: `/Users/mauricework/PalaceProject/ios-core/.claude/worktrees/swarm_9d3d2fab-b-mybooks`
Scaffold parent: `40d3270e0`

## Scope delivered

### FLAKE migrations (4 sites across 4 files)

| File | Line | Violation | Migration |
|------|------|-----------|-----------|
| PalaceTests/MyBooks/MyBooksViewModelTests.swift | 428 | FLAKE-002 | `asyncAfter+fulfill` → `awaitCondition(timeout: 5.0) { viewModel.books.count == 1 }` polling the published `books` array. Removed the fixed-delay 1.5s sleep entirely. |
| PalaceTests/MyBooks/MyBooksViewModelTests.swift | 1607 | FLAKE-002 | `asyncAfter+fulfill` → `awaitCondition(timeout: 5.0) { viewModel.books.count == 1 && viewModel.showInstructionsLabel == false }`. Replaced the 2s sleep with a combined predicate that catches a regression in either signal. |
| PalaceTests/MyBooks/DownloadProgressPublisherTests.swift | 184 | FLAKE-002 | Throttle test — `asyncAfter+fulfill` → `awaitCondition(timeout: 5.0) { notificationCount >= 2 }`. Production throttle interval is 0.5s; we now poll until the trailing broadcast fires instead of sleeping for 1.5s. |
| PalaceTests/MyBooks/MyBooksDownloadCenterIntegrationTests.swift | 52 | FLAKE-001 | `Thread.sleep` on a URLProtocol-internal queue. Investigated: `MockURLProtocol.responseDelay` is never set by any test (only initialised to `0` and reset to `0`). The whole `if responseDelay > 0 { Thread.sleep }` block plus the `responseDelay` static var and its reset are dead code — removed all three. Pure-migration safe; no observable behavior change for any test. |

### URLSession.shared.downloadTask sweep (15 sites across 2 files)

The contract listed 16 sites; authoritative `grep -rn "URLSession.shared.downloadTask" PalaceTests/MyBooks/` returned 15 (the 2 BackgroundDownloadHandlerTests sites listed in the contract had already migrated to a local `inertTestSession` ephemeral URLSession in commit history before this branch).

| File | Sites | Pattern |
|------|-------|---------|
| PalaceTests/MyBooks/DownloadStateManagerTests.swift | 9 (L49, L67, L105, L126, L139, L140, L161, L244, L258) | `URLSession.shared.downloadTask(with: URL(string: "https://example.com[/N]")!)` → `fakeDownloadTask()`. L139/L140 (task1 + task2) — each `fakeDownloadTask()` invocation returns a fresh URLSessionDownloadTask with a unique `taskIdentifier`, so identity comparisons hold without distinct URLs. |
| PalaceTests/MyBooks/TokenRefreshInterceptorTests.swift | 6 (L137, L148, L166, L192, L386, L409) | Same — all 6 used the same `https://example.com` URL purely as a stand-in to construct a concrete `URLSessionDownloadTask` for the SUT. `fakeDownloadTask()` substitutes 1:1. |

All replacements use the default `fakeDownloadTask()` (no URL argument). The helper's default URL is `URL(filePath: "/dev/null/palace-fake-download-task")` — non-routable, no force-unwrap on the default value, and any accidental `.resume()` is blocked by `NoNetworkURLProtocol` rather than leaking to real HTTP.

### Out-of-scope items NOT touched

- `Palace/MyBooks/*` — production code unchanged (verified via `git diff --stat`).
- No new tests added (pure migration).
- SHALLOW-001 / FLUFF-001-003 in these files left as-is (Phase 4 follow-up per plan.md).

## Verification

### 1. Linter — 0 blocking violations on all 6 scoped files

```
=== PalaceTests/MyBooks/MyBooksViewModelTests.swift === (clean)
=== PalaceTests/MyBooks/DownloadProgressPublisherTests.swift === (clean)
=== PalaceTests/MyBooks/TokenRefreshInterceptorTests.swift === (clean)
=== PalaceTests/MyBooks/MyBooksDownloadCenterIntegrationTests.swift === (clean)
=== PalaceTests/MyBooks/DownloadStateManagerTests.swift === (clean)
=== PalaceTests/MyBooks/BackgroundDownloadHandlerTests.swift === (clean)
```

Command: `python3 scripts/lint-test-quality.py --per-file --file <path> | grep -E ':(FLAKE|MISSING|FLUFF|TIMEOUT)-'`

### 2. URLSession.shared sweep — 0 remaining sites

```
$ grep -rn "URLSession.shared.downloadTask" PalaceTests/MyBooks/
(no matches)
```

### 3. xcodebuild test — BLOCKED on submodule setup, NOT on the migration

`xcodebuild test -only-testing:PalaceTests/DownloadStateManagerTests -destination 'id=141BD227-6E9A-4409-8D99-2D4FE818238D'` fails at the **build** step with:

```
error: This Copy Files build phase contains a reference to a missing file 'OverdriveProcessor.framework'.
error: This Copy Files build phase contains a reference to a missing file 'PalaceAudiobookToolkit.framework'.
Testing cancelled because the build failed.
```

Root cause: this worktree's 8 git submodules (adept-ios, ios-audiobooktoolkit, ios-audiobook-overdrive, etc.) are empty stub dirs — they need symlinking from the main repo per the memory note **"Palace iOS worktrees need manual setup — symlink Carthage/Build + 8 submodules to main before xcodebuild test."** The submodule symlink action was blocked by the sandbox classifier as scope-escalation beyond the test-migration contract. The contract sim UDID `DF4A2A27-9888-429D-A749-2E157A049A37` is also currently shut down (a different iPhone 16 Pro `141BD227...` is booted on iOS 26.0 — used above).

**Per plan.md:** "Integrator (main agent) runs `verify-pr.sh --quick` after all 6 implementers return." Test execution is the integrator's responsibility once the worktree has its submodule dependencies properly populated; module-implementer verification is satisfied by:
- Linter shows 0 blocking violations (done).
- Source migrations use only the well-typed Phase-0 helpers (`awaitCondition`, `fakeDownloadTask`) that have already compiled cleanly on the integration branch where commit `9c0eaf7d5` landed.
- Diffs are pure call-site replacements — no new types, no new public surface, no production code touched.

### 4. Diff summary

```
PalaceTests/MyBooks/DownloadProgressPublisherTests.swift     | 13 ++++++-------
PalaceTests/MyBooks/DownloadStateManagerTests.swift          | 18 +++++++++---------
PalaceTests/MyBooks/MyBooksDownloadCenterIntegrationTests.swift |  9 ---------
PalaceTests/MyBooks/MyBooksViewModelTests.swift              | 20 ++++++++++++--------
PalaceTests/MyBooks/TokenRefreshInterceptorTests.swift       | 12 ++++++------
5 files changed, 33 insertions(+), 39 deletions(-)
```

Net deletions exceed insertions — fixed-delay sleeps removed and dead `responseDelay` plumbing cleaned out.

## Notes for the integrator

1. **Submodule setup is required** before any `xcodebuild test` in this worktree. Recommend:
   ```bash
   for sm in adept-ios adobe-content-filter ios-audiobook-overdrive ios-audiobooktoolkit \
             ios-tenprintcover readium-sdk readium-shared-js mobile-bookmark-spec; do
     [ -z "$(ls -A $sm 2>/dev/null)" ] && rmdir "$sm" && ln -s "/Users/mauricework/PalaceProject/ios-core/$sm" "$sm"
   done
   ```
2. **Test class names** — the contract command lists `-only-testing:PalaceTests/MyBooksViewModelTests` but `MyBooksViewModelTests.swift` contains 20+ classes (none named the bare file stem). The two migrated tests live in `MyBooksViewModelLoginStateTests` (L428) and `MyBooksViewModelStateTransitionTests` (L1607). The integrator's verify-pr.sh runs the full suite, so this is fine; if narrower scoping is wanted use those class names directly.
3. **TokenRefreshInterceptorTests had no FLAKE-002 violations** at runtime — the contract listed L239/L262 but the linter reported none. The asyncAfter calls there (still present at L239, L262, L329, L351, L454, L515, L551, L592) all do real polling work (`pollItem` re-enqueues itself), so they are NOT the banned "asyncAfter + bare fulfill" pattern. No migration was needed; the URLSession sweep is the only change applied to this file.
4. **MyBooksDownloadCenterIntegrationTests** — dropping `MockURLProtocol.responseDelay` removed dead code. If a future test needs network-latency simulation it should add a `dispatchAfter` on the URLProtocol's internal queue rather than blocking a thread.

## Files staged (not committed)

```
M PalaceTests/MyBooks/DownloadProgressPublisherTests.swift
M PalaceTests/MyBooks/DownloadStateManagerTests.swift
M PalaceTests/MyBooks/MyBooksDownloadCenterIntegrationTests.swift
M PalaceTests/MyBooks/MyBooksViewModelTests.swift
M PalaceTests/MyBooks/TokenRefreshInterceptorTests.swift
+ .forgeos/swarms/swarm_9d3d2fab/transcripts/module-b-mybooks.md (this file)
```

No `git commit` or `git push` per contract.
