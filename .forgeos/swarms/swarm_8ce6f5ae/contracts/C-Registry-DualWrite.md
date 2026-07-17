# Contract C — Kill Registry Dual-Write + Enforce allowedTransitions (WS3)

**Module:** Book (TPPBookRegistry / TPPBookState) + full observer migration (6 modules)
**Risk:** critical_path (TPPBookRegistry is THE single source of truth for book state)
**Depends on:** A (doctrine declares the enforcement point + SoT scope)

> **AMENDED per Fable Phase-1a BLOCK.** Three substantive corrections folded in:
> (a) the `allowedTransitions` set is INCOMPLETE — correct it BEFORE enforcing or
> DEBUG builds + the Monday DEBUG suite crash; (b) the `:283` post is a REGISTRY
> LIFECYCLE signal, not per-book — it needs a NEW fed publisher (the existing
> `syncStatePublisher` is DEAD: `syncStateSubject` is never `.send`-fed); (c) two
> observers would HANG on a fresh empty-registry sign-in if pointed at
> `bookStatePublisher`. Full per-observer target map below.

## Verified starting facts
- Deprecated dual-write: `TPPBookRegistry.postStateNotification`
  (`Palace/Book/Models/TPPBookRegistry.swift:639`, `@available(*, deprecated)`) posts
  `.TPPBookRegistryStateDidChange` (`:642`), called from EVERY per-book state path
  (`:553,:570,:586,:600,:614`). A SECOND, DIFFERENT post at `:283` signals REGISTRY
  LIFECYCLE (load/sync began/ended), NOT per-book state.
- Per-book Combine replacement exists and is fed: `bookStatePublisher` (`:313`).
- **`syncStatePublisher` is DEAD** — `syncStateSubject` is never `.send`-fed, so it
  emits nothing. It CANNOT be the lifecycle replacement without being fed first.
