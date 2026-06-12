---
name: ws0-runtime-quiescence-gate
created: 2026-06-11
author: claude-opus-4-8
---

## Summary

WS-0 / M0 (3.2.0 release gate): add a deterministic, order-independent
structural gate that prevents the cross-test cooperative-pool starvation flake —
a test leaving `AccountsManager.deferInitialLoadCatalogsForTesting = false`,
which makes the next test class's `AppContainer.production()` rebuild spawn a
leaked background catalog crawl. The production root cause was already fixed
(#1050/#1056/#1057/#1061); this is the structural backstop that makes the bug
class impossible to reintroduce silently. Test-target only; zero production-code
behaviour change.

## Claims

- adds `PalaceTests/Support/RuntimeQuiescenceAuditor.swift` — pure quiescence detector (`deferFlagViolations`) + live capture
- adds `PalaceTests/Support/PalaceTestCase.swift` — base XCTestCase whose `tearDownWithError` asserts quiescence AFTER super (the runtime gate)
- adds `PalaceTests/MetaTests/RuntimeQuiescenceGateTests.swift` — self-test proving the detector fires on a synthetic polluter and passes clean
- adds `PalaceTests/MetaTests/RuntimeQuiescenceLintTests.swift` — structural lint forcing any `= false` flag-setter onto the quiescence base; self-tests BAD/GOOD/CLEAN
- changes `PalaceTests/Support/PalaceWiringTestCase.swift` base class from `XCTestCase` to `PalaceTestCase` (one hierarchy)
- adds a non-gating diagnostic NSLog breadcrumb to `PalaceTests/PalaceTestSetup.swift` observer
- migrates `AppContainerResetTests` and `TestAppContainerFactoryTests` to subclass `PalaceTestCase`
- adds the new test files to `Palace.xcodeproj/project.pbxproj` (PalaceTests target)
- adds ADR `docs/architecture/runtime-quiescence-gate.md` and wall-failure `.forgeos/wall-failures/2026-06-11-ws0-inert-quiescence-gate.md`

## Anti-claims

- does NOT change any `Palace/` production code or behaviour (test-target only)
- does NOT migrate `AccountsManagerTests`' `AppContainer.production()` reads (deferred scope, per palace-pm)
- does NOT disable `testExecutionOrdering = "random"` in the scheme
- does NOT add a global auto-fail observer (proven inert) or a trailing final-gate test (proven order-fragile)
- does NOT use `#if DEBUG` in test-target gate code (proven to compile to a no-op on the PalaceTests target)

## Files in scope

- PalaceTests/Support/RuntimeQuiescenceAuditor.swift (NEW)
- PalaceTests/Support/PalaceTestCase.swift (NEW)
- PalaceTests/MetaTests/RuntimeQuiescenceGateTests.swift (NEW)
- PalaceTests/MetaTests/RuntimeQuiescenceLintTests.swift (NEW)
- PalaceTests/Support/PalaceWiringTestCase.swift
- PalaceTests/PalaceTestSetup.swift
- PalaceTests/AppInfrastructure/AppContainerResetTests.swift
- PalaceTests/Support/TestAppContainerFactoryTests.swift
- Palace.xcodeproj/project.pbxproj
- docs/architecture/runtime-quiescence-gate.md (NEW)
- .forgeos/wall-failures/2026-06-11-ws0-inert-quiescence-gate.md (NEW)
- .forgeos/intent/ws0-runtime-quiescence-gate.md (NEW)
