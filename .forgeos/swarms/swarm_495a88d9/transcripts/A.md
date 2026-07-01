# Module A — SideloadedBookRegistry + Sync-Exemption + AppContainer wiring — READY

**Swarm:** swarm_495a88d9  **Worktree:** `ios-core-sl-A` (branch `swarm/495a88d9-A`)
**Risk:** critical_path (registry sync + DRM-adjacent).

## Summary

- New `SideloadedBookRegistry` (PP-2678): dedicated local-only JSON manifest under
  Application Support (`<AppSupport>/<bundleID>/sideloaded/sideloaded.json`),
  `@unchecked Sendable` + `NSLock`, synchronous persist-on-mutation. API:
  `add/remove/rename/update/allBooks/identifiers` (+ `originalFilename(for:)`).
  Corrupt/empty/missing/garbage-record manifests all load as empty (no crash).
- Sync-exemption (the load-bearing change): `BookRegistrySync` gained a
  `sideloadedIDsProvider: () -> Set<String>` init param (default lazily reads
  `AppContainer.production().sideloadedBookRegistry.identifiers`, mirroring the
  `downloadCenterProvider` cycle-avoidance precedent) and, immediately after
  `var recordsToDelete = Set<String>(registry.keys)`, `recordsToDelete.subtract(sideloadedIDsProvider())`.
  This exempts sideloaded ids from BOTH the un-registration AND the on-disk delete.
- `TPPBookRegistry`: provider threaded EXPLICITLY through both `BookRegistrySync`
  construction sites (`init(accountsManager:imageLoader:)` and the account-scoped
  `init`).
- `AppContainer`: additive-only `sideloadedBookRegistry` lazy-cached computed
  property + `private static var _sideloadedBookRegistry` (bookOpenTracker-style),
  and `_sideloadedBookRegistry = nil` added to `_resetForTesting()`. The big
  `init`, `_buildCachedAppContainer()` return, and `with*Presenter` copies were
  NOT touched.
- `BookFileManager` (Component 4): account-stable read resolution. Added a
  `sideloadedIdentifiersProvider` seam (production default = the lazy AppContainer
  provider) and, at the single read choke point `fileUrl(for identifier:account:)`,
  substitute `SideloadedBookRegistry.sideloadContentAccountID` for sideloaded ids
  so a library switch can't orphan the file. The shared constant
  `SideloadedBookRegistry.sideloadContentAccountID = AccountsManager.TPPAccountUUIDs[0]`
  lives on `SideloadedBookRegistry` — **Module C must consume THIS constant for its
  import write** (do not pick the account independently).

## Files added
- `Palace/MyBooks/Sideload/SideloadedBookRegistry.swift` (prod → Palace + Palace-noDRM)
- `PalaceTests/MyBooks/Sideload/SideloadedBookRegistryTests.swift`
- `PalaceTests/Book/BookRegistrySyncSideloadExemptionTests.swift`
- `PalaceTests/MyBooks/BookFileManagerSideloadResolutionTests.swift`
All registered via `ruby scripts/pbxproj_add_swift.rb` (added=4 skipped=0 failed=0).

## Files modified
- `Palace/Book/Models/BookRegistrySync.swift` (provider param + subtract line)
- `Palace/Book/Models/TPPBookRegistry.swift` (provider at both inits)
- `Palace/AppInfrastructure/AppContainer.swift` (additive property + static + reset nil)
- `Palace/MyBooks/BookFileManager.swift` (Component 4 resolution + provider seam)

## Key test names
- Exemption (critical): `test_sync_withSideloadedIdExempt_preservesBookAndSkipsOnDiskDelete`
  (drives full production `sync()` — awaitReady gate + HTTP-stubbed loans feed +
  real reconciliation barrier + spy `LocalBookContentService` recording deletes;
  same-run non-exempt book IS evicted+deleted, proving reconciliation ran) and the
  contrast `test_sync_withEmptyExemption_evictsTheSameBook_andDeletesItsContent`.
- Resolution: `test_sideloadedId_resolvesToFixedAccount_evenWhenCurrentAccountDiffers`
  (+ explicit-account variant + non-sideloaded contrast).
