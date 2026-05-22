# Swarm Outcome — `swarm_efd1f0c3` — Audiobook toolkit overhaul (T1 + T2 + T3)

**Status:** complete
**Started:** 2026-05-21
**Toolkit PRs merged:** 2026-05-22 (T3 #176, T1 #177, T2 #179)
**Palace branch ready for PR:** `swarm/swarm_efd1f0c3-scaffold` (off `epic/audiobook-toolkit-overhaul`)

## What shipped

Three toolkit-side phases of the audiobook systemic overhaul (companion to PRs #979/#980/#982 which shipped the Palace-side 3-phase overhaul on 2026-05-21):

### T3 — Rename `AudiobookSessionManager` → `AudiobookDownloadCoordinator` (toolkit PR #176)
- Pure rename via `git mv` (history preserved at 86% similarity)
- 21 in-file references + 7 listener call-sites + 4 pbxproj entries + 1 behavioral round-trip test
- `.shared` retained per ADR (iOS process-wide URLSession background completion handler design)
- Zero Palace callers affected (toolkit-internal)
- Merge SHA on toolkit main: `42da86bf`

### T1 — Player protocol async migration (toolkit PR #177)
- Three completion-handler methods on `Player` protocol → `async/await`
  - `skipPlayhead → async → TrackPosition?`
  - `play(at:) async throws`
  - `move(to:) async → TrackPosition?`
- `Completion` typealias removed
- `OpenAccessPlayer` + `LCPStreamingPlayer` migrated atomically (Swift compiler enforces signature match across 14 LCP overrides — clean build confirms)
- `seekTo` kept callback-shaped per pre-flight (not in protocol; LCP override's `isSeekingWithinSameTrack` flag + `asyncAfter(0.5)` clear translates poorly)
- `PlayerMock` rewritten async + spy surface
- 13 bridge shims marked `// swarm_efd1f0c3-T1 BRIDGE` in T2 territory (3 AudiobookManager, 7 AudiobookPlaybackModel, 3 FindawayPlayer) — kept the toolkit standalone-buildable; T2 replaced them
- 12 new contract tests across `OpenAccessPlayerAsyncContractTests` (8) + `LCPStreamingPlayerAsyncContractTests` (4)
- One-line typo fix in pre-existing `ManifestDecodingTests` (was blocking test-target compilation entirely; `Manifest.Metadata.FindawayDRMInformation` → `Manifest.FindawayDRMInformation`)
- Merge SHA on toolkit main: `85ba6037`

### T2 — Findaway async + bridge-shim removal (toolkit PR #179, originally #178)
- `FindawayPlayer` full async migration; all 3 async Player methods implemented
- **`SingleResumeContinuationBox<T>` + `SingleResumeThrowingContinuationBox`** — thread-safe single-resume guard against Findaway's duplicate-notification SDK quirk; 32-thread `DispatchQueue.concurrentPerform` race test pins the lock contract
- All 13 `// swarm_efd1f0c3-T1 BRIDGE` markers removed (`grep` returns 0 against PR HEAD)
- 13 new tests: `FindawayPlayerAsyncContractTests` (9) + `AsyncCallSiteTests` (4)
- `FindawayPlayer` relaxed `final` → `class` to allow `SpyFindawayPlayer` test subclassing (sole non-test subclass)
- `play(at:) async throws` resumes after queueing the SDK call (NOT waiting for `audioEnginePlaybackStarted`) — deliberate trade-off documented inline to avoid Findaway queue deadlock
- Merge SHA on toolkit main: `d40b1ea6` (the merge commit; T2's substantive commit is `de7e2dcd`)

### Palace-side integrator work (this branch, `swarm/swarm_efd1f0c3-scaffold`)
- ADR `docs/architecture/audiobook-systemic-overhaul.md` reconstructed and committed (`888732787`)
- Swarm scaffold (plan, 3 contracts, manifest) committed (`9a694ff61`)
- Implementer transcripts committed (`053e0287c`)
- Submodule pin bumped `7577ecb6` → `d40b1ea6` (`c901d5dbc`)
- Three Palace player-call sites migrated to async (`c901d5dbc`):
  - `Palace/Audiobooks/AudiobookSessionManager.swift:~431` (chapter-skip from CarPlay/remote-control)
  - `Palace/Audiobooks/AudiobookSessionManager.swift:~628` (initial-position playback start)
  - `Palace/Audiobooks/AudiobookSessionManager.swift:~687` (remote-position seek after sync)
- Each call site now uses `Task { @MainActor in try await player.play(at:) }` with `Log.info` / `Log.error` for success/failure

## Architect re-partition (vs ADR's original sketch)

ADR said: "T1 = protocol + 1 player; T2 = remaining players + external callers."

Architect re-partitioned to: **T1 = protocol + OpenAccess + LCPStreamingPlayer** (LCP inherits from OpenAccess with 14 `override` declarations — Swift requires base + subclass signatures to change atomically). **T2 = FindawayPlayer (standalone) + AudiobookManager + AudiobookPlaybackModel call-site edits**. T3 unchanged.

Rationale: T1's protocol-shape commit forced both OpenAccess and LCP to change in lockstep; splitting them across PRs would leave a non-buildable intermediate.

## Dispatch + merge sequence

- **Wave 1 (parallel):** T1 + T3 dispatched simultaneously off toolkit `origin/main`
- **Wave 2:** T2 dispatched after T1 pushed (stacked on T1's branch via `feat/swarm_efd1f0c3-T1`)
- **Merge order:** T3 first (smallest, independent) → T1 second (T2 dependency) → T2 last (required retarget from T1's branch to main after T1 merged + T1 branch was deleted)
- **Conflict resolution:** T1's pbxproj conflicted with T3's renames (3 test-file additions); resolved by taking origin/main's additive side. T2's swift files conflicted with T1's bridge shims; resolved by taking T2's HEAD side (full migration replaces bridge shims).
- **PR #178 auto-closed** when T1 branch was deleted post-merge; re-opened as PR #179 against `main` with identical diff.

## Reviewer verdicts (independent review prior to merge)

| PR | Verdict | Severity | Nits |
|---|---|---|---|
| #176 (T3) | APPROVE | none | 0 |
| #177 (T1) | APPROVE WITH NITS | minor | 3: LCP `move(to:)` doesn't route through `seekTo` (pre-existing); no `isSeekingWithinSameTrack` flag test; one tautology assertion in cancellation test |
| #178/#179 (T2) | APPROVE WITH NITS | minor | 4: one test pins PlayerMock instead of real call-site; trap-avoidance `XCTAssertTrue(true, ...)` idiom; mutation tooling not ported to toolkit; docstring clarity on per-call box lifecycle |

No blockers. Continuation guard verified thread-safe; bridge-shim removal grep verified.

## Failure surfaces closed (per the overhaul ADR)

| Pattern | Closed by |
|---|---|
| Pattern 1 — Loader callback pyramid (Palace-side) | Palace Swarm 1 (PR #979 — already shipped) |
| Pattern 2 — Vendor-shape dispatch via property checks (Palace-side) | Palace Swarm 1 |
| Pattern 3 — `hasLCPAcquisition` missing recursive case | Palace Swarm 1 |
| Pattern 4 — Position writers don't share a contract | Palace Swarm 2 (PR #980 — already shipped) |
| Pattern 5 — `.shared` singletons on audiobook lifecycle (Palace-side) | Palace Swarm 3 (PR #982 — already shipped) |
| Pattern 6 — GCD residue on the audiobook path (Palace-side) | Palace Swarm 3 |
| **Toolkit-side: `AudiobookSessionManager` misnaming** | **T3 (this swarm)** |
| **Toolkit-side: Player callback API surface** | **T1 + T2 (this swarm)** |

The full ADR-listed work is now executed.

## Risks / follow-up

- **Mutation tooling not ported to the toolkit.** `palace_mutate.py` (and its `lint-test-quality.py` companion) live on Palace ios-core; toolkit PRs were assessed analytically against test design. CI on toolkit is also minimal (no checks ran on the 3 PRs — review was the gate). Track porting as a separate ticket if toolkit-side mutation gates are wanted.
- **One follow-up test refactor** in `AsyncCallSiteTests` (T2) pins PlayerMock rather than real call-site routing — non-blocking nit; clean up in next toolkit PR.
- **No simdrive E2E** against the new async player surface — recommend a smoke pass before tag-cut: open audiobook, skip chapters via remote-control + CarPlay, force-quit mid-chapter, reopen, verify resume position holds.
- **Pre-existing toolkit test failures** (PalaceUIKit framework rpath, ManifestDecodingTests — partially fixed by T1's typo correction) tracked separately; not introduced by this swarm.

## Methodology lessons (post-swarm)

1. **Hook-relative-path fragility on cross-repo worktrees.** `scripts/hooks/audit-before-assert.py` lived on ios-core but agents working in toolkit worktrees inherited the hook config without the script. T1's first attempt was blocked; symlinking `scripts/hooks/` into each toolkit worktree unblocked it. Bake into Phase 0 of swarm skill if cross-repo swarms recur.
2. **Stacked-PR base-branch deletion auto-closes children.** When T1 merged + its branch was deleted, PR #178 (stacked on T1's branch) was auto-closed by GitHub. The PR could not be reopened; had to create PR #179 with identical diff against `main`. Document this behavior in the swarm skill for future stacked-PR users.
3. **Architect re-partition was load-bearing.** T1's "OpenAccess + LCPStreaming together" split avoided a non-buildable intermediate. Encourage architects to verify all `override` chains before locking the partition.
4. **Bridge-shim pattern works.** T1 added 13 `// swarm_efd1f0c3-T1 BRIDGE` markers; T2 removed them as the final migration step. The marker comments made the cross-PR coordination visible and the grep verification trivial.
5. **Squash for T3 + T1; merge for T2.** T2's reviewer recommended `merge` over `squash` to preserve commits for bisect (T1 → main, T2's substantive commit `de7e2dcd`, merge from main into T2's branch `e71503d2`, final merge commit `d40b1ea6`). Squash would have flattened the bisect-relevant history.

## Commit chain on `swarm/swarm_efd1f0c3-scaffold`

```
c901d5dbc [swarm_efd1f0c3] bump submodule pin + migrate 3 Palace call sites to async player
053e0287c [swarm_efd1f0c3] implementer transcripts — T1 + T2 + T3
9a694ff61 [swarm_efd1f0c3] swarm scaffold: contracts + plan + manifest
888732787 docs(architecture): reconstruct audiobook-systemic-overhaul ADR
```

Parent is `epic/audiobook-toolkit-overhaul` (off develop). PR target: develop.
