---
name: cleanup-address-11-manual-review-findings-and-2-lint-blockers
created: 2026-05-28
author: claude-opus-4-7
---

## Claims

- tightens `TPPReauthenticator._testContainerOverride` scope from `#if DEBUG` to XCTest env-var
- changes `authenticateCallCount` visibility from `public private(set)` to `internal private(set)`
- updates 3 stale `SignInModalHostingController` doc references in `SignInModalSheetPresenter.swift`
- adds `.detailsEvicted` to `loadedDetails(of:)` docstrings in `TPPSignInBusinessLogic.swift` and `TPPAnnotations.swift`
- removes fixture-sanity set-then-assert in `TPPSAMLFlowTests.swift` (FLUFF-001)
- fixes 6 manual-review findings + 2 lint blockers

## Anti-claims

- does NOT change any behavior (mutation-eligible surface is the new `isRunningUnderXCTest` env-var check, deterministic)
- does NOT add new API surface
- does NOT delete `SignInModalHostingController` (that landed in wave 4 main commit; this commit only updates stale comments)
- does NOT touch Palace/Audiobooks/ or ios-audiobooktoolkit/

## Files in scope

- Palace/Reader2/Bookmarks/TPPAnnotations.swift
- Palace/SignInLogic/SignInModalSheetPresenter.swift
- Palace/SignInLogic/TPPReauthenticator.swift
- Palace/SignInLogic/TPPSignInBusinessLogic.swift
- PalaceTests/SignInLogic/TPPSAMLFlowTests.swift
