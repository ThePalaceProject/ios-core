# Swarm `swarm_efd1f0c3` — Audiobook toolkit overhaul (T1 + T2 + T3)

**Scope:** Toolkit-side residuals from the Palace audiobook systemic overhaul (ADR §"Toolkit-side remaining work"). Three buckets dispatched in parallel-where-safe.

**Unusual property:** Implementation work lives in the `ios-audiobooktoolkit` submodule (its own git repo, branch `main`). Architect artifacts (this plan, contracts, manifest, transcripts) live on ios-core for governance traceability. The submodule will be bumped on Palace in a follow-up PR (out of scope for this swarm).

**Base refs:**
- ios-core orchestrator branch: `swarm/swarm_efd1f0c3-scaffold` off `epic/audiobook-toolkit-overhaul`
- Toolkit base: `origin/main` (NOT `develop`; toolkit's primary branch is `main`)
- Toolkit `origin/main` at swarm start: `298f3934`
- Toolkit `HEAD` (Palace submodule pin): `7577ecb6`

## Triage findings

### Player surface is small (4 protocol methods) but coupled by inheritance

`Player` protocol declares 4 completion-handler methods: `play(at:completion:)`, `move(to:completion:)`, `skipPlayhead(_:completion:)`, plus `Completion = (Error?) -> Void` for any conformer.

`LCPStreamingPlayer: OpenAccessPlayer` — LCP inherits from OpenAccess and **overrides** the three player-protocol methods plus `seekTo`. **This forces T1 + T2-LCP to land together** — Swift requires `override` signatures to match exactly, so migrating OpenAccess to async without LCP breaks the toolkit build. The ADR's "T1 establishes async shape, T2 migrates remaining implementations" partition is not buildable as-stated.

**Re-partition:** T1 owns the protocol shape + OpenAccessPlayer + LCPStreamingPlayer (one buildable unit). T2 owns FindawayPlayer (standalone class, AudioEngine SDK callbacks) + external callers `AudiobookManager.swift` + `AudiobookPlaybackModel.swift`. T3 is the rename, fully independent.

### `AudiobookManager.swift` is NOT read-only

The ADR called this file "likely-read-only gravitational core." It calls T1's completion-handler methods directly at lines 223, 847, 861 (`play(at:completion:)`, `skipPlayhead(_:completion:)`) — these MUST migrate to `await` calls in the same change that migrates the protocol. Reassigned to T2.

`AudiobookPlaybackModel.swift` (UI) also calls these methods at lines 48/178/189/199/409/443/483 — reassigned to T2 (it's the "external integration" bucket).

### T3 is purely internal to the toolkit

Palace's `Palace.AudiobookSessionManager` (a distinct, instance-based class added in Phase 3 / PR #982) is **not** related to the toolkit's `PalaceAudiobookToolkit.AudiobookSessionManager`. The toolkit class is only referenced internally by:
- `PalaceAudiobookToolkit/Player/Helpers/OpenAccessBackgroundListener.swift` (5 call sites)
- `PalaceAudiobookToolkit/Player/Helpers/OverdriveBackgroundListener.swift` (5+ call sites)

No Palace call sites exist. T3 is a rename within the toolkit module + pbxproj path field update — no submodule-bump pressure on Palace beyond the routine submodule pin update.

**T3 keeps `.shared`** per ADR scope. The toolkit's `AudiobookSessionManager` is a singleton because iOS background-session reconnection delivers to a process-wide handler; binding it to an instance would require AppDelegate-side rework that's out of bucket. Architect-recommended scope: rename only.

### Findaway feasibility

FindawayPlayer uses `FAEAudioEngine.shared()` (Findaway SDK) and routes through `FAEPlaybackEngine` notifications + completion-like callbacks. The player surface (4 protocol methods) is migratable to async — internal SDK calls stay sync. T2-Findaway is tractable in this swarm.

## Dispatch order

| Bucket | Toolkit branch | Base ref | Dispatch | Parallel with |
|---|---|---|---|---|
| **T1** | `feat/swarm_efd1f0c3-T1` | toolkit `origin/main` | DISPATCH FIRST | T3 (parallel) |
| **T2** | `feat/swarm_efd1f0c3-T2` | `feat/swarm_efd1f0c3-T1` (stacks) | AFTER T1 commits protocol shape | T3 (parallel) |
| **T3** | `feat/swarm_efd1f0c3-T3` | toolkit `origin/main` | DISPATCH FIRST | T1, T2 (no dependency) |

**Why T2 stacks on T1:** T2 imports T1's new async `Player` protocol shape (FindawayPlayer must conform). T2 implementer cannot start before T1 has at least committed the protocol file. Architect recommends T1 commits the protocol + OpenAccess + LCP in one branch, T2 branches off that branch and adds Findaway + AudiobookManager/AudiobookPlaybackModel call-site migrations.

**Why T3 is fully parallel:** disjoint file scope (`Core/AudiobookSessionManager.swift` + helpers under `Player/Helpers/`). No protocol shape leak into T1/T2. Worktree-isolated implementer can run concurrently with T1.

## Bucket size estimates

| Bucket | Production LOC moved | Test LOC added | Risk |
|---|---:|---:|---|
| T1 — Player protocol + OpenAccess + LCP migration | ~1,400 (OpenAccessPlayer 1412 + LCPStreamingPlayer 738 in scope, mostly rewrites) | ~400 | HIGH — concurrency migration on critical path |
| T2 — Findaway + AudiobookManager + AudiobookPlaybackModel call-site migration | ~880 (FindawayPlayer 883 + AudiobookManager call-site edits + AudiobookPlaybackModel call-site edits) | ~250 | MED — Findaway SDK callback bridging |
| T3 — Rename `AudiobookSessionManager` → `AudiobookDownloadCoordinator` | ~50 net (rename + 11 call-site edits + pbxproj path field) | ~30 (rename existing references; no new behavior) | LOW |

## Toolkit pbxproj handling

The toolkit project has **one** target (`PalaceAudiobookToolkit`), so each new/renamed file gets one PBXBuildFile + one PBXFileReference + one group membership + one Sources-phase entry. No `pbxproj_add_swift.rb` equivalent exists — implementers can use `xcodeproj` Ruby gem manually or hand-edit (toolkit pbxproj is small enough). T3's rename touches 4 lines in the pbxproj (lines 82/89/124/249-styled entries referencing `AudiobookSessionManager.swift`).

## Build & test commands

```bash
# In the implementer's toolkit worktree:
cd /Users/mauricework/PalaceProject/toolkit-worktrees/swarm_efd1f0c3-T{1,2,3}/

# Build:
xcodebuild -project PalaceAudiobookToolkit.xcodeproj \
  -scheme PalaceAudiobookToolkit \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build

# Test:
xcodebuild -project PalaceAudiobookToolkit.xcodeproj \
  -scheme PalaceAudiobookToolkit \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test
```

The toolkit has 19 test files under `PalaceAudiobookToolkitTests/`. T1/T2 must update `PlayerMock.swift` to match the new async protocol. T3 must update test files that reference `AudiobookSessionManager` by type name (no Palace cross-package tests reference it — toolkit-internal only).

## Don't-touch list (swarm-wide)

These files are off-limits to every bucket unless that bucket's contract explicitly grants write:

- `PalaceAudiobookToolkit/Network/` — manifest/network layer; out of scope
- `PalaceAudiobookToolkit/Tracker/` — bookmark/position tracking; out of scope
- `PalaceAudiobookToolkit/DRM/` — DRM hooks; out of scope
- `PalaceAudiobookToolkit/UI/` (except `AudiobookPlaybackModel.swift` per T2 grant) — UI surfaces; out of scope
- `PalaceAudiobookToolkit/Core/AudiobookManager.swift` — out of scope EXCEPT T2's explicit edits to call sites at lines 223/847/861

## ForgeOS coupling

Palace-side ForgeOS coordination (initiative + changeset) for the eventual submodule-pin-bump PR is **out of scope** for this swarm. The integrator opens a new initiative when ready to bump the Palace submodule pin to a toolkit release that contains T1+T2+T3.

Toolkit PRs follow the toolkit repo's own conventions (ThePalaceProject/ios-audiobooktoolkit — its own CONTRIBUTING.md applies). No ForgeOS hooks fire on the toolkit-side commits.

## Sequencing checklist

1. Architect commits this plan + 3 contracts + manifest on the orchestrator branch.
2. Integrator dispatches T1 + T3 implementers in parallel (worktrees under `/Users/mauricework/PalaceProject/toolkit-worktrees/`).
3. T1 implementer commits async protocol + OpenAccess + LCP migrations on `feat/swarm_efd1f0c3-T1`; writes transcript to `transcripts/T1.md` on orchestrator branch.
4. Integrator dispatches T2 implementer with base ref = `feat/swarm_efd1f0c3-T1`.
5. T2 + T3 land in parallel.
6. Integrator opens 3 toolkit PRs (T1 → main, T2 → main with T1 as dependency, T3 → main). Toolkit reviewer + CI gate.
7. After toolkit PRs merge: separate Palace-side PR bumps submodule pin to the merged toolkit SHA. That PR opens a new ForgeOS initiative.
