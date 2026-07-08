---
name: swarm_03acb10a-contract-C-AsyncAfterSweep
type: immutable
status: active
created: 2026-05-21
last_refresh: 2026-05-21
freshness_window: never
owners: [general]
description: Module C — AsyncAfter sweep (NowPlayingCoordinator only)
---

# Module C — AsyncAfter sweep (NowPlayingCoordinator only)

**Status:** REFINED post-triage — **scope reduced to ONE file**.

## Scope summary

Replace the single `DispatchQueue.main.asyncAfter` call site in
`NowPlayingCoordinator.swift:280` with a `Task.sleep`-based debounce.
Preserve the existing `pendingUpdate?.cancel()` semantics by changing the
type of `pendingUpdate` from `DispatchWorkItem?` to `Task<Void, Never>?`.

**AudiobookDataManager.swift DROPPED.** Architect triage (D5) verified that
its `syncQueue.async(flags: .barrier)` pattern is the result of a DELIBERATE
prior fix replacing `DispatchQueue.main.asyncAfter` with serial-queue barrier
writes — driven by test flakiness banned in CLAUDE.md. Migrating it back to
`Task.detached` would reverse the fix. The `UIApplication.beginBackgroundTask`
migration is independent and not high-value enough to justify the risk in
this swarm. Leave AudiobookDataManager.swift alone.

**AudiobookLoader.swift NOT TOUCHED.** Swarm 1 already restructured to
adapter dispatch (PR #979); residual callback pyramid is gone. Architect
confirms zero edits.

## In-scope files (exclusive write)

- MOD `Palace/Audiobooks/NowPlayingCoordinator.swift` — replace
  `DispatchWorkItem` debounce mechanism with `Task<Void, Never>?`

## Out-of-scope (read-only)

- `Palace/Audiobooks/AudiobookLoader.swift` — Swarm 1 territory; confirmed
  zero residual pyramid surface
- `Palace/Audiobooks/AudiobookSessionManager.swift` (Module B)
- `Palace/Audiobooks/PlaybackBootstrapper.swift` (Module B)
- `Palace/Audiobooks/Tracker/AudiobookDataManager.swift` — see scope summary;
  architect-dropped; the `syncQueue` is a deliberate flakiness-elimination
  pattern and must not regress
- All files in the swarm-wide don't-touch list

## Locked migration

### `NowPlayingCoordinator.swift`

**Field declaration (line 53):**

```diff
-    private var pendingUpdate: DispatchWorkItem?
+    private var pendingUpdate: Task<Void, Never>?
```

**Cancel sites (lines 227, 249, 272):** No code change — `Task<Void, Never>?`
also responds to `.cancel()`. Verify visually that each site reads
`pendingUpdate?.cancel()` followed by `pendingUpdate = nil` — semantics carry over.

**Schedule site (lines 270–281):**

```diff
         } else {
             // Schedule debounced update
-            let workItem = DispatchWorkItem { [weak self] in
-                Task { @MainActor in
-                    self?.performUpdate(info, isPlaying: isPlaying)
-                }
-            }
-            pendingUpdate = workItem
-
             let delay = Configuration.updateDebounceInterval - timeSinceLastUpdate
-            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
+            let task = Task { @MainActor [weak self] in
+                do {
+                    try await Task.sleep(for: .seconds(delay))
+                } catch {
+                    // Cancellation surfaces as CancellationError — silently
+                    // exit, matching DispatchWorkItem.cancel() semantics.
+                    return
+                }
+                guard !Task.isCancelled else { return }
+                self?.performUpdate(info, isPlaying: isPlaying)
+            }
+            pendingUpdate = task
         }
```

**Why `try await Task.sleep(for:)` and not `Task.sleep(nanoseconds:)`:**
the project minimum is iOS 16; `Task.sleep(for:)` is available since iOS 16
and is the canonical form.

**Why both `try-catch` AND `Task.isCancelled`:** A Task cancelled during the
sleep throws `CancellationError`; the `catch` covers that path. A Task
cancelled AFTER the sleep returns (e.g. cancelled between sleep return and
the `performUpdate` call) is caught by `Task.isCancelled`. Both branches must
exit silently — matching the prior `DispatchWorkItem.cancel()` semantic where
a cancelled work item simply doesn't fire.

**Why `@MainActor` and `[weak self]` on the Task:** preserves the prior
work-item body's main-thread isolation + weak self capture exactly.

## Acceptance criteria

- `grep "DispatchQueue\.main\.asyncAfter" Palace/Audiobooks/ --include='*.swift'`
  returns ONE match: the comment at `Tracker/AudiobookDataManager.swift:109`
  (kept — explanatory)
- `grep "DispatchWorkItem" Palace/Audiobooks/NowPlayingCoordinator.swift`
  returns 0
- `NowPlayingCoordinatorTests` + `NowPlayingCoordinatorBackgroundTests` both
  pass — they exercise the debounce window via injected `applicationStateProvider`
  + `now()` seams, neither of which the migration touches. If a test
  reads `pendingUpdate` directly (it shouldn't — `private var`), Module C
  must adapt the assertion.
- `AudiobookLoader.swift` LOC unchanged (still 418 — Swarm 1's tip)
- `AudiobookDataManager.swift` LOC unchanged
- `xcodebuild build` succeeds for Palace + Palace-noDRM

## Implementer prompt

You are Module C implementer for `swarm_03acb10a`. You are independent of
Modules A and B — can dispatch in parallel with Module A. Production code
compiles independently.

PRE-WORK:
1. Write transcript skeleton FIRST at
   `.forgeos/swarms/swarm_03acb10a/transcripts/C-AsyncAfterSweep.md` with 5
   section headings (Read steps / Field migration / Schedule rewrite / Test
   pass / Validation).
2. Read this contract + `transcripts/triage.md`.
3. Read `Palace/Audiobooks/NowPlayingCoordinator.swift` lines 45–60 (field
   declarations) and lines 220–290 (debounce path including the 3 cancel
   sites and the schedule site).
4. Read `PalaceTests/Audiobooks/NowPlayingCoordinatorTests.swift` (340 LOC)
   and `PalaceTests/Audiobooks/NowPlayingCoordinatorBackgroundTests.swift` —
   note what they assert about the debounce window. Do NOT change tests
   unless they read internal state that the migration removes.

**You are NOT touching:**
- `Palace/Audiobooks/AudiobookLoader.swift` — Swarm 1 territory; architect
  confirms zero residual pyramid surface
- `Palace/Audiobooks/Tracker/AudiobookDataManager.swift` — see scope
  summary (D5); the `syncQueue` migration would regress a prior flakiness fix
- `Palace/Audiobooks/AudiobookSessionManager.swift` or `PlaybackBootstrapper.swift`
  (Module B)

**You ARE touching:**
- `Palace/Audiobooks/NowPlayingCoordinator.swift` — single field type change
  + single schedule rewrite, per the diff above

Validate:
- `xcodebuild build` succeeds
- `xcodebuild test -only-testing:PalaceTests/NowPlayingCoordinatorTests` passes
- `xcodebuild test -only-testing:PalaceTests/NowPlayingCoordinatorBackgroundTests` passes

Write transcript. Do NOT commit, push, or dispatch agents.
