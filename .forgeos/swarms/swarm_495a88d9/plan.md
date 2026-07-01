# Swarm plan — swarm_495a88d9 — Side Loading (PP-2677 / PP-2678 / PP-2679)

**Branch:** feature/PP-2677-sideloading (worktree `ios-core-sideloading`)
**Base:** develop
**Created:** 2026-07-01
**Ground truth:** `docs/architecture/sideloading-plan.md` (LOCKED decisions — not re-litigated here)

## Goal
A **test-only** capability: import a local EPUB / PDF / audiobook file, have it
appear in a dedicated catalog lane, and open in the real reader + DRM stack with
no OPDS feed involved. Primary use: exercising DRM profiles (LCP 2.x, PP-2580)
end-to-end in the shipping reader.

Locked approach (plan doc): reuse the main `TPPBookRegistry` by registering
sideloaded books as `.downloadSuccessful` + a **sync exemption**, gated behind a
`RemoteFeatureFlags` flag with a DEBUG-on local override.

## Modules

| Module | Risk | Depends on | Owns |
|--------|------|-----------|------|
| **B — FeatureFlag** | standard | — | `RemoteFeatureFlags` + `FirebaseManager` flag `sideLoadingEnabled` |
| **A — Registry + Sync-Exemption** | **critical_path** | — | `SideloadedBookRegistry` (PP-2678), `BookRegistrySync` exemption, `TPPBookRegistry` provider threading, AppContainer `sideloadedBookRegistry` property |
| **C — Manager + Settings** | critical_path | A, B | `SideloadedBookManager` (PP-2677), Settings "Side Loading" screen, launch rehydration, AppContainer `sideloadedBookManager` property |
| **D — SideloadedLane** | standard | A, B | Catalog lane injection (PP-2679) in `CatalogViewModel`/`CatalogState`/`AppTabHostView` |

Contracts: `.forgeos/swarms/swarm_495a88d9/contracts/{B-FeatureFlag,A-Registry-and-SyncExemption,C-Manager-and-Settings,D-SideloadedLane}.md`.

## Parallelism / dependency plan
`SideloadedBookRegistry` (A) is the foundation everything consumes; the flag (B)
is foundational and independent. C and D both consume A + B.

```
Wave 1 (parallel):   A (registry + sync-exemption)   ||   B (feature flag)
Wave 2 (parallel):   C (manager + settings)          ||   D (catalog lane)
Integrate:           orchestrator reconciles AppContainer + project.pbxproj, then verify-pr + forge-review
```

- **A ∥ B** run fully in parallel — zero shared files.
- **C ∥ D** run in parallel after A+B land — C touches MyBooks/Settings/AppDelegate,
  D touches CatalogUI/AppTabHostView. Their only shared file is `AppContainer.swift`
  (C appends a property; D does not touch AppContainer — D reads via the property A
  added). So C ∥ D is clean; the AppContainer collision is A↔C, resolved by staging
  (C lands after A) + orchestrator reconcile.
- C and D can begin against A's **contract** (stable public surface) before A's code
  fully merges, but must rebase onto merged A before final verify.

## Real integration collision points (explicit ownership)
1. **`Palace/AppInfrastructure/AppContainer.swift`** — touched by A (adds
   `sideloadedBookRegistry` lazy-cached property) and C (adds `sideloadedBookManager`
   lazy-cached property + is where rehydration is composed). Both edits are
   **additive** lazy-cached computed properties in the `bookOpenTracker`-style
   region — NEITHER touches the big `init`, `_buildCachedAppContainer` return, or
   the `with*Presenter` copies. **Orchestrator owns final AppContainer composition
   at integrate time**; A is primary author of the property region, C appends.
2. **`Palace.xcodeproj/project.pbxproj`** — new files from A (2 prod) and C (2-3
   prod) + test files from all. **Every module MUST use
   `ruby scripts/pbxproj_add_swift.rb [--targets Palace,Palace-noDRM] FILE...`
   — NEVER hand-edit.** The helper is idempotent; orchestrator re-runs / reconciles
   pbxproj at integrate to absorb both modules' additions cleanly.

## Reader-open call-graph confirmation (task item 4)
Traced: catalog lane tap → `BookDetailViewModel` button state for `.downloadSuccessful`
→ Read/Listen action → `MyBooksDownloadCenter.fileUrl` / `BookFileManager.fileUrl(for:account:)`
→ reader.

**Verdict: SUFFICIENT for EPUB + PDF with NO other production edits.** Registering
a book `.downloadSuccessful` and placing the correct file at
`BookFileManager.fileUrl` opens it:
- `BookButtonMapper.swift:48` maps `.downloadSuccessful` → Read/Listen from
  registry state alone (no availability/download-record/network gate).
- The reader resolves `book.url` → `downloadCenter.fileUrl(for:identifier)` →
  `BookFileManager.fileUrl` sha256 path (`TPPBook+Additions.swift:15`,
  `BookFileManager.swift:59-73`) — no download-record lookup, no OPDS re-fetch, no
  acquisition-availability check.
- The `#if FEATURE_DRM_CONNECTOR` Adobe gate (`BookDetailViewModel.swift:848`) is
  skipped for a no-credentials open-access book.
- **Caveat (architect finding 5):** `didSelectRead` still runs the `ensureAuthAndExecute`
  AUTH gate (`:711`) — a signed-out user on an auth-required library sees sign-in
  first. Accepted (R7); not an availability/download/OPDS gate.
