<!-- audit-verified -->
# Swift 6 Phase C — handoff (2026-07-07)

**Purpose:** pick-up-cold handoff to finish **Phase C** (the `SWIFT_VERSION 5.0 → 6.0`
language-mode flip). Phase A + Phase B are DONE and merged; Phase C is characterized and
partially applied (a saved WIP patch), paused at a reviewable checkpoint. Read this before
resuming. Companion: `swift6-modernization-handoff-2026-07-06.md` (the Phase-B arc + playbook).

Tracked under epic **PP-4717** (PP-4723 = Phase C).

---

## 1. Status

- **Packages → Swift 6:** DONE. **Phase A** (targeted → 0): DONE. **Phase B**
  (`complete`-mode → 0): **DONE — 738 → 0, all 13 PRs merged** (develop `50faaa34e`,
  wave-1 #1163-#1186 range + wave-2 #1190-#1196). See the 07-06 handoff for the wave map.
- **Phase C** (`SWIFT_VERSION 6.0`): **IN PROGRESS, paused.** The flip surfaces a tail of
  Swift-6-language-mode-only diagnostics (things `complete`-mode under Swift 5 does NOT
  flag) across app + PalaceAuth-package code, several on auth/DRM critical paths.
- **Phase D** (PalaceAudiobookToolkit submodule ~5): NOT STARTED, independent.

**Key fact:** Phase B being 0 does NOT make Phase C a no-op. Full Swift 6 language mode adds
diagnostics `complete`-mode-in-Swift-5 doesn't emit: ObjC-completion-block `@Sendable`
import mismatches, `NSLock.lock()/unlock()` banned in async contexts, `sending`/captured-var
in more places, static-mutable-global concurrency-safety, and `@MainActor`-from-nonisolated
that only errors under full 6 mode. Expect to clear these **layer by layer** (each build
stops at the first stratum; fixing it reveals the next).

---

## 2. The flip

```bash
# In the DRM integration worktree (adobe-rmsdk symlinked; recipe in 07-02 handoff §2b/§4):
ruby scripts/set_strict_concurrency.rb complete          # sets the 4 app configs to complete
# then flip SWIFT_VERSION 5.0 -> 6.0 in each config block that has complete:
python3 - Palace.xcodeproj/project.pbxproj <<'PY'
lines=open('Palace.xcodeproj/project.pbxproj').read().split('\n')
for i,ln in enumerate(lines):
    if 'SWIFT_STRICT_CONCURRENCY = complete' in ln:
        for j in range(i, min(i+8, len(lines))):
            if 'SWIFT_VERSION = 5.0' in lines[j]:
                lines[j]=lines[j].replace('5.0','6.0'); break
open('Palace.xcodeproj/project.pbxproj','w').write('\n'.join(lines))
PY
```
Leaves the `4.2` (legacy) and `""` (inherited) SWIFT_VERSION entries alone. 4 configs flip
(Palace + Palace-noDRM, Debug+Release). Build the `Palace` DRM scheme; iterate on errors.

---

## 3. WIP already applied (SAVE THIS — do not redo)

A partial fix set is saved at **`scratchpad/phasec-progress.patch`** (7 files, ~271 lines)
and lives uncommitted in the integ worktree `.claude/worktrees/s6-integ-0706`. If that
worktree is gone, re-apply the patch onto a fresh integ worktree (flip applied). Layers
fixed:

1. **DRM protocol `@Sendable`** — `NYPLADEPT` (ObjC++) conforms to the `@objc`
   `TPPDRMAuthorizing`; its ADEPT completion blocks import `@Sendable` in Swift 6, which
   must match the protocol requirement. Fix: `@Sendable` on the two protocol completions in
   `Palace/SignInLogic/TPPSignInBusinessLogic.swift` + the mirror in
   `PalaceTests/Mocks/TPPDRMAuthorizingMock.swift`. (Tried `@preconcurrency` on the NYPLADEPT
   conformance first — does NOT silence a function-type-sendability witness mismatch; the
   protocol must actually gain `@Sendable`.)
2. **`NSLock.lock()/unlock()` in async** — banned in Swift 6 (`Use async-safe scoped locking`).
   Convert the async-context pairs to `lock.withLock { … }`:
   `Palace/FeatureFlags/RemoteFeatureFlags.swift` (1), `Palace/MyBooks/BookReturnService.swift`
   (2 pairs, inside the `Task` closures — the outer sync locks are fine, leave them).
3. **AdobeDRM captured-`var` `data`** — `Palace/Reader2/.../AdobeDRMContentProtection.swift`
   `readDataFromArchive`: the `archive.extract` consumer mutates a captured `var data`. Fix:
   lock-backed `ArchiveDataAccumulator` (`@unchecked Sendable`).
4. **[BEHAVIOR-SENSITIVE — SoD REQUIRED] `+DRM` sign-in completion** — making the DRM
   completion `@Sendable` (layer 1) ripples into `TPPSignInBusinessLogic+DRM.swift`: the
   completion now runs `@Sendable` from the Adobe activation thread but touches `@MainActor`
   state (`userAccount`, `libraryAccount`, `finalizeSignIn`). Fix applied: wrap the body in
   one `Task { @MainActor in … }` hop with strong `self` (preserving original retain), and
   box the non-Sendable `error` + `loggingContext` (`DRMAuthCompletionBox`, and
   `DRMLoggingContextBox` hoisted **before** the closure so the `@Sendable` completion
   captures the box, not the raw `[String:Any]`). **Behavioral note for the reviewer:**
   cancel → set-IDs → finalize ordering preserved and now runs as one main-actor unit
   (set-IDs provably precede `finalizeSignIn`, which was NOT guaranteed before). This is the
   one non-mechanical change and MUST get architect + SoD review.

---

## 4. Layers REMAINING (app-target not yet clean when paused)

Next stratum (layer 8), plus almost certainly more behind it:
- **`Palace/AppInfrastructure/TPPAppDelegate.swift:132`** — `PalaceAuthTokenProvider.tokenResolver`
  static property "not concurrency-safe because it involves shared mutable state." The
  resolver is set at launch. Fix likely lives in the **PalaceAuth package** (make
  `tokenResolver` a lock-backed holder or `@MainActor`, NOT `nonisolated(unsafe)`). Package
  change → package build + version consideration.
- **`Palace/SignInLogic/TPPSignInBusinessLogic+SignOut.swift:475`** — `completeLogOutProcess()`
  (`@MainActor`) called from a synchronous nonisolated context (`strongSelf.completeLogOutProcess()`
  inside a nonisolated closure). Fix: main-actor hop.
- **Then keep going** — each fix reveals the next stratum. Budget for several more layers,
  and re-run a **fresh-DD** build each time (incremental under-reports).

After app-target is clean: run **`build-for-testing`** (compiles the test target under Swift 6
— the DRM mock + ~40 `TPPDRMAuthorizingMock` call sites, and any other test ripples), then a
full `verify-pr.sh --quick` / CI (CI also builds **Palace-noDRM**, which this local DRM build
does NOT cover — `#if FEATURE_DRM_CONNECTOR` paths differ).

---

## 5. Why this is its own reviewed pass (not a flag-flip)

Phase C touches auth (`TPPSignInBusinessLogic`, `+DRM`, `+SignOut`, PalaceAuth
`tokenResolver`) and DRM (`AdobeDRMContentProtection`, `NYPLADEPT`) — all critical-path. The
`+DRM` completion restructure is a genuine behavior change. Per the CLAUDE.md rigor bar these
get architect + SoD regardless of LOC. Recommended shape:
1. Resume in a DRM integ worktree; re-apply `phasec-progress.patch`; iterate layers to
   app-target-clean, then test-target-clean.
2. Carve **one Phase C PR**: pbxproj flip + all residual fixes + any PalaceAuth package change.
   Because it spans app + package + auth/DRM, give it 2 SoD (soundness + behavior) with
   explicit attention to the `+DRM` ordering change and the `tokenResolver` concurrency model.
3. Merge-on-green (CI verifies both Palace + Palace-noDRM). Then the migration is DONE →
   optionally Phase D (submodule).

**Do NOT** grind Phase C to merge at the tail of an unrelated long session — the auth/DRM
changes deserve fresh-eyes review. Phase B (738→0) is already safely landed; there is no
pressure to rush C.
