# Contract C — Kill Registry Dual-Write + Enforce allowedTransitions (WS3)

**Module:** Book (TPPBookRegistry / TPPBookState) + full observer migration (6 modules)
**Risk:** critical_path (TPPBookRegistry is THE single source of truth for book state)
**Depends on:** A (doctrine declares the enforcement point + SoT scope)

> **FULL SCOPE — no C-now/C-follow-up split.** This contract does the COMPLETE
> dual-write kill in one landing: enforce transitions AND migrate ALL 9 observers
> AND delete both notification posts. Internal ordering is **enforce-before-purge**
> (wire the Combine path + enforcement first, migrate every observer, THEN delete
> the deprecated posts last so nothing is orphaned).

## Verified starting facts
- Deprecated dual-write: `TPPBookRegistry.postStateNotification`
  (`Palace/Book/Models/TPPBookRegistry.swift:639`, `@available(*, deprecated,
  message: "Use Combine publishers instead.")`) posts `.TPPBookRegistryStateDidChange`
  (`:642`), called from EVERY state path (`:553,:570,:586,:600,:614`). A SECOND
  direct post lives in the sync path (`:283`).
- Combine replacements already exist: `registryPublisher` / `bookStatePublisher`
  (`:313`) / `syncStatePublisher`.
- **All 9 observers (6 modules) — verified, ALL migrate in this contract:**
  1. `Palace/CatalogUI/ViewModels/ActiveSessionsViewModel.swift:135`
  2. `Palace/CatalogUI/Views/CatalogLaneMoreView.swift:122`
  3. `Palace/CatalogUI/Views/CatalogSearchView.swift:112`
  4. `Palace/AppInfrastructure/AppTabHostView.swift:456`
  5. `Palace/Book/UI/BookDetail/BookDetailView.swift:134`
  6. `Palace/Book/UI/BookDetail/HalfSheetview.swift:227`
  7. `Palace/MyBooks/MyBooksDownloadCenter.swift:2076` (one-shot observer)
  8. `Palace/MyBooks/MyBooks/MyBooksViewModel.swift:338`
  9. `Palace/Book/Models/TPPBookRegistry.swift:455` (registry's OWN internal
     self-observer — re-point to the internal Combine path)
- **External POSTERS** that must ALSO stop firing the notification (or be re-pointed
  to a registry API): `Palace/Holds/HoldsViewModel.swift:249`,
  `Palace/Settings/DeveloperSettings/DeveloperSettingsViewModel.swift:741`.
- `allowedTransitions` (`Palace/Book/Models/TPPBookState.swift:91`) + `canTransition`
  (`:151`) declared but referenced by NO production file; `setState`
  (`TPPBookRegistry.swift:605`) does not call them. **Unenforced, confirmed.**

## Internal ordering (enforce-before-purge — non-negotiable)
1. **Enforce allowedTransitions at `setState` (`:605`).** After computing
   `previousState`, call `TPPBookState.canTransition(from:previousState,to:state)`.
   On violation: `assertionFailure` in DEBUG + telemetry/log in RELEASE, then **still
   apply** the transition (never DROP state — dropping is riskier than logging).
   Expand `allowedTransitions` (`TPPBookState.swift:91`) to cover every transition the
   Contract-E green snapshots exercise (soft-couple to E; seed from facts.json flows
   if E not yet green, mark TODO for pairs E later confirms).
2. **Migrate ALL 9 observers to `bookStatePublisher`** (Combine). Each migrated site
   reacts to a publisher emission, not the NotificationCenter name. Re-point the
   registry's own internal self-observer (`:455`) to the internal Combine path.
3. **Re-point the 2 external posters** — `HoldsViewModel:249` and
   `DeveloperSettingsViewModel:741` stop hand-posting `.TPPBookRegistryStateDidChange`;
   route through a registry method or drop if redundant (their observers moved to
   Combine in step 2).
4. **DELETE both posts LAST**: remove `postStateNotification` (`:639`) and its call
   sites (`:553,:570,:586,:600,:614`), and remove the direct sync-path post (`:283`).
   Remove the `.TPPBookRegistryStateDidChange` name decl in `NSNotification+TPP.swift`
   ONLY if no consumer remains (grep must be clean).

## Scope (exact files)
- `Palace/Book/Models/TPPBookRegistry.swift` (enforce + delete both posts + self-observer)
- `Palace/Book/Models/TPPBookState.swift` (expand allowedTransitions if needed)
- `Palace/CatalogUI/ViewModels/ActiveSessionsViewModel.swift`
- `Palace/CatalogUI/Views/CatalogLaneMoreView.swift`
- `Palace/CatalogUI/Views/CatalogSearchView.swift`
- `Palace/AppInfrastructure/AppTabHostView.swift`
- `Palace/Book/UI/BookDetail/BookDetailView.swift`
- `Palace/Book/UI/BookDetail/HalfSheetview.swift`
- `Palace/MyBooks/MyBooks/MyBooksViewModel.swift`
- `Palace/MyBooks/MyBooksDownloadCenter.swift` — **the :2076 one-shot observer block
  ONLY** (Contract E owns the rest of this file; C touches only the observer)
