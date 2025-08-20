Catalog MVVM + SwiftUI and Networking Unification — Migration Checklist

Use this checklist to track the one-pass migration from Objective-C Catalog to SwiftUI MVVM and unify networking via a protocol-driven client.

Completed
- [x] Architecture defined: MVVM + SwiftUI, protocol-driven `NetworkClient`, repository layer, OPDS parser wrapper
- [x] Networking core added: `NetworkClient` protocol and `URLSessionNetworkClient` adapter reusing `TPPNetworkExecutor`
- [x] Catalog domain created: `CatalogFeed`/`CatalogEntry` models, `OPDSParser` wrapper (`TPPXML(data:)`), `CatalogAPI`, `CatalogRepository`
- [x] SwiftUI Catalog scaffolding: `CatalogView`, `CatalogViewModel`, `TPPCatalogHostViewController`
- [x] App integration: `TPPRootTabBarController` instantiates SwiftUI Catalog host
- [x] Xcode project updated: groups for Networking/Core, CatalogDomain, CatalogUI; sources added
- [x] Lint check clean for new files

In Progress / Verify
- [ ] Ensure Target Membership = Palace for:
  - `Palace/CatalogUI/CatalogHostViewController.swift`
  - `Palace/CatalogUI/Views/CatalogView.swift`
  - `Palace/CatalogUI/ViewModels/CatalogViewModel.swift`
- [ ] Build & run: resolve ObjC⇄Swift bridging (requires `#import "Palace-Swift.h"` and files in target)
- [ ] Update property types in `TPPRootTabBarController` to `UINavigationController *` for Catalog/MyBooks to avoid casts
- [ ] Fill Catalog UI parity: lane strips, facets, search, navigation to book detail
- [ ] Verify cover images via existing ImageCache
- [ ] Account handling: abstract `AccountService` (age-check/sign-in parity); currently using `TPPSettings`

To Do — Networking Migration (post-Catalog)
- [ ] Replace direct networking with `NetworkClient` in:
  - [ ] Sign-in: `TPPBasicAuth.swift`, `TokenRequest.swift`, `TPPSignInBusinessLogic.swift`
  - [ ] Analytics & error logging: `TPPCirculationAnalytics.swift`, `TPPErrorLogger.swift`
  - [ ] MyBooks metadata/network calls (leave specialized audiobook downloaders intact)
  - [ ] Deprecate and remove `TPPSession` after last usage is migrated
- [ ] Add lint/CI check to block new direct `URLSession` usages outside Networking/Core

To Do — Testing
- [ ] `NetworkClient` contract tests using `URLProtocol`
- [ ] OPDS parser tests with existing fixtures
- [ ] Repository error mapping and edge-case tests
- [ ] ViewModel async tests (loading, retry, search, facets)
- [ ] SwiftUI snapshot tests for loading/error/empty/content states
- [ ] Integration: account change (notification) triggers Catalog reload

To Do — Cleanup & Rollout
- [ ] QA parity checklist: top-level browsing, lanes, facets, search, account switch, age-check/sign-in prompts, deep links, accessibility/dynamic type
- [ ] Remove legacy Objective-C Catalog controllers/cells from project and target once parity confirmed
- [ ] Update developer docs (how to use `NetworkClient`, patterns for new features)
- [ ] Monitor analytics/crash metrics after merge

Notes
- `URLSessionNetworkClient` intentionally reuses `TPPNetworkExecutor` to preserve auth/refresh/caching behavior.
- OPDS parsing continues to rely on existing Objective-C `TPPOPDS` via a thin Swift wrapper.
- We will keep checking items off here as we complete each step.

