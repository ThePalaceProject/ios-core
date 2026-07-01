# Module C — SideloadedBookManager + Settings + launch rehydration

**Swarm:** swarm_495a88d9 (side-loading)
**Risk:** `critical_path` — mints synthetic `TPPBook`s and registers them into the
main `TPPBookRegistry`; a mis-registration interacts with the sync-exemption and
DRM stack. Architect + SoD (blast_radius) review required.
**Depends on:** A (`SideloadedBookRegistry`, `TPPBookRegistry.addBook`,
`AppContainer.sideloadedBookRegistry`), B (`RemoteFeatureFlags.isSideLoadingEnabled`).
**Ticket:** PP-2677.

## Component 1 — `SideloadedBookManager` (NEW)
`Palace/MyBooks/Sideload/SideloadedBookManager.swift`.

### Import (`import(fileURL: URL) throws / async throws`)
1. **Classify** by extension/MIME → `TPPBookContentType.from(mimeType:)`
   (`TPPContentType.swift:20`). Must resolve to `.epub` / `.pdf` / `.audiobook`;
   reject `.unsupported` with a surfaced error (do NOT register).
2. **Mint an open-access `TPPBook`** via the designated init (`TPPBook.swift:122`):
   - generated `identifier` (e.g. `"sideload-" + UUID`; the sha256 of this drives
     the on-disk path).
   - exactly ONE `TPPOPDSAcquisition` whose **MIME matches the content type** so
     both `defaultBookContentType` (`TPPBook.swift:669`) AND
     `BookFileManager.pathExtension` (`BookFileManager.swift:123`) resolve
     correctly (LCP audiobook → `.lcpa`, LCP PDF → `.zip`, else `.epub`). This MIME
     is load-bearing — a wrong MIME → `.unsupported` → the reader shows
     `presentUnsupportedItemError` and never opens.
   - DRM-free / open-access (no `revokeURL`, no bearer token, no `needsAuth`
     acquisition), `imageCache: ImageCache.shared`, `title` from the filename.
3. **Copy the file** to
   `BookFileManager.fileUrl(for: book, account: SideloadedBookRegistry.sideloadContentAccountID)`
   (explicit-account overload `BookFileManager.swift:69`) — the sha256-hashed path.
   **Pin the account to the fixed `sideloadContentAccountID` constant defined by
   Module A** (= `AccountsManager.TPPAccountUUIDs[0]`, the primary/no-subpath dir),
   NOT `currentAccountId`. Sideloaded books are account-agnostic; writing under the
   current library would make the file unresolvable after a library switch. Module
   A owns the matching READ-side resolution (BookFileManager substitutes this same
   fixed account for sideloaded ids), so write and read agree. Consume A's constant
   — do NOT hardcode a second copy of the account value here.
4. **Register:** `SideloadedBookRegistry.add(book:fileURL:)` (dedicated manifest —
   truth) **and** `TPPBookRegistry.addBook(book, state: .downloadSuccessful)`
   (`TPPBookRegistry.swift:387`; state is the 3rd arg).
   - NOTE: the sync-exemption is **automatically** satisfied by adding to
     `SideloadedBookRegistry` — Module A's provider reads `identifiers` live at
     sync time. There is NO separate `syncExemption.insert` call; adding to the
     registry IS the exemption. Do not invent a second exemption store.

### Remove (`remove(identifier:)`)
Reverse: delete the on-disk file, `SideloadedBookRegistry.remove(identifier:)`,
`TPPBookRegistry.removeBook(forIdentifier:)` (`:417`).

### Launch rehydration (`rehydrateAtLaunch()`)
Read `SideloadedBookRegistry.allBooks`; for each not already present in the main
registry, `TPPBookRegistry.addBook(book, state: .downloadSuccessful)`. Idempotent
(running twice does not duplicate).

