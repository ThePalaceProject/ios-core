# Module C — SideloadedBookManager + Settings + launch rehydration — READY

**Swarm:** swarm_495a88d9 · **Branch:** swarm/495a88d9-C · **Worktree:** `ios-core-sl-C`
**Risk:** critical_path (mints synthetic `TPPBook`s into the main registry). **Ticket:** PP-2677.
**Built on:** Wave 1 (A registry + sync-exemption + BookFileManager Component 4; B `isSideLoadingEnabled`).

## Summary

- **NEW `SideloadedBookManager`** (`Palace/MyBooks/Sideload/`): import → classify (ext→MIME→
  `TPPBookContentType.from`, rejecting unsupported before any write) → mint an OPEN-ACCESS
  `TPPBook` (single acquisition, correct MIME, `relation: .openAccess`, unlimited availability,
  no revoke/bearer/needs-auth) → copy the file to the FIXED-account `BookFileManager.fileUrl`
  path → register in BOTH `SideloadedBookRegistry` (truth = the sync-exemption) AND the main
  `TPPBookRegistry` as `.downloadSuccessful`. `remove()` reverses all three; `rehydrateAtLaunch()`
  re-registers persisted books into the main registry, idempotently.
- **Fixed-account write:** the import copy pins to
  `SideloadedBookRegistry.sideloadContentAccountID` (Module A's constant) — NOT `currentAccountId`
  — so it agrees with A's read-side resolution and a library switch can't orphan the file.
- **Dedup:** the identifier is content-derived (`"sideload-" + sha256(fileBytes)`), so a re-import
  of the same file yields the same id → overwrites in place instead of duplicating.
- **Settings "Side Loading" screen** (`SideLoadingView` + `SideLoadingViewModel`): SwiftUI
  `.fileImporter` (epub/pdf/json UTTypes, security-scoped access handled) + a manage/delete list.
  Gated by `RemoteFeatureFlags.shared.isSideLoadingEnabled` at the `TPPSettingsView` call site.
- **AppContainer:** additive lazy-cached `sideloadedBookManager` property + static + `_resetForTesting` nil.
- **Launch rehydration** wired inside `setupBookRegistryAndNotifications()` in the
  `bookRegistry.load { … }` completion (CORRECTED anchor).

## Files added
- `Palace/MyBooks/Sideload/SideloadedBookManager.swift` (prod → Palace + Palace-noDRM)
- `Palace/Settings/NewSettings/SideLoadingView.swift` (prod → Palace + Palace-noDRM)
- `PalaceTests/MyBooks/Sideload/SideloadedBookManagerTests.swift`
- `PalaceTests/Contract/SideloadImportContractTests.swift`
- `PalaceTests/Contract/__Snapshots__/SideloadImportContractTests/importEpub.json` (recorded baseline — commit it)
All 4 source files registered via `ruby scripts/pbxproj_add_swift.rb` (added=4 skipped=0 failed=0).

## Files modified
- `Palace/Settings/NewSettings/TPPSettingsView.swift` (gated `sideLoadingSection` + `@AppStorage` override read)
- `Palace/AppInfrastructure/AppContainer.swift` (additive property + static + reset nil)
- `Palace/AppInfrastructure/TPPAppDelegate.swift` (rehydration in the load completion)

## FOR THE INTEGRATOR — exact reconcile points

### AppContainer additive lines (append after Module A's `_sideloadedBookRegistry`)
```swift
var sideloadedBookManager: SideloadedBookManager {
    if let cached = AppContainer._sideloadedBookManager { return cached }
    let manager = SideloadedBookManager(
        bookRegistry: self.bookRegistry,
        sideloadedRegistry: self.sideloadedBookRegistry,
        bookFileManager: BookFileManager()
    )
    AppContainer._sideloadedBookManager = manager
    return manager
}
private static var _sideloadedBookManager: SideloadedBookManager?
```
And in `_resetForTesting()`, right after A's `_sideloadedBookRegistry = nil`:
```swift
_sideloadedBookManager = nil
```
NEITHER the big `init`, `_buildCachedAppContainer()` return, nor `with*Presenter` copies are touched.

### TPPAppDelegate rehydration hookpoint (`setupBookRegistryAndNotifications`, replaced the bare `load()`)
```swift
if let loadableRegistry = AppContainer.production().bookRegistry as? TPPBookRegistry {
    loadableRegistry.load {
        AppContainer.production().sideloadedBookManager.rehydrateAtLaunch()
    }
} else {
    AppContainer.production().bookRegistry.load()
}
```
NOTE: the `AppContainer.bookRegistry` property is typed `TPPBookRegistryProvider`, whose surface
has only `load()` (no completion). `load(completion:)` lives on the concrete `TPPBookRegistry`
(off-limits to edit), hence the `as? TPPBookRegistry` cast. Production always resolves to the
concrete type; the `else` keeps the original behaviour if that ever changes. (The contract's
`grep "bookRegistry.load"` convenience matches `loadableRegistry.load {` in spirit — the local is
`loadableRegistry`, not `bookRegistry`, because of the cast.)

### Protocol seam introduced (no Module-A file touched)
`SideloadedBookManager.swift` declares `protocol SideloadedBookRegistering` and
`extension SideloadedBookRegistry: SideloadedBookRegistering {}` — the conformance is a one-liner
extension in C's own file, so A's `SideloadedBookRegistry.swift` is untouched. The manager depends
on this protocol (spyable). It also declares `SideloadContentClassifier` + `SideloadFileManaging`
seams with `Default*` production impls.

### pbxproj
4 source files added to the correct targets via the helper (prod→both, tests→PalaceTests).
Re-run / reconcile at integrate.

## DoD evidence
1. **SUT instantiation:** `grep -c "SideloadedBookManager(" …SideloadedBookManagerTests.swift` = 1 (≥1). ✓
2. **Multi-step bodies:** idempotency test drives `rehydrateAtLaunch()` twice (grep count = 3 incl. helper);
   remove-fallback + remove tests each do stage→act→assert. ✓
3. **Build:** `** BUILD SUCCEEDED **` (Palace scheme, `generic/platform=iOS Simulator`).
4. **Tests:** 12 tests, 0 failures (11 manager + 1 contract). First green run
   `Executed 11 tests, with 0 failures` (before the remove-fallback test); the 12-test set then
   passed as the mutation **baseline: PASS in 17.1s**. `** TEST SUCCEEDED **`.
   xcresult: `/tmp/harness-palace-ios-BFB9B169-…/Logs/Test/Test-Palace-2026.07.01_11-20-27--0400.xcresult`.
5. **Mutation (critical path, whole-file, `--no-cache`):** 3 points, **killed 3, survived 0,
   kill rate 100.0%** (baseline PASS). L122 classifier unsupported-guard KILLED; L259 remove()
   fallback-lookup comparison KILLED (added fallback test); L290 rehydrate existence-guard KILLED
   (idempotency test).
6. **check-test-name-vs-body.py:** exit 0 on both test files. ✓
7. **Scope-coverage audit:** table below.
8. **check-blast-radius.py --quiet:** exit 0. ✓
9. **check-adjacency-staleness.py --quiet:** exit 0. ✓
10. **check-superpartner-spectrum.py --quiet:** exit 0. ✓

## Grep-able contract criteria (all pass)
- `SideloadedBookManager(` in test = 1 (≥1) ✓
- `downloadSuccessful` in manager = 5 (≥1) ✓
- `sideloadContentAccountID` in manager = 3 (≥1) ✓
- `isSideLoadingEnabled` in TPPSettingsView = 2 (≥1) ✓
- `rehydrateAtLaunch` in TPPAppDelegate lands inside `setupBookRegistryAndNotifications` in the
  `load { … }` completion (lines 209-210) ✓
- contract snapshot baseline present: `__Snapshots__/SideloadImportContractTests/importEpub.json`
  records `classify → copyFile → sideloadRegistry.add → bookRegistry.addBook(state=download-successful)` ✓

## Scope-coverage audit
| Contract item | Status |
|---|---|
| `SideloadedBookManager.import` (classify/mint/copy/register both) | DONE |
| fixed-account write (`sideloadContentAccountID`) | DONE + test |
| dedup (content-hash id) | DONE + test |
| unsupported + copy-failure error paths (no partial write) | DONE + tests |
| `remove()` reverses file + both registries | DONE + 2 tests (incl. fallback lookup) |
| `rehydrateAtLaunch()` idempotent | DONE + 2 tests |
| Settings "Side Loading" screen, flag-gated | DONE |
| AppContainer `sideloadedBookManager` (additive) | DONE |
| TPPAppDelegate rehydration in load completion | DONE |
| Contract-snapshot on import pipeline | DONE (baseline recorded) |
| EPUB + PDF + audiobook support | DONE (classification tests per type) |

## Gaps / deferred (for the integrator)
- **Both-target build + verify-pr.sh --quick:** only the `Palace` scheme was built here (time). New
  files carry NO `#if LCP`/`#if FEATURE_DRM_CONNECTOR`, so Palace-noDRM is expected clean, but the
  integrator should run the full both-target build + `verify-pr.sh --quick` at integrate (matches A).
- **Contract snapshot recording:** the baseline JSON was recorded (first-run auto-record; the env
  var doesn't propagate through `harness test` to the sim, so it took the first-run record-and-fail
  branch and wrote the file). It is present in the working tree and re-runs PASS. Commit it.
- **simdrive E2E (plan step 5):** deferred to the release-path pass (enable flag → import LCP 2.x
  EPUB → lane → open → renders + chaos-replay). Not run in this implementer pass.
- **Accepted limitation (R7):** opening a sideloaded book while signed-out on an auth-required
  library shows sign-in first (shared critical-path auth gate) — accepted per contract, not
  engineered around.
