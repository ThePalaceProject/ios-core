# Module A — SideloadedBookRegistry + Sync-Exemption + AppContainer wiring

**Swarm:** swarm_495a88d9 (side-loading)
**Risk:** `critical_path` — touches `BookRegistrySync` reconciliation (the code that
deletes local books + on-disk files). Requires architect + SoD (blast_radius)
review regardless of LOC. See CLAUDE.md "Risk-driven rigor bar" + "Auth-error /
critical-path" canon.
**Depends on:** none (foundation). Modules C and D depend on THIS.
**Tickets:** PP-2678 (registry) + the critical sync-exemption from the plan.

## Why A bundles registry + sync-exemption + AppContainer construction
The sync-exemption set is *driven by* `SideloadedBookRegistry.identifiers`, and the
provider that feeds `BookRegistrySync` reads it via `AppContainer`. These three
edits are one atomic seam — splitting them yields a half-wired exemption that the
next `sync()` defeats (the exact load-bearing hazard in the plan). One contract,
one critical-path implementer.

## Component 1 — `SideloadedBookRegistry` (PP-2678, NEW)
Dedicated local-only persistence, separate manifest from `registry.json`.
- **Storage:** own JSON manifest. Recommend **Application Support** (consistent
  with `registry.json`, backup-excluded) — treat the ticket's "Documents folder"
  wording as illustrative (plan open item; confirm in transcript). Path helper:
  mirror `BookRegistrySync.registryUrl(for:)` style but a distinct filename, e.g.
  `sideloaded/sideloaded.json`. Local-only, NOT account-scoped-synced.
- **Model:** persists each sideloaded `TPPBook` via `book.dictionaryRepresentation()`
  round-trip + the original imported filename (per-entry). Re-hydrate with the
  matching `TPPBook(dictionary:)` initializer.
- **API (exact):**
  - `func add(book: TPPBook, fileURL: URL)`  (records book + original filename)
  - `func remove(identifier: String)`
  - `func rename(identifier: String, to newTitle: String)`
  - `func update(book: TPPBook)`
  - `var allBooks: [TPPBook]` (drives the lane, Module D)
  - `var identifiers: Set<String>` (drives the sync-exemption set — MUST be a
    cheap synchronous read; it is called inside `BookRegistrySync.sync()`)
- **Concurrency:** MUST be thread-safe and `Sendable` (internal `NSLock` +
  `@unchecked Sendable` with a documented invariant, per module-3 playbook —
  do NOT use `nonisolated(unsafe)`). `identifiers` is read from the main-actor
  sync-reconciliation path AND from the manager's import path (Module C), so it
  cannot be `@MainActor`-only. Persist synchronously on mutation, or serialize
  writes on an internal queue; a corrupt/empty/missing manifest must load as an
  empty registry (no crash).

## Component 2 — Sync-exemption in `BookRegistrySync` (CRITICAL)
- Add init param to `BookRegistrySync.init` (`BookRegistrySync.swift:64-75`):
  `sideloadedIDsProvider: @escaping () -> Set<String> = { AppContainer.production().sideloadedBookRegistry.identifiers }`.
  Store it as a `let` (immutable — preserves the `@unchecked Sendable` invariant
  documented at `:11-30`; do NOT add a mutable var). Mirror the existing lazy
  `downloadCenterProvider` precedent (`:43`, `:215`) — resolving `AppContainer`
  lazily avoids the launch-time dispatch_once cycle.
- In `sync()` reconciliation, immediately after
  `var recordsToDelete = Set<String>(registry.keys)` (**`BookRegistrySync.swift:406`**),
  add: `recordsToDelete.subtract(sideloadedIDsProvider())`.
  This exempts sideloaded ids from BOTH the `registry.removeValue` un-registration
  (`:480-481`) AND the `deleteLocalContent` on-disk delete (`:496-497`).
- Thread the provider through **both** `TPPBookRegistry` inits that construct a
  `BookRegistrySync` (`TPPBookRegistry.swift:212` and `:242`). Passing the default
  is acceptable, but pass it EXPLICITLY at both sites for clarity + so the
  contract-reconciliation gate sees the wiring.

## Component 3 — AppContainer exposure (ADDITIVE ONLY)
- Add a lazy-cached computed property `sideloadedBookRegistry: SideloadedBookRegistry`
  to `AppContainer`, backed by a `private static var _sideloadedBookRegistry`,
  mirroring the `bookOpenTracker` cache pattern (`AppContainer.swift:229-236`).
- **DO NOT** touch the big `init(...)` (`:283-325`), `_buildCachedAppContainer()`
  return statement (`:469-494`), or the two `with*Presenter` copy methods
  (`:106`, `:158`). The property is additive so Module C's later append and the
  orchestrator's final reconcile stay conflict-free.