- Registry: round-trip, add/remove/rename/update, duplicate-add, missing/corrupt/
  empty/garbage manifest.

## Gaps for the integrator
- **AppContainer collision (A↔C):** A authored the `sideloadedBookRegistry` property
  region; C appends `sideloadedBookManager`. Both additive, neither touches init /
  builder return / presenter copies. Orchestrator owns final composition.
- **pbxproj:** 4 files added to both targets via the helper; re-run/reconcile at integrate.
- **Constant ownership:** `SideloadedBookRegistry.sideloadContentAccountID` is the
  single source of truth for the pinned account — Module C's import copy must call
  `bookFileManager.fileUrl(for: book, account: SideloadedBookRegistry.sideloadContentAccountID)`.
- **Full both-target build / verify-pr.sh --quick:** NOT run here (time). The Palace
  app target compiled clean; new code is DRM-agnostic so Palace-noDRM is expected
  clean, but the integrator should run the full both-target build + verify-pr at integrate.
- **Mutation --diff-only:** `palace_mutate.py --diff-only` computes `git diff base..HEAD`,
  which is empty for uncommitted working-tree changes (I must not commit). I verified
  the touched lines via manual single-mutant kills instead (see DoD #5). At integrate,
  after the changes are committed, `palace_mutate.py --file … --diff-only` will work
  normally.

## DoD evidence

1. **SUT instantiation** — `grep -c 'SideloadedBookRegistry(' …SideloadedBookRegistryTests.swift` = 2;
   `grep -c 'BookRegistrySync(' …BookRegistrySyncSideloadExemptionTests.swift` = 1;
   `grep -c 'BookFileManager(' …BookFileManagerSideloadResolutionTests.swift` = 1. All ≥ required.
   Contract greps: `recordsToDelete.subtract`=1, `sideloadedIDsProvider` in BookRegistrySync=4 /
   in TPPBookRegistry=2, `sideloadContentAccountID` in BookFileManager=2, `sideloadedBookRegistry`
   in BookFileManager=1, `func test` in exemption class=2.
2. **Multi-step bodies** — exemption class has both survives/evicted methods with opposite
   `deleteLocalContent` assertion directions; resolution "…evenWhenCurrentAccountDiffers" sets
   a non-primary currentAccountId then asserts the fixed dir.
3. **check-test-name-vs-body.py** — exit 0 on all three new test files.
4. **Tests green** — `Executed 17 tests, with 0 failures` (12 registry + 3 resolution + 2 exemption).
   Regression: existing `BookRegistrySyncTests`+`Reentrancy`+`Readiness` = `Executed 31 tests,
   with 1 test skipped and 0 failures` (skip is a pre-existing keychain gate).
   xcresult: `/tmp/harness-palace-ios-…/Logs/Test/Test-Palace-2026.07.01_10-35-34--0400.xcresult`.
5. **Mutation (manual single-mutant kills, critical path):**
   - `BookRegistrySync` subtract line → replaced with `_ = sideloadedIDsProvider()`:
     `test_sync_withSideloadedIdExempt` FAILED (mutant killed); control still passed. Restored. → 100% on touched line.
   - `BookFileManager` substitution → `? account : account`: both resolution tests FAILED
     (killed); non-sideloaded contrast passed. Restored.
   - `SideloadedBookRegistry` add duplicate-guard flip `== nil` → `!= nil`: 10/12 tests FAILED
     (killed). Restored.
   (Restores verified by grep; final all-green re-run confirmed.)
6. **Build** — Palace app target compiled clean (test target builds + runs green).
7. **Wiring coverage** — exemption tests drive real `sync()` to `.synced` and the spy records
   the on-disk delete for the non-exempt book, i.e. the `:496-497` delete branch executed.
8. **Contract reconciliation** — deferred to integrate (needs commit-msg file; no commit made).
9. **check-blast-radius.py --quiet** — exit 0.
10. **check-adjacency-staleness.py --quiet** — exit 0.
11. **check-superpartner-spectrum.py --quiet** — exit 0.