**Anchor (CORRECTED — the original `:218` cite was wrong).** The rehydration is
wired inside `applicationDidFinishLaunching`, specifically in
`setupBookRegistryAndNotifications()` where `bookRegistry.load()` is called
(`TPPAppDelegate.swift:200`). **`TPPAppDelegate.swift:218` is NOT a launch sync — it
is inside `handleAppRefresh(task:)`, the BGAppRefresh background handler.** The real
first runtime syncs are `applicationDidBecomeActive` (`:330`) and
`AppTabHostView.swift:260` (catalog appear) — both come AFTER
`applicationDidFinishLaunching`.

**Mechanism (CORRECTED — must hook the async load completion, finding 3).**
`bookRegistry.load()` is asynchronous — the comment at `:196-199` states "load()
returns immediately — the disk I/O is dispatched onto the store's own queue." A
synchronous `rehydrateAtLaunch()` right after `load()` returns would run while the
registry is still `.loading`/`.unloaded` and be clobbered when the disk snapshot
lands and transitions to `.loaded`. Therefore rehydration MUST run in the
`load(completion:)` callback (`TPPBookRegistry.load(account:completion:)` at `:269`):

```swift
AppContainer.production().bookRegistry.load {
    AppContainer.production().sideloadedBookManager.rehydrateAtLaunch()
}
```

Hop to main if `rehydrateAtLaunch` touches main-only state (`addBook` is itself
store-queue-safe). The exemption protects persistence regardless of ordering (it
reads the persisted `SideloadedBookRegistry` live), so worst case of a wiring
mistake is "book absent until rehydration runs," not data loss — but wire it
correctly per the above.

## Component 2 — Settings UI (gated by the flag)
- `Palace/Settings/NewSettings/TPPSettingsView.swift` (modify): add a
  `sideLoadingSection` to the `List` (`:104-108`), rendered ONLY when
  `RemoteFeatureFlags.shared.isSideLoadingEnabled` (inline flag read matches the
  existing `:276` usage). Use the `row(title:index:selection:destination:)` helper
  (`:424-434`) with a fresh unique `index` (e.g. 11) and `NavigationLink` →
  `SideLoadingView`.
- `Palace/Settings/NewSettings/SideLoadingView.swift` (NEW): the screen — a
  file-import affordance (SwiftUI `.fileImporter(isPresented:allowedContentTypes:
  onCompletion:)` — there is NO existing `UIDocumentPicker` pattern in the repo, so
  build from scratch; `allowedContentTypes` = epub/pdf/audiobook UTTypes) + a
  "manage" list of imported books (title, delete). Back it with a small
  `SideLoadingViewModel` (`@MainActor ObservableObject`, may live in the same file
  or a sibling) that calls `SideloadedBookManager`. Obtain the manager via
  `AppContainer.production().sideloadedBookManager` (the settings view already
  reads services this way, e.g. `:277`, `:395`) OR construct the VM in
  `TPPSettingsView.init()` mirroring the `librariesVM` `@StateObject` template
  (`:27`,`:35`). No `TPPSettings` key is needed — visibility is gated by the
  RemoteFeatureFlag, not a `TPPSettings` toggle.

## Component 3 — AppContainer exposure (ADDITIVE, appends after Module A)
Add a lazy-cached computed property `sideloadedBookManager: SideloadedBookManager`
+ `private static var _sideloadedBookManager`, mirroring `bookOpenTracker`
(`AppContainer.swift:229-236`). It resolves `self.sideloadedBookRegistry` (from
Module A) + `self.bookRegistry` + `self.downloadCenter` + a `BookFileManager`.
DO NOT touch the big `init`, `_buildCachedAppContainer` return, or `with*Presenter`
copies. Append your property AFTER Module A's `sideloadedBookRegistry` property so
the orchestrator's AppContainer reconcile is a clean concatenation.

