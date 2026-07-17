# Contract C — Kill Registry Dual-Write + Enforce allowedTransitions (WS3)

**Module:** Book (TPPBookRegistry / TPPBookState) + observer migration
**Risk:** critical_path (TPPBookRegistry is THE single source of truth for book state)
**Depends on:** A (doctrine declares the enforcement point + SoT scope)

## Verified starting facts
- Deprecated dual-write: `TPPBookRegistry.postStateNotification`
  (`Palace/Book/Models/TPPBookRegistry.swift:639`, `@available(*, deprecated,
  message: "Use Combine publishers instead.")`) posts `.TPPBookRegistryStateDidChange`
  (`:642`) and is called from EVERY setState/addBook/removeBook path
  (`:553,:570,:586,:600,:614`) plus a direct post in the sync path (`:283`).
- The Combine replacements already exist: `registryPublisher` / `bookStatePublisher`
  (`:313`) / `syncStatePublisher`.
- **Observer blast radius (9 consumers across 6 modules) — verified:**
  `Palace/CatalogUI/ViewModels/ActiveSessionsViewModel.swift:135`,
  `Palace/CatalogUI/Views/CatalogLaneMoreView.swift:122`,
  `Palace/CatalogUI/Views/CatalogSearchView.swift:112`,
  `Palace/AppInfrastructure/AppTabHostView.swift:456`,
  `Palace/Book/UI/BookDetail/BookDetailView.swift:134`,
  `Palace/Book/UI/BookDetail/HalfSheetview.swift:227`,
  `Palace/MyBooks/MyBooksDownloadCenter.swift:2076` (one-shot),
  `Palace/MyBooks/MyBooks/MyBooksViewModel.swift:338`.
- **External POSTERS (not just observers)** that also fire the notification:
  `Palace/Holds/HoldsViewModel.swift:249`,
  `Palace/Settings/DeveloperSettings/DeveloperSettingsViewModel.swift:741`.
- `allowedTransitions` (`Palace/Book/Models/TPPBookState.swift:91`) + `canTransition`
  (`:151`) are declared but referenced by NO production file — `setState`
  (`TPPBookRegistry.swift:605`) does not call them. **Unenforced, confirmed.**

## Realistic one-day scope (conservative — the full observer purge is a follow-up)
This is high blast-radius; a hard removal of the post + full observer migration
in one pass is NOT safely landable and MUST NOT be attempted here. Do THIS:

1. **Enforce allowedTransitions at `setState` — log-only in RELEASE, hard in DEBUG/tests.**
   - In `TPPBookRegistry.setState` (`:605`), after computing `previousState`, call
     `TPPBookState.canTransition(from: previousState, to: state)`. On violation:
     `assertionFailure` in DEBUG + a telemetry/log line in RELEASE, then **still
     apply** the transition (do NOT drop state — dropping is riskier than logging).
   - Expand `allowedTransitions` to cover every transition the Contract-E green
     snapshots actually exercise (soft-couple to E; if E is not yet green, seed
     from the documented borrow/return flows in facts.json and mark TODO).
2. **Gate the deprecated post behind a single feature switch** so it can be turned
   off without deleting the observers yet. Keep `postStateNotification` firing by
   default (parity), but route it through one private `emitLegacyStateNotification`
   guarded by a `RemoteFeatureFlags` / build flag, so a follow-up flips it off.
3. **Migrate the 2 lowest-risk observers** to `bookStatePublisher` as proof of the
   pattern (recommend `ActiveSessionsViewModel`, `CatalogSearchView` — self-contained
   Combine subscribers already). Leave the remaining 6 + 2 external posters as
   **tracked debt** with a named finish-line in the doctrine.
4. Add a **TPPBookRegistry mutation-path contract test** (CLAUDE.md names this a
   good contract candidate) pinning: `setState` → canTransition checked →
   `bookStatePublisher` emits. This lives in Contract E's test file set ONLY IF E
   owns it; otherwise create `PalaceTests/Contract/TPPBookRegistryMutationContractTests.swift`
   here (register via `scripts/pbxproj_add_swift.rb`).

## Scope (exact files)
- `Palace/Book/Models/TPPBookRegistry.swift` (setState enforcement + post gating)
- `Palace/Book/Models/TPPBookState.swift` (expand allowedTransitions if needed)
- `Palace/CatalogUI/ViewModels/ActiveSessionsViewModel.swift` (migrate observer)
- `Palace/CatalogUI/Views/CatalogSearchView.swift` (migrate observer)
- NEW test: `PalaceTests/Contract/TPPBookRegistryMutationContractTests.swift`

## Off-limits
- `Palace/MyBooks/**` (owned by Contract E — including MyBooksDownloadCenter's
  one-shot observer at :2076; do NOT migrate it here)
- `Palace/MyBooks/Sideload/**` (owned by Contract D)
- The remaining 6 observers + 2 external posters — leave AS-IS (tracked debt).
  Do not touch `HoldsViewModel.swift` / `DeveloperSettingsViewModel.swift` posts.
- `Palace/AppInfrastructure/Store.swift` / `Effect.swift` (Contract B)

## What public types change
- No signature changes to `TPPBookRegistry`'s protocol methods. `setState` gains
  internal enforcement only. `TPPBookState.canTransition` moves from
  unused-but-public to called.

## Test contracts
- New `TPPBookRegistryMutationContractTests`: a legal transition emits on
  `bookStatePublisher` and passes `canTransition`; an illegal transition
  (e.g. `.unregistered` → `.downloadSuccessful`) trips the DEBUG assertion path
  (test via an injected violation handler, not by crashing the suite).
- Migrated observers: add/keep a test that the view-model reacts to a
  `bookStatePublisher` emission (behavioral, not "publisher exists").
- 100% mutation on the new `canTransition` call site in `setState`.

## Verification criteria (Phase 4.5)
```bash
# AC1: setState now consults canTransition (enforcement wired)
grep -q 'canTransition' Palace/Book/Models/TPPBookRegistry.swift

# AC2: canTransition is no longer dead code (referenced outside its own file)
test "$(grep -rl 'canTransition' Palace --include='*.swift' | grep -v 'TPPBookState.swift' | wc -l | tr -d ' ')" -ge 1

# AC3: the deprecated post is now gated behind one switch (single emit funnel)
grep -Eq 'emitLegacyStateNotification|legacyStateNotificationEnabled|FeatureFlag' Palace/Book/Models/TPPBookRegistry.swift

# AC4: the two proof-of-pattern observers moved to the Combine publisher
grep -q 'bookStatePublisher' Palace/CatalogUI/ViewModels/ActiveSessionsViewModel.swift
grep -q 'bookStatePublisher' Palace/CatalogUI/Views/CatalogSearchView.swift

# AC5: a registry mutation-path contract test exists
test -f PalaceTests/Contract/TPPBookRegistryMutationContractTests.swift
grep -q 'ContractSnapshot.assert' PalaceTests/Contract/TPPBookRegistryMutationContractTests.swift

# AC6: MyBooks / Sideload / remaining observers untouched by THIS contract
#      (orchestrator: assert the diff for C does not modify those paths)
```
