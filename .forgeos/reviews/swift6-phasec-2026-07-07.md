<!-- audit-verified -->
# Swift 6 Phase C — SoD review record (2026-07-07)

Local in-session Separation-of-Duties review (ForgeOS is OFF per handoff §2d; verdicts
recorded here rather than via `mcp__forgeos__*`). Two independent reviewers, distinct lenses.
Change: `SWIFT_VERSION 5.0 → 6.0` language-mode flip (Palace + Palace-noDRM + PalaceUIKit) plus
the residual language-mode-only diagnostic fixes on auth/DRM critical paths.

## rev_50d0a001 — SoD-A (soundness / concurrency-architecture) — APPROVE

All four soundness concerns CONFIRMED-SOUND:
1. `+DRM` authorize completion → single `@MainActor` hop + two `@unchecked Sendable` boxes:
   boxes are `let`-only (read-only after init), consumed once on the main actor; `self`
   capture sound (class is `@MainActor`, hence Sendable); no lost cancellation; captured
   `deviceID`/`userID`/`success` are Sendable.
2. `PalaceAuthTokenProvider` lock-backed `@Sendable` holder — NO deadlock: the getter returns
   the closure value before `?()` applies it, so the resolver runs OUTSIDE the lock.
3. `AdobeDRMContentProtection.ArchiveDataAccumulator` — honest lock-guarded fix (append+read
   both under the lock), not hiding a race.
4. All four `NSLock.lock()/unlock()` → `withLock`/scoped conversions preserve the exact
   critical sections; early-returns/awaits correctly kept outside the lock.
Playbook-compliant: no `nonisolated(unsafe)`; all `@unchecked Sendable` boxes documented; no
`assumeIsolated` added in a deinit.
- Non-blocking note raised: PalaceUIKit embedded framework was left at Swift 5.0.
  **Resolution:** flipped PalaceUIKit (single trivial `Font+PalaceUIKit.swift`) to
  `complete` + `6.0` in this change; verified it compiles clean. Note resolved.

## rev_50d0b002 — SoD-B (behavior-preservation) — APPROVE

- `+DRM` sign-in completion: PRESERVED. Ordering-neutral — the off-main callback path
  already serialized cancel→set-IDs→finalize via main-queue FIFO, and `finalizeSignIn`/
  `updateUserAccount` never reads `userID`/`deviceID`. 25s timeout cancel still targets the
  right main runloop.
- `+SignOut` deauthorize completion → `Task { @MainActor }`: IMPROVED. Closes latent off-main
  execution of `@MainActor` credential/WebKit cleanup; the re-auth stale-generation guard now
  runs on the same main-actor executor, removing the old cross-thread torn-read window. Cannot
  wrongly wipe fresh credentials or skip a legitimate wipe.
- `PalaceAuthTokenProvider`: PRESERVED. Same resolver, same token value, no new launch
  nil-window; lock only guards the storage slot.
- `BookReturnService` + siblings: PRESERVED. Mechanical, same critical sections.
- Non-blocking note raised: the `+DRM` inline comment implied a prior ordering bug.
  **Resolution:** comment softened to state the change is ordering-neutral (not a fix).
  Note resolved.

VERDICT (both): APPROVE. No blocking items.