- **`_resetForTesting()` reset (REQUIRED, not optional).** `SideloadedBookRegistry`
  is a file-backed shared static cache, so it WILL bleed manifest state across test
  classes. Add `_sideloadedBookRegistry = nil` to `_resetForTesting()` (method at
  `AppContainer.swift:546`; nil the static in the same style as the audiobook
  statics reset — the exact line is ~`:585-587`, re-locate it, the earlier `:584-588`
  cite was ~40 lines stale). The architect review confirmed this is a YES, not an
  "only if."

## Component 4 — Account-stable file resolution in `BookFileManager` (REQUIRED)
`BookFileManager.fileUrl` is scoped to `currentAccountId`
(`fileUrl(for identifier:)` → `fileUrl(for: identifier, account: currentAccountId)`
→ `directory(for: account)/content/<sha256(id)>.<ext>`). The reader resolves a
book via `TPPBook.url` → `downloadCenter.fileUrl(for: identifier)` →
`bookFileManager.fileUrl(for: identifier)` (`MyBooksDownloadCenter.swift:1625-1631`).
`SideloadedBookRegistry` is deliberately **account-agnostic**, so if a sideloaded
file is written under one library's content dir and the user switches libraries,
`currentAccountId` changes and the read resolves the WRONG directory → nil → open
fails. This is a real cross-account defect, not a nicety.

**Resolution (pin both write and read to ONE fixed account):**
- Expose a single constant for the sideload content account:
  `static let sideloadContentAccountID = AccountsManager.TPPAccountUUIDs[0]`
  (the primary/no-subpath account — `TPPBookContentMetadataFilesHelper.directory(for:)`
  at `:32` appends NO sub-path for `TPPAccountUUIDs[0]`, giving the stable
  `<AppSupport>/<bundleID>/content/` dir). Put the constant on `SideloadedBookRegistry`
  (or `BookFileManager`) so BOTH Module A (read) and Module C (write) reference the
  SAME value — do NOT let the two sides pick the account independently.
- In `BookFileManager.fileUrl(for identifier:, account:)` (`:59`), before resolving,
  if `identifier` is sideloaded (∈ `AppContainer.production().sideloadedBookRegistry.identifiers`
  — the same lazy provider pattern, evaluated at read time, no init cycle),
  substitute `account = <sideloadContentAccountID>`. This is the single READ choke
  point every `fileUrl(for: identifier)` overload funnels through, so it fixes the
  reader path without touching `MyBooksDownloadCenter`.
- Module C's import writes via `fileUrl(for: book, account: <sideloadContentAccountID>)`
  (explicit account overload `:69` — no interception needed on the write side because
  C passes the account directly). C consumes the constant from A.

## Files IN scope
- `Palace/MyBooks/Sideload/SideloadedBookRegistry.swift` (NEW)
- `Palace/Book/Models/BookRegistrySync.swift` (modify — provider param + subtract at :406)
- `Palace/Book/Models/TPPBookRegistry.swift` (modify — pass provider at :212 & :242 ONLY)
- `Palace/AppInfrastructure/AppContainer.swift` (modify — ADD lazy-cached property + static cache + `_resetForTesting` nil ONLY; see Component 3 boundaries)
- `Palace/MyBooks/BookFileManager.swift` (modify — account-stable read resolution for sideloaded ids + the `sideloadContentAccountID` constant; Component 4)
- `PalaceTests/MyBooks/Sideload/SideloadedBookRegistryTests.swift` (NEW)
- `PalaceTests/Book/BookRegistrySyncSideloadExemptionTests.swift` (NEW — critical regression)
- `PalaceTests/MyBooks/BookFileManagerSideloadResolutionTests.swift` (NEW — account-stable resolution)
- New Swift files added to BOTH targets via `ruby scripts/pbxproj_add_swift.rb`
  (NEVER hand-edit `project.pbxproj`). Test files auto-route to `PalaceTests`.

## Files OFF-LIMITS
- `Palace/FeatureFlags/RemoteFeatureFlags.swift`, `FirebaseManager.swift` (Module B).
- `Palace/MyBooks/Sideload/SideloadedBookManager.swift` + all Settings files (Module C).
- `Palace/CatalogUI/*` (Module D).
- AppContainer big `init` / `_buildCachedAppContainer` return / `with*Presenter`
  copies — additive-only (Component 3).
- The reconciliation guards `shouldSkipBulkDeletion` / large-deletion warn logic
  (`:449-467`) — do not alter; the `subtract` goes at :406, before those.