- `Palace/Holds/HoldsViewModel.swift` — **the :249 post ONLY**
- `Palace/Settings/DeveloperSettings/DeveloperSettingsViewModel.swift` — **the :741 post ONLY**
- `Palace/AppInfrastructure/NSNotification+TPP.swift` (remove name decl iff unused)
- NEW test: `PalaceTests/Contract/TPPBookRegistryMutationContractTests.swift`

## Off-limits
- `Palace/MyBooks/Sideload/**` (Contract D)
- `Palace/AppInfrastructure/Store.swift` / PalaceAuth `Effect.swift` (Contract B)
- Everything in `MyBooksDownloadCenter.swift` EXCEPT the :2076 observer (Contract E
  owns the pipeline — C edits only the observer block; E edits the decision cores).

## What public types change
- No `TPPBookRegistry` protocol-method signature changes; `setState` gains internal
  enforcement; `postStateNotification` removed. `TPPBookState.canTransition` becomes
  live. `.TPPBookRegistryStateDidChange` removed as a public seam (iff unused).

## Test contracts
- `TPPBookRegistryMutationContractTests`: legal transition emits on
  `bookStatePublisher` + passes `canTransition`; illegal transition
  (e.g. `.unregistered` → `.downloadSuccessful`) trips the DEBUG assertion path via an
  injected violation handler (do not crash the suite).
- Each migrated observer: behavioral test that the VM/view reacts to a
  `bookStatePublisher` emission (NOT "publisher exists").
- 100% mutation on the `canTransition` call site in `setState` and the removed-post
  region.

## Definition of Done — TWO TIERS ("ship today, verify Monday")
**TODAY (implementer, fast/local — do NOT run the full ~7k CI suite):**
- All scoped files IMPLEMENTED; changed files COMPILE clean:
  `xcodebuild -project Palace.xcodeproj -scheme Palace -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build`.
- Diff-scoped mutation, 100% on the critical lines:
  `python3 scripts/palace_mutate.py --file Palace/Book/Models/TPPBookRegistry.swift --tests PalaceTests/TPPBookRegistryMutationContractTests --diff-only`
  (repeat for `Palace/Book/Models/TPPBookState.swift`).
- Characterization + unit tests written and PASS via targeted selectors, e.g.
  `-only-testing:PalaceTests/TPPBookRegistryMutationContractTests` (+ each migrated-observer test class).
- Transcript + DoD evidence pasted.

**MONDAY MERGE GATE (orchestrator only — NOT the implementer):**
- Full CI-parity suite green: `scripts/xcode-test-optimized.sh`.
- `/forge-review` — 3 SoD reviewers (architect + qa_test + blast_radius) approve.
- `arch drift` clean (Contract F's `scripts/arch-drift-check.py` exits 0).
- Nothing merges to `develop` until Monday-green.

## Verification criteria (orchestrator runs at Phase 4.5)
```bash
# AC1: setState consults canTransition (enforcement wired)
grep -q 'canTransition' Palace/Book/Models/TPPBookRegistry.swift

# AC2: canTransition no longer dead (referenced outside its own file)
test "$(grep -rl 'canTransition' Palace --include='*.swift' | grep -v 'TPPBookState.swift' | wc -l | tr -d ' ')" -ge 1

# AC3: the deprecated post is DELETED (function + both posts gone)
! grep -q 'func postStateNotification' Palace/Book/Models/TPPBookRegistry.swift
test "$(grep -c 'post(name: .TPPBookRegistryStateDidChange' Palace/Book/Models/TPPBookRegistry.swift)" = "0"

# AC4: NO production observer of the old notification remains (full migration;
#      only an unused name decl in NSNotification+TPP.swift may linger)
test "$(grep -rlE 'publisher\(for: .TPPBookRegistryStateDidChange\)|forName: .TPPBookRegistryStateDidChange|for: .TPPBookRegistryStateDidChange' Palace --include='*.swift' | wc -l | tr -d ' ')" = "0"

# AC5: the 2 external posters no longer hand-post the notification
! grep -q 'post(name: .TPPBookRegistryStateDidChange' Palace/Holds/HoldsViewModel.swift
! grep -q 'post(name: .TPPBookRegistryStateDidChange' Palace/Settings/DeveloperSettings/DeveloperSettingsViewModel.swift

# AC6: migrated observers now use the Combine publisher
for f in \
  Palace/CatalogUI/ViewModels/ActiveSessionsViewModel.swift \
  Palace/CatalogUI/Views/CatalogLaneMoreView.swift \
  Palace/CatalogUI/Views/CatalogSearchView.swift \
  Palace/AppInfrastructure/AppTabHostView.swift \
  Palace/Book/UI/BookDetail/BookDetailView.swift \
  Palace/Book/UI/BookDetail/HalfSheetview.swift \
  Palace/MyBooks/MyBooks/MyBooksViewModel.swift ; do
    grep -q 'bookStatePublisher\|registryPublisher' "$f" || { echo "NOT MIGRATED: $f"; exit 1; }
done

# AC7: registry mutation-path contract test exists
test -f PalaceTests/Contract/TPPBookRegistryMutationContractTests.swift
grep -q 'ContractSnapshot.assert' PalaceTests/Contract/TPPBookRegistryMutationContractTests.swift

# AC8: Sideload untouched (Contract D boundary)
#      (orchestrator: assert C's diff does not modify Palace/MyBooks/Sideload/**)
```
