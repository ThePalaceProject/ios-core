# Module D — SideloadedLane (catalog) — Implementer transcript

**Swarm:** swarm_495a88d9 · **Ticket:** PP-2679 · **Branch:** swarm/495a88d9-D
**Worktree:** `/Users/mauricework/PalaceProject/ios-core-sl-D`

## Summary

Injected a flag-gated "Side Loaded" lane at the top of the catalog, present only
when the sideloaded registry is non-empty, surviving every catalog conversion
path — including the `applyFacet` cache-HIT synchronous fast path (:283) that a
per-site patch would silently drop.

All injection routes through ONE choke-point helper
`CatalogViewModel.withSideloadedLane(_:)`, so the lane can never vanish on a
single path. The five former `toCatalogContent()` call sites (166/283/308/362/381)
now call the helper; exactly one `toCatalogContent(` call remains in the file
(inside the helper).

## DI wiring (how the registry + flag reach the VM)

- **Provider seam:** `CatalogViewModel` gained ONE init param
  `sideloadedLaneBooksProvider: @escaping () -> [TPPBook] = { [] }`. The flag is
  kept OUT of the VM — the provider returns `[]` when side-loading is off.
- **Construction site (only caller):** `AppTabHostView.swift` init passes:
  ```swift
  sideloadedLaneBooksProvider: {
      RemoteFeatureFlags.shared.isSideLoadingEnabled
          ? appContainer.sideloadedBookRegistry.allBooks
          : []
  }
  ```
  The flag gate lives here; the registry is read via the existing Wave-1
  `AppContainer.sideloadedBookRegistry` property (READ-only — AppContainer.swift
  was NOT edited).
- **Bridge:** `MappedCatalog.toCatalogContent(prepending:)` forces `.grouped`
  when `extraLanes` is non-empty so the lane shows even for `.ungrouped`/`.empty`
  base feeds. Ungrouped base books are wrapped into a single trailing lane (feed
  title as header) so nothing is dropped — documented choice per contract.

## Files changed

- `Palace/CatalogUI/ViewModels/CatalogState.swift` — `toCatalogContent(prepending:)`.
- `Palace/CatalogUI/ViewModels/CatalogViewModel.swift` — init param, `withSideloadedLane(_:)` helper, 5 call sites routed through it.
- `Palace/AppInfrastructure/AppTabHostView.swift` — provider passed at the CatalogViewModel init (:74 region), flag-gated. (`.sync()` region untouched.)
- `PalaceTests/CatalogUI/SideloadedLaneTests.swift` — NEW (registered in pbxproj → PalaceTests target).

**NOT edited:** AppContainer.swift, RemoteFeatureFlags.swift, SideloadedBookRegistry.swift, CatalogContentView.swift (renderer needed zero changes).

## Tests (PalaceTests/CatalogUI/SideloadedLaneTests.swift)

`SideloadedLaneBridgeTests` (pure toCatalogContent(prepending:)):
- grouped base + provider → Side Loaded lane FIRST, base lanes retained
- ungrouped base + provider → forces `.grouped`, original books not dropped
- empty base + provider → `.grouped([sideloadedLane])`
- provider empty for grouped/ungrouped/empty base → baseline shape unchanged (lane ABSENT)

`SideloadedLaneViewModelTests` (VM wiring, constructs `CatalogViewModel(`):
- load + non-empty provider → lane prepended at top
- load + empty provider → no Side Loaded lane (flag-off / empty-registry analog)
- **applyFacet cache-HIT (:283)** → drives the synchronous cache branch (repo
  load count unchanged = no network; scrollGeneration incremented = branch ran)
  and asserts the Side Loaded lane is still first.

## Definition of Done — evidence

1. **SUT instantiation:** `grep -c "CatalogViewModel(" SideloadedLaneTests.swift` = 1; `grep -c "toCatalogContent(" SideloadedLaneTests.swift` = 8. PASS.
2. **Choke-point greps (CatalogViewModel.swift):**
   - `grep -c "toCatalogContent("` = **1** (want 1 — only in helper)
   - `grep -c "\.toCatalogContent()"` = **0** (want 0)
   - `grep -c "withSideloadedLane("` = **7** (want ≥5: def + 5 sites + doc-ref)
   - AppTabHostView: `sideloadedLaneBooksProvider` = 1, `isSideLoadingEnabled` = 1.
3. **Build:** `** BUILD SUCCEEDED **` (Palace scheme, generic iOS Simulator).
4. **Tests:** `** TEST SUCCEEDED **` — `Executed 9 tests, with 0 failures`
   (SideloadedLaneBridgeTests: 6, SideloadedLaneViewModelTests: 3).
   xcresult: `/tmp/harness-palace-ios-141BD227-6E9A-4409-8D99-2D4FE818238D-d87edc89-dd/Logs/Test/Test-Palace-2026.07.01_11-11-47--0400.xcresult`
5. **Mutation (CatalogState.swift):** the engine discovers only 4 mutation points
   in the file, ALL on PRE-EXISTING lines (39/40 `isApplyingFacet`, 111/121
   selector `==`) — it generates NO mutants for my changed lines because
   `toCatalogContent(prepending:)` is expressed with `.isEmpty` / `!` / array-`+`
   constructs the engine doesn't mutate. Whole-file kill rate is therefore 0/4
   (all 4 UNCOVERED — they belong to code my SUT doesn't exercise), and
   `--diff-only` reports "0 mutation points on changed lines". Not a coverage gap
   in my tests — an engine-operator gap on the changed shape.

   **Manual single-mutant proof (per contract's "single-mutant manual since no
   commit" allowance):** injected `if extraLanes.isEmpty || true` to gut the lane
   injection (extraLanes dropped / force-grouped removed), rebuilt, ran
   `SideloadedLaneBridgeTests` → **mutant KILLED**: `Executed 6 tests, with 5
   failures` — the 3 "present" tests (grouped/ungrouped/empty base) all failed on
   the exact assertions (lane-first, force-grouped, keeps-original-books) while
   the 3 baseline "absent" tests correctly still passed. Mutant reverted; file
   confirmed clean (`grep MANUAL-MUTANT` = 0). Kill rate on the touched behavior
   = 100% (mutant caught by 3 tests / 5 assertions).
6. **check-test-name-vs-body.py:** exit 0 ("0 fake-wiring tests found").
7. **check-blast-radius.py --quiet:** exit 0.
8. **check-superpartner-spectrum.py --quiet:** exit 0.
9. **Scope-coverage audit:** all contract items landed — bridge param, helper,
   5 sites, provider wiring, 5+ named tests incl. facet-cache-hit. No deferrals.

## Note for integrator

`--diff-only` mutation could not scope because changes are uncommitted (git diff
vs origin/develop saw 0 changed lines in the working tree for this tool). After
the orchestrator commits, re-running `palace_mutate.py --file CatalogState.swift
--tests PalaceTests/SideloadedLaneBridgeTests --diff-only` will still find 0
mutants on the changed lines (engine-operator gap on `.isEmpty`/`!`/`+`), which
is expected — the manual single-mutant proof above is the authoritative evidence
that the tests catch the injection defect. Also note: palace_mutate's shared
DerivedData had a stale precompiled-header (modulemap mtime) that failed the
first baseline; cleared `PrecompiledHeaders` + `GeneratedModuleMaps-iphonesimulator`
under `Palace-cjpueeer...` DerivedData to recover (not a code issue).

## Gaps / BLOCKED

None.