## Test contract
1. `SideloadedBookRegistryTests` — construct `SideloadedBookRegistry(...)` with an
   injected temp directory (add a directory-override init seam like
   `BookFileManager`'s `directoryProvider`). Prove:
   - Manifest round-trip: add 2 books → reload a fresh instance → `allBooks`
     identical (identifiers, titles, original filenames).
   - `add` then `remove` → `identifiers` no longer contains it.
   - `rename` changes the persisted title; reload confirms.
   - `identifiers` reflects current membership after add/remove.
   - Edge cases: duplicate add (same id) does not double-insert; missing/corrupt/
     empty manifest file loads as empty (no throw/crash); unsupported/garbage JSON
     tolerated.
2. `BookRegistrySyncSideloadExemptionTests` — **THE critical regression.**
   Construct `BookRegistrySync(store:accountsManager:downloadCenterProvider:opdsFeedServiceProvider:sideloadedIDsProvider:)`
   directly with spy dependencies. Seed the store with a `.downloadSuccessful`
   book whose id is "sideloaded-1". Drive `sync()` with a stubbed loans feed that
   does NOT contain "sideloaded-1", and `sideloadedIDsProvider` returning
   `["sideloaded-1"]`. Assert:
   - After sync, "sideloaded-1" is STILL in the registry with `.downloadSuccessful`.
   - The spy `downloadCenter.deleteLocalContent` was NOT called for it.
   - Control case (same test class, second method): with an EMPTY exemption set,
     the same book IS evicted + `deleteLocalContent` IS called — proving the
     exemption is what saved it, not some other guard (mutation-grade contrast).
3. `BookFileManagerSideloadResolutionTests` — construct `BookFileManager` with a
   `directoryProvider` temp override and a stubbed `sideloadedBookRegistry`
   identifier set. Prove: a sideloaded id resolves to the FIXED
   `sideloadContentAccountID` directory **even when `accountsManager.currentAccountId`
   is a different library** (set currentAccountId to a non-primary account, assert
   the resolved path is the primary/no-subpath content dir). Contrast: a
   non-sideloaded id still resolves against `currentAccountId` (no behavior change
   for normal books).

## Verification criteria (grep-able, per acceptance criterion)
- SUT instantiation (DoD #1):
  - `grep -c "SideloadedBookRegistry(" PalaceTests/MyBooks/Sideload/SideloadedBookRegistryTests.swift` ≥ 2
  - `grep -c "BookRegistrySync(" PalaceTests/Book/BookRegistrySyncSideloadExemptionTests.swift` ≥ 1
- Exemption present in production: `grep -c "recordsToDelete.subtract" Palace/Book/Models/BookRegistrySync.swift` == 1
- Provider param present: `grep -c "sideloadedIDsProvider" Palace/Book/Models/BookRegistrySync.swift` ≥ 2 (param + use)
  and `grep -c "sideloadedIDsProvider" Palace/Book/Models/TPPBookRegistry.swift` == 2 (both inits)
- AppContainer additive only: `git diff Palace/AppInfrastructure/AppContainer.swift` must NOT touch lines inside `init(` param list or the `_buildCachedAppContainer` `return AppContainer(` block; confirm with a review of the hunk ranges. (The `_resetForTesting` nil is the one exception — a single added line in that method.)
- Account-stable resolution present: `grep -c "sideloadContentAccountID" Palace/MyBooks/BookFileManager.swift` ≥ 1 and `grep -c "sideloadedBookRegistry" Palace/MyBooks/BookFileManager.swift` ≥ 1 (the membership check).
- Resolution test proves cross-account stability: `grep -c "BookFileManager(" PalaceTests/MyBooks/BookFileManagerSideloadResolutionTests.swift` ≥ 1, and the test sets `currentAccountId` to a non-primary account and asserts the primary/no-subpath dir (multi-step body).
- Multi-step / contrast body (DoD #3): the exemption regression test class has
  BOTH the "survives with exemption" and "evicted without exemption" methods —
  `grep -c "func test" PalaceTests/Book/BookRegistrySyncSideloadExemptionTests.swift` ≥ 2, and grep the file for both `deleteLocalContent` assertion directions (called / not-called).
- Wiring-coverage (DoD #7): line-coverage report shows the exemption test hits
  `BookRegistrySync.swift:406` and the `deleteLocalContent` branch at `:496-497`.
- **Mutation (DoD #5, MANDATORY critical path):**
  `python3 scripts/palace_mutate.py --file Palace/Book/Models/BookRegistrySync.swift --tests PalaceTests/BookRegistrySyncSideloadExemptionTests --diff-only`
  → **100% kill on the touched lines** (the `subtract` line and provider use; the
  contrast test must kill the "subtract removed" mutant). Also run
  `--file Palace/MyBooks/Sideload/SideloadedBookRegistry.swift --tests PalaceTests/SideloadedBookRegistryTests --diff-only` ≥ 50%.
- `check-blast-radius.py --quiet` exit 0 (new AppContainer property is not a
  test-only init param; provider default is not a discarded result).
- `check-contract-reconciliation.py --commit-msg <file>` exit 0 for the "adds
  SideloadedBookRegistry / adds sync exemption" claims.
- `check-superpartner-spectrum.py --quiet` exit 0.
- Build clean (both targets); `scripts/verify-pr.sh --quick` PASS.