## Files IN scope
- `Palace/MyBooks/Sideload/SideloadedBookManager.swift` (NEW)
- `Palace/Settings/NewSettings/SideLoadingView.swift` (NEW; VM may be a 2nd NEW file)
- `Palace/Settings/NewSettings/TPPSettingsView.swift` (modify — add gated section)
- `Palace/AppInfrastructure/AppContainer.swift` (modify — ADD `sideloadedBookManager` property ONLY)
- `Palace/AppInfrastructure/TPPAppDelegate.swift` (modify — rehydration call ONLY, inside the `bookRegistry.load(completion:)` callback in `applicationDidFinishLaunching`/`setupBookRegistryAndNotifications` per the CORRECTED anchor above; do NOT place it in `handleAppRefresh` / near :218)
- `PalaceTests/MyBooks/Sideload/SideloadedBookManagerTests.swift` (NEW)
- `PalaceTests/Contract/SideloadImportContractTests.swift` (NEW — import-pipeline snapshot)
- New Swift files → BOTH targets via `ruby scripts/pbxproj_add_swift.rb` (NEVER hand-edit pbxproj).

## Files OFF-LIMITS
- `SideloadedBookRegistry.swift`, `BookRegistrySync.swift`, `TPPBookRegistry.swift`
  (Module A — consume their surfaces, do not modify).
- `RemoteFeatureFlags.swift` / `FirebaseManager.swift` (Module B — read `isSideLoadingEnabled`).
- `CatalogUI/*`, `AppTabHostView.swift` (Module D).
- `BookFileManager.swift` (consume `fileUrl`/`pathExtension`; do not modify).
- AppContainer big `init` / `_buildCachedAppContainer` return / `with*Presenter`.

## Reader-open sufficiency (confirmed — no extra production edits)
Tracing confirms: for EPUB (Reader2) and PDF (Reader3), a book registered
`.downloadSuccessful` with the file at `BookFileManager.fileUrl` opens with NO
other production changes — the reader resolves `book.url` →
`downloadCenter.fileUrl(for:identifier)` → sha256 path (`TPPBook+Additions.swift:15`,
`BookFileManager.swift:59-73`); no download-record / OPDS-refetch / availability
gate. The `#if FEATURE_DRM_CONNECTOR` Adobe gate (`BookDetailViewModel.swift:848`)
is skipped for a no-credentials open-access book. **Module C's construction
obligations are:** (a) correct acquisition MIME; (b) for audiobooks, the copied
file MUST be a valid **manifest JSON** (the `LocalFileAdapter` parses it —
`Vendors/LocalFileAdapter.swift:73-80`), and remote track playback still needs the
network at play time; and (c) pin file placement to the fixed
`sideloadContentAccountID` (import step 3 — else a library switch makes the file
unresolvable).

**Accepted limitation (DECISION — document, do NOT engineer around; finding 5):**
`didSelectRead` (`BookDetailViewModel.swift:844`) wraps the open in
`ensureAuthAndExecute` (`:711`), which presents a sign-in modal when
`account.needsAuth && !account.hasCredentials()` (or `authState == .credentialsStale`).
Opening a sideloaded book **while signed out on an auth-required library shows
sign-in, not the reader.** This is an auth gate (not an availability/download/OPDS
gate), so the EPUB/PDF "no other production edits" claim holds for the intended
signed-in DRM-test use case. **Decision: accept (option a)** — do NOT route
sideloaded opens around the shared critical-path auth gate for a test feature.
E2E testers sign in first; note this in the simdrive flow.