- **`allowedTransitions` (`Palace/Book/Models/TPPBookState.swift:91`) is INCOMPLETE.**
  Production legitimately performs, and the current set OMITS:
  - `.downloadSuccessful -> .downloadNeeded` — content-protection re-download at
    `Palace/Reader2/.../ReaderService.swift:585`; PP-4800 OverDrive `-1008` recovery at
    `Palace/Audiobooks/AudiobookSessionManager.swift:2227` ("reset to .downloadNeeded
    first"); LRU eviction at `Palace/MyBooks/DiskBudgetManager.swift:168`.
  - `.used -> .downloadNeeded` — also live.
  Enforcing the CURRENT set with a DEBUG `assertionFailure` crashes dev builds and
  Monday's DEBUG suite. **Correcting the SET makes these legal without touching those
  3 call sites.**
- **All 9 observers (6 modules) — count CONFIRMED complete (no Obj-C / raw-string
  stragglers):**
  1. `Palace/CatalogUI/ViewModels/ActiveSessionsViewModel.swift:135`
  2. `Palace/CatalogUI/Views/CatalogLaneMoreView.swift:122`
  3. `Palace/CatalogUI/Views/CatalogSearchView.swift:112`
  4. `Palace/AppInfrastructure/AppTabHostView.swift:456` (holds badge)
  5. `Palace/Book/UI/BookDetail/BookDetailView.swift:134`
  6. `Palace/Book/UI/BookDetail/HalfSheetview.swift:227`
  7. `Palace/MyBooks/MyBooksDownloadCenter.swift:2076` (launch download reconciliation)
  8. `Palace/MyBooks/MyBooks/MyBooksViewModel.swift:338`
  9. `Palace/Book/Models/TPPBookRegistry.swift:455` (registry self-observer; SAML
     post-sign-in sync)
- **External POSTERS (hand-fired triggers, not observers):**
  `Palace/Holds/HoldsViewModel.swift:249`,
  `Palace/Settings/DeveloperSettings/DeveloperSettingsViewModel.swift:741`. Both feed
  the AppTabHostView holds-badge refresh (#4).
- `canTransition` (`TPPBookState.swift:151`) declared but referenced by NO production
  file; `setState` (`:605`) does not call it. Unenforced, confirmed.

## Per-observer TARGET MAP (mandatory — how each of the 9 migrates)
| # | Observer | Target | Why |
|---|----------|--------|-----|
| 1 | ActiveSessionsViewModel:135 | `bookStatePublisher` | per-book UI refresh |
| 2 | CatalogLaneMoreView:122 | `bookStatePublisher` | per-book lane refresh |
| 3 | CatalogSearchView:112 | `bookStatePublisher` | per-book results refresh |
| 5 | BookDetailView:134 | `bookStatePublisher` | per-book detail refresh |
| 6 | HalfSheetview:227 | `bookStatePublisher` | per-book sheet refresh |
| 8 | MyBooksViewModel:338 | `bookStatePublisher` | per-book shelf refresh |
| 7 | MyBooksDownloadCenter:2076 | **NEW RegistryState publisher** | launch reconciliation runs on LOAD-complete; a fresh empty registry emits ZERO per-book events → `bookStatePublisher` would hang forever |
| 9 | TPPBookRegistry:455 (SAML sync) | **NEW RegistryState publisher** | post-sign-in sync fires on SYNC lifecycle, not per-book; same empty-registry hang risk |
| 4 | AppTabHostView:456 (holds badge) | `bookStatePublisher` (hold state changes) **+ a holds-changed trigger** replacing the 2 hand-posts | badge currently refreshes on the 2 hand-posted triggers (Holds:249, DeveloperSettings:741) |

**Hand-posted-trigger replacement (#4):** replace the two `post(name:.TPPBookRegistryStateDidChange)`
calls at HoldsViewModel:249 + DeveloperSettingsViewModel:741 with a `.send` into a
dedicated **holds-changed publisher** (a `PassthroughSubject` on the holds source /
registry, e.g. `holdsDidChangePublisher`); AppTabHostView:456 subscribes to that for
the badge (plus `bookStatePublisher` for per-book hold-state flips). Do NOT leave the
badge depending on a deleted NotificationCenter name.

## Internal ordering (non-negotiable — 5 steps)
1. **CORRECT the transition set FIRST.** In `TPPBookState.swift:91` add
   `.downloadSuccessful -> .downloadNeeded` and `.used -> .downloadNeeded` with an
   inline comment citing the 3 sources (ReaderService.swift:585,
   AudiobookSessionManager.swift:2227, DiskBudgetManager.swift:168). Seed any further
   pairs from Contract-E green snapshots.
2. **CREATE AND FEED a RegistryState publisher** for the lifecycle signal. Either
   revive `syncStatePublisher` by actually `.send`-feeding `syncStateSubject` at the
   load/sync-began/ended points (where `:283` currently posts), OR add a new
   `registryStatePublisher`; feed it at every `:283` lifecycle transition. It MUST emit
   on load-complete so the empty-registry sign-in path fires.
3. **ENFORCE at `setState:605`** — call
   `TPPBookState.canTransition(from:previousState,to:state)`; on violation
   `assertionFailure` in DEBUG + telemetry/log in RELEASE, then **still apply** the
   transition (never drop state).
4. **MIGRATE all 9 observers per the target map** (6 → `bookStatePublisher`, 2 → the
   new RegistryState publisher, 1 badge → `bookStatePublisher` + holds-changed
   trigger). Re-point the 2 external posters to the holds-changed publisher.
5. **DELETE both posts LAST** — remove `postStateNotification` (`:639`) + call sites
   (`:553,:570,:586,:600,:614`) + the `:283` post; remove the
   `.TPPBookRegistryStateDidChange` name decl in `NSNotification+TPP.swift` iff no
   consumer remains (grep clean).

## Scope (exact files)
- `Palace/Book/Models/TPPBookState.swift` (correct allowedTransitions FIRST)
- `Palace/Book/Models/TPPBookRegistry.swift` (create+feed RegistryState publisher;
  enforce; self-observer :455; delete both posts)
- `Palace/CatalogUI/ViewModels/ActiveSessionsViewModel.swift`
- `Palace/CatalogUI/Views/CatalogLaneMoreView.swift`
- `Palace/CatalogUI/Views/CatalogSearchView.swift`
- `Palace/AppInfrastructure/AppTabHostView.swift` (badge → publisher + holds-changed)
- `Palace/Book/UI/BookDetail/BookDetailView.swift`
- `Palace/Book/UI/BookDetail/HalfSheetview.swift`
- `Palace/MyBooks/MyBooks/MyBooksViewModel.swift`
- `Palace/MyBooks/MyBooksDownloadCenter.swift` — **the :2076 observer block ONLY**
  (→ new RegistryState publisher; Contract E owns the rest of this file)
- `Palace/Holds/HoldsViewModel.swift` — **the :249 post ONLY** (→ holds-changed send)
- `Palace/Settings/DeveloperSettings/DeveloperSettingsViewModel.swift` — **the :741 post ONLY**
- `Palace/AppInfrastructure/NSNotification+TPP.swift` (remove name decl iff unused)
- NEW test: `PalaceTests/Contract/TPPBookRegistryMutationContractTests.swift`

## Off-limits
- The 3 legitimate-transition CALL SITES — `ReaderService.swift:585`,
  `AudiobookSessionManager.swift:2227`, `DiskBudgetManager.swift:168` — do NOT edit
  them; correcting the SET is what legalizes them.
- `Palace/MyBooks/Sideload/**` (Contract D)
- `Palace/AppInfrastructure/Store.swift` / PalaceAuth `Effect.swift` (Contract B)
- Everything in `MyBooksDownloadCenter.swift` EXCEPT the :2076 observer (Contract E).

## What public types change
- `TPPBookState.allowedTransitions` gains 2 pairs; `canTransition` becomes live.
- `TPPBookRegistry` gains a FED RegistryState publisher (new or revived
  `syncStatePublisher`) + a holds-changed publisher; loses `postStateNotification`.
- `.TPPBookRegistryStateDidChange` removed as a public seam (iff unused).

## Test contracts
- `TPPBookRegistryMutationContractTests`: (a) each of the 2 newly-legal transitions
  passes `canTransition`; an illegal one (e.g. `.unregistered -> .downloadSuccessful`)
  trips the DEBUG path via an injected violation handler (do not crash the suite).
  (b) **Regression guard for the hang:** on a FRESH EMPTY-REGISTRY load, the
  SAML-sync observer (registry :455) AND the launch-reconciliation observer (MBDC
  :2076) STILL FIRE via the RegistryState publisher (zero per-book emissions).
- Each migrated observer: behavioral test it reacts to its assigned publisher.
- 100% mutation on the `canTransition` call site + the RegistryState feed points.

## Definition of Done — TWO TIERS ("ship today, verify Monday")
**TODAY (implementer, fast/local — do NOT run the full ~7k CI suite):**
- All scoped files IMPLEMENTED; changed files COMPILE clean:
  `xcodebuild -project Palace.xcodeproj -scheme Palace -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build`.
- Diff-scoped mutation 100% on the critical lines:
  `python3 scripts/palace_mutate.py --file Palace/Book/Models/TPPBookRegistry.swift --tests PalaceTests/TPPBookRegistryMutationContractTests --diff-only`
  (repeat for `Palace/Book/Models/TPPBookState.swift`).
- Characterization + unit tests (incl. the empty-registry hang guard) PASS via
  `-only-testing:PalaceTests/TPPBookRegistryMutationContractTests` (+ each migrated-observer test).
- Transcript + DoD evidence pasted.

**MONDAY MERGE GATE (orchestrator only):** full CI-parity suite
(`scripts/xcode-test-optimized.sh`) green + `/forge-review` 3 SoD reviewers +
`arch drift` clean. Nothing merges to `develop` until Monday-green.

## Verification criteria (orchestrator runs at Phase 4.5)
```bash
# AC0 (NEW): the 2 legitimate transitions are in the corrected set BEFORE enforcement,
#            with the 3 sources cited in a comment
grep -Eq 'downloadSuccessful.*downloadNeeded|\.downloadNeeded' Palace/Book/Models/TPPBookState.swift
grep -Eq 'ReaderService|AudiobookSessionManager|DiskBudgetManager' Palace/Book/Models/TPPBookState.swift

# AC1: setState consults canTransition (enforcement wired)
grep -q 'canTransition' Palace/Book/Models/TPPBookRegistry.swift

# AC2: canTransition no longer dead
test "$(grep -rl 'canTransition' Palace --include='*.swift' | grep -v 'TPPBookState.swift' | wc -l | tr -d ' ')" -ge 1

# AC3 (NEW): a RegistryState lifecycle publisher is CREATED AND FED (not the dead one)
#            — assert a .send into the sync/registry-state subject exists
grep -Eq 'syncStateSubject\.send|registryStateSubject\.send|registryStatePublisher' Palace/Book/Models/TPPBookRegistry.swift

# AC4: both posts DELETED
! grep -q 'func postStateNotification' Palace/Book/Models/TPPBookRegistry.swift
test "$(grep -c 'post(name: .TPPBookRegistryStateDidChange' Palace/Book/Models/TPPBookRegistry.swift)" = "0"

# AC5: NO production observer of the old notification remains
test "$(grep -rlE 'publisher\(for: .TPPBookRegistryStateDidChange\)|forName: .TPPBookRegistryStateDidChange|for: .TPPBookRegistryStateDidChange' Palace --include='*.swift' | wc -l | tr -d ' ')" = "0"

# AC6: the 2 external posters no longer hand-post the notification (re-pointed)
! grep -q 'post(name: .TPPBookRegistryStateDidChange' Palace/Holds/HoldsViewModel.swift
! grep -q 'post(name: .TPPBookRegistryStateDidChange' Palace/Settings/DeveloperSettings/DeveloperSettingsViewModel.swift

# AC7: per-book observers use bookStatePublisher
for f in \
  Palace/CatalogUI/ViewModels/ActiveSessionsViewModel.swift \
  Palace/CatalogUI/Views/CatalogLaneMoreView.swift \
  Palace/CatalogUI/Views/CatalogSearchView.swift \
  Palace/Book/UI/BookDetail/BookDetailView.swift \
  Palace/Book/UI/BookDetail/HalfSheetview.swift \
  Palace/MyBooks/MyBooks/MyBooksViewModel.swift ; do
    grep -q 'bookStatePublisher' "$f" || { echo "NOT MIGRATED (per-book): $f"; exit 1; }
done

# AC8 (NEW): the 2 lifecycle observers use the RegistryState publisher, NOT bookStatePublisher
grep -Eq 'registryStatePublisher|syncStatePublisher' Palace/Book/Models/TPPBookRegistry.swift
grep -Eq 'registryStatePublisher|syncStatePublisher' Palace/MyBooks/MyBooksDownloadCenter.swift

# AC9 (NEW): empty-registry hang regression guard is present in the contract test
grep -Eiq 'emptyRegistry|freshSignIn|launchReconciliation|samlSync' PalaceTests/Contract/TPPBookRegistryMutationContractTests.swift

# AC10: registry mutation-path contract test exists
test -f PalaceTests/Contract/TPPBookRegistryMutationContractTests.swift
grep -q 'ContractSnapshot.assert' PalaceTests/Contract/TPPBookRegistryMutationContractTests.swift

# AC11: Sideload untouched (Contract D boundary)
#       (orchestrator: assert C's diff does not modify Palace/MyBooks/Sideload/**)
```
