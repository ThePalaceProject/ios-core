---
name: PP-2677 side-loading manager settings catalog lane registry sync-exemption feature flag
created: 2026-07-01
author: swarm_495a88d9
---

# Intent — Side Loading (PP-2677 / PP-2678 / PP-2679)

Swarm: swarm_495a88d9 · Branch: feature/PP-2677-sideloading · Date: 2026-07-01
Ground truth: docs/architecture/sideloading-plan.md · Contracts: .forgeos/swarms/swarm_495a88d9/contracts/

## Claims (what this change WILL do)
- Add a `SideloadedBookRegistry` — a dedicated, local-only JSON manifest of sideloaded books (PP-2678) with add/remove/rename/update/allBooks/identifiers.
- Add a `SideloadedBookManager` (PP-2677) that imports a local EPUB/PDF/audiobook file: classify → mint an open-access `TPPBook` → copy the file to a fixed-account `BookFileManager` path → register in both the sideloaded registry and the main `TPPBookRegistry` as `.downloadSuccessful` → add the id to a sync-exemption set; plus a flag-gated Settings screen and launch rehydration.
- Exempt sideloaded book ids from `BookRegistrySync` reconciliation so server sync does not evict them or delete their files.
- Make `BookFileManager` resolve sideloaded book files against a fixed `sideloadContentAccountID` (= primary account) so they survive library switches.
- Add a `RemoteFeatureFlags.sideLoadingEnabled` flag (Firebase default + DEBUG-on + dev-menu local override) gating the whole feature.
- Inject a "Side Loaded" `CatalogLaneModel` at every `toCatalogContent()` site in `CatalogViewModel` via a single choke-point helper (PP-2679), flag-gated.

## Anti-claims (what this change will NOT do)
- Will NOT sync sideloaded books to any server or OPDS feed (local-only).
- Will NOT alter the borrow / download / DRM-fulfillment pipelines for catalog books.
- Will NOT change server-sync behavior for non-sideloaded books (exemption is scoped to the sideloaded id set only).
- Will NOT hide sideloaded books from the My Books shelf (accepted side effect of registry reuse).
- Will NOT bypass the `didSelectRead` auth gate (accepted limitation for auth-required libraries when signed out).

## Files in scope
- NEW: Palace/MyBooks/Sideload/SideloadedBookRegistry.swift, SideloadedBookManager.swift (+ tests)
- MODIFY: Palace/Book/Models/BookRegistrySync.swift (sync exemption), Palace/MyBooks/BookFileManager.swift (account-stable resolution), Palace/Book/Models/TPPBookRegistry.swift (provider threading)
- MODIFY: Palace/FeatureFlags/RemoteFeatureFlags.swift (+ FirebaseManager)
- MODIFY: Palace/CatalogUI/ViewModels/CatalogViewModel.swift, CatalogState.swift (lane injection)
- MODIFY: Palace/Settings/TPPSettings.swift, Settings/NewSettings/TPPSettingsView.swift (Settings entry)
- MODIFY: Palace/AppInfrastructure/AppContainer.swift (2 additive properties), TPPAppDelegate.swift (rehydration in load(completion:))
- MODIFY: Palace.xcodeproj/project.pbxproj (via scripts/pbxproj_add_swift.rb only)