- **Caveat (architect finding 4):** file placement + read resolution are pinned to a
  fixed account so a library switch cannot orphan the file (R6, Modules A+C).

**No hidden production gap** — but two *construction requirements* fall to Module C
(already in its scope, not new files):
1. The minted `TPPBook`'s single acquisition MIME MUST classify via
   `TPPBookContentType.from` to epub/pdf/audiobook, else `defaultBookContentType`
   → `.unsupported` → `presentUnsupportedItemError` and it never opens.
2. **Audiobook caveat:** the copied file must be a valid **manifest JSON** (parsed
   by `LocalFileAdapter`, `Vendors/LocalFileAdapter.swift:73-80`); remote-track
   playback still needs the network at play time. Also, audiobook open runs
   `validateRequirements` which requires credentials only for auth-required
   accounts — a synthetic open-access book passes. Acceptable for a test feature.

## Risks
- **R1 (load-bearing):** the main registry `sync()` evicts + deletes any book not in
  the loans feed (`BookRegistrySync.swift:406,480-497`). Sideloaded books MUST be
  exempted or the next sync destroys them. Owned by Module A; guarded by the
  critical regression test + 100% mutation on the touched lines.
- **R2 (rehydration ordering + async load — architect finding 2/3):** the exemption
  set is driven by `SideloadedBookRegistry.identifiers` (persisted independently,
  read lazily at sync time), so persistence is safe regardless of ordering. But
  rehydration into the MAIN registry (so books open + appear) must (a) be anchored in
  `applicationDidFinishLaunching` / `setupBookRegistryAndNotifications()` — NOT the
  `handleAppRefresh` background handler that the original `:218` cite pointed at — and
  (b) run in the **`bookRegistry.load(completion:)` callback**, because `load()` is
  async and a synchronous rehydrate afterward is clobbered when the disk snapshot
  lands and transitions to `.loaded`. The real first runtime syncs
  (`applicationDidBecomeActive:330`, `AppTabHostView:260`) both follow launch and are
  guarded by the registry loading state. Owned by Module C.
- **R6 (cross-account file scoping — architect finding 4):** `BookFileManager.fileUrl`
  is scoped to `currentAccountId`, but sideloaded books are account-agnostic. Both
  the write (Module C import) AND the read resolution (Module A, in `BookFileManager`)
  are pinned to ONE fixed `sideloadContentAccountID` (= `AccountsManager.TPPAccountUUIDs[0]`,
  the primary/no-subpath content dir), so a library switch cannot orphan the file.
  Module A owns the read-side override; C consumes the shared constant for the copy.
- **R7 (auth gate — architect finding 5, ACCEPTED):** `didSelectRead` runs
  `ensureAuthAndExecute`, so opening a sideloaded book while signed out on an
  auth-required library shows sign-in, not the reader. Accepted for this test feature
  (signed-in DRM-test use case works); NOT engineered around (shared critical-path
  auth gate). E2E testers sign in first.
- **R3 (AppContainer / pbxproj collisions):** mitigated by additive-only property
  edits + orchestrator reconcile (above).
- **R4 (My Books visibility):** decision #1 makes sideloaded books appear on the My
  Books shelf. Accepted for a test feature (plan open item); not in scope to filter.
- **R5 (DRM path for LCP 2.x):** the whole point. `BookFileManager.pathExtension`
  (`:123`) chooses `.lcpa`/`.zip`/`.epub` from the book's acquisition chain — Module
  C's minted `TPPBook` acquisition MIME must be correct so the file lands at the
  extension the LCP extract pass expects. Verified via simdrive E2E (plan step 5).

## Acceptance criteria (from the three tickets + plan Verification)
- AC1 (PP-2678): `SideloadedBookRegistry` persists/round-trips sideloaded books in
  its own manifest; add/remove/rename/update + edge cases covered by tests.
- AC2 (sync-exemption): a `sync()` whose loans feed lacks a sideloaded id leaves the
  book + its file intact (critical regression test, 100% mutation on touched lines).
- AC3 (PP-2677): import a file → classify by type → mint open-access `TPPBook` →
  copy to `BookFileManager.fileUrl` → register in both registries → exemption set
  updated; remove reverses; launch rehydration re-registers before first sync.
  Import pipeline pinned by a contract-snapshot.
- AC4 (PP-2677): Settings "Side Loading" screen (file picker + manage list), gated
  by the flag.
- AC5 (PP-2679): flag on + ≥1 sideloaded book → lane present (incl. ungrouped/empty
  base feed); flag off or empty registry → lane absent.
- AC6 (gate): `RemoteFeatureFlags.isSideLoadingEnabled` — local override > DEBUG-on
  > Firebase.
- AC7: opening a sideloaded book renders in the real reader (EPUB/PDF/audiobook);
  LCP 2.x test EPUB opens end-to-end (simdrive E2E + chaos-replay recording).
- Global DoD: 11-check battery, build clean both targets, `verify-pr.sh --quick`
  PASS, architect + SoD (blast_radius) review on A and C (critical path).

## Integration & review
1. Land A + B (wave 1), rebuild pbxproj, verify each in isolation.
2. Land C + D (wave 2) rebased on A+B.
3. Orchestrator reconciles `AppContainer.swift` + `project.pbxproj`.
4. `scripts/verify-pr.sh --quick` full-suite parity.
5. `/forge-review` — architect + blast_radius reviewers focused on the
   sync-exemption (A) and the import/rehydration wiring (C).
6. simdrive E2E per plan step 5; record a chaos-replay.