## Test contract
1. `SideloadedBookManagerTests` — construct `SideloadedBookManager(...)` with
   injected spies (fake `SideloadedBookRegistry` w/ temp dir, spy
   `TPPBookRegistryProvider`, a `BookFileManager` with a `directoryProvider`
   temp override, a fake file source). Prove:
   - Import EPUB MIME → minted book `defaultBookContentType == .epub`, file copied
     to the expected sha256 path, `SideloadedBookRegistry.identifiers` contains id,
     `TPPBookRegistry.addBook` called with `state: .downloadSuccessful`.
   - Import PDF and audiobook MIME → correct `defaultBookContentType`.
   - Unsupported MIME/extension → throws / returns error, NEITHER registry mutated
     (edge case).
   - Duplicate import (same content) → no double-register (dedup).
   - `remove` → file deleted + both registries cleared.
   - `rehydrateAtLaunch` → each persisted book re-added to the main registry as
     `.downloadSuccessful`; idempotent (running twice doesn't duplicate).
   - Missing-file / copy-failure error path → no partial registration.
2. `SideloadImportContractTests` (contract-snapshot, `PalaceTests/Contract/`) —
   record the ordered call sequence of a successful import:
   `classify → copyFile → sideloadRegistry.add → bookRegistry.addBook(.downloadSuccessful)`.
   Follow the `CallLog` + `ContractSnapshot.assert` pattern (CLAUDE.md
   "Contract-snapshot tests"). A reorder / dropped call drifts the snapshot.

## Verification criteria (grep-able)
- SUT instantiation (DoD #1):
  - `grep -c "SideloadedBookManager(" PalaceTests/MyBooks/Sideload/SideloadedBookManagerTests.swift` ≥ 1
  - `python3 scripts/check-test-name-vs-body.py PalaceTests/MyBooks/Sideload/SideloadedBookManagerTests.swift` → exit 0
- `.downloadSuccessful` wiring present: `grep -c "downloadSuccessful" Palace/MyBooks/Sideload/SideloadedBookManager.swift` ≥ 1 (import + rehydration).
- Rehydration wired in the correct method + via load completion:
  `grep -n "rehydrateAtLaunch" Palace/AppInfrastructure/TPPAppDelegate.swift` must
  land inside `setupBookRegistryAndNotifications()` (the `applicationDidFinishLaunching`
  path), inside the `bookRegistry.load { ... }` completion closure — NOT inside
  `handleAppRefresh` and NOT a bare fire-and-forget after `load()`. Verify: the
  rehydration call's line is between the `func setupBookRegistryAndNotifications`
  declaration and its closing brace, AND the `load(` on that path passes a trailing
  closure (`grep -A2 "bookRegistry.load" TPPAppDelegate.swift` shows `{`, not `load()`).
- Fixed-account write: `grep -c "sideloadContentAccountID" Palace/MyBooks/Sideload/SideloadedBookManager.swift` ≥ 1 (import copy pins the account); the manager must NOT call `fileUrl(for:book:account: currentAccountId)` for sideloaded copies.
- Flag-gated settings: `grep -c "isSideLoadingEnabled" Palace/Settings/NewSettings/TPPSettingsView.swift` ≥ 1.
- Multi-step body (DoD #3): `rehydrate`/`twice`/`again` tests actually drive the
  step twice — grep the rehydration test for two `rehydrateAtLaunch()` calls (idempotency).
- Contract-snapshot exists: `ls PalaceTests/Contract/__Snapshots__/SideloadImportContractTests/` non-empty after first record run; committed baseline present.
- **Mutation (DoD #5, MANDATORY):**
  `python3 scripts/palace_mutate.py --file Palace/MyBooks/Sideload/SideloadedBookManager.swift --tests PalaceTests/SideloadedBookManagerTests --diff-only` → ≥ 50% (aim 100% on classify + register + rehydrate branches; critical path).
- `check-contract-reconciliation.py --commit-msg <file>` exit 0 for the
  "adds SideloadedBookManager / mints open-access book / rehydrates at launch" claims.
- `check-blast-radius.py --quiet` exit 0 (AppContainer property not a test-only init param).
- `check-superpartner-spectrum.py --quiet` exit 0.
- Build clean (both targets, incl. Palace-noDRM); `scripts/verify-pr.sh --quick` PASS.
- (Release-path) simdrive E2E per plan step 5: enable flag → import LCP 2.x test
  EPUB (PP-2580) → lane → open in reader → renders. Record a chaos-replay.
