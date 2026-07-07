---
name: swift6-phasec-language-mode-flip
created: 2026-07-07
author: claude-opus-4-8
---

**ADR refs:** none — no local ADR ledger present; ForgeOS is OFF (handoff §2d), so
the `mcp__forgeos__forge_list_adrs` path is intentionally not invoked. Phase C is the
finish line of the Swift 6 modernization epic PP-4717 (PP-4723), a continuation of the
already-merged Phase A/B decisions, not a reversal of any.

## Context

Resumes the paused Phase C checkpoint (worktree `swift6/integ-0706`). Phase A (targeted→0)
and Phase B (`complete`-mode→0, 738→0) are merged. Phase C flips `SWIFT_VERSION 5.0 → 6.0`
on the 4 app configs and clears the tail of Swift-6-language-mode-only diagnostics
(ObjC-completion `@Sendable` import mismatches, `NSLock.lock()/unlock()` banned in async,
static-mutable-global concurrency safety, `@MainActor`-from-nonisolated) layer by layer
until the app target and test target build clean under full Swift 6. Critical-path
(auth/DRM) → architect + 2×SoD review required. Companion:
`docs/architecture/swift6-phaseC-handoff-2026-07-07.md`.

## Claims

- migrates `SWIFT_VERSION` from `5.0` to `6.0` on the 4 app configs (Palace + Palace-noDRM,
  Debug + Release) plus the 2 PalaceUIKit embedded-framework configs (Debug + Release), and
  sets `SWIFT_STRICT_CONCURRENCY = complete` on those 6 configs, in
  `Palace.xcodeproj/project.pbxproj` (PalaceUIKit added so no embedded Swift-5 framework
  remains — flagged by both SoD reviewers; it compiles a single trivial `Font+PalaceUIKit.swift`)
- migrates ObjC-imported DRM completion blocks to `@Sendable` on the `TPPDRMAuthorizing`
  protocol requirements in `Palace/SignInLogic/TPPSignInBusinessLogic.swift` and the mock
  mirror in `PalaceTests/Mocks/TPPDRMAuthorizingMock.swift`
- migrates async-context `NSLock.lock()/unlock()` pairs to `withLock { }` in
  `Palace/FeatureFlags/RemoteFeatureFlags.swift` and `Palace/MyBooks/BookReturnService.swift`
- adds a lock-backed `ArchiveDataAccumulator` (`@unchecked Sendable`) in
  `Palace/Reader2/ReaderStackConfiguration/AdobeDRM/AdobeDRMContentProtection.swift` to
  replace a captured-`var` mutation in `readDataFromArchive`
- migrates the `+DRM` sign-in completion in `Palace/SignInLogic/TPPSignInBusinessLogic+DRM.swift`
  to run its body as one `Task { @MainActor in … }` hop with boxed non-Sendable error +
  logging context (BEHAVIOR-SENSITIVE — preserves cancel → set-IDs → finalize ordering)
- migrates `NSLock.lock()/unlock()` in the async `initialize()` of
  `Palace/Utilities/DeviceSpecificErrorMonitor.swift` to a scoped `withLock`
- migrates `PalaceAuthTokenProvider.tokenResolver` (audiobook-toolkit submodule
  `ios-audiobooktoolkit/PalaceAudiobookToolkit/Core/PalaceAuthTokenProvider.swift`) from a
  bare `public static var` to a lock-backed `@Sendable`-closure holder — this is a SUBMODULE
  change requiring a toolkit PR + version + pointer bump (landing approach pending user
  decision); the `@Sendable` type ripples to the app-side assignment in `TPPAppDelegate.swift`
- migrates `Palace/SignInLogic/TPPSignInBusinessLogic+SignOut.swift:475` `completeLogOutProcess()`
  to a `Task { @MainActor in }` hop (also corrects latent off-main credential/WebKit cleanup)
- (pending build discovery) migrates any further language-mode-only strata to app-target-clean

## Anti-claims

- does NOT change the observable behavior of sign-in, sign-out, borrow, return, download,
  or DRM fulfillment beyond the documented `+DRM` completion ordering tightening (set-IDs
  now provably precede `finalizeSignIn` within one main-actor unit)
- does NOT use `nonisolated(unsafe)` to silence any diagnostic (isolation-only per the playbook)
- does NOT touch the `4.2` (legacy) or `""` (inherited) `SWIFT_VERSION` entries
- does NOT alter `SWIFT_STRICT_CONCURRENCY` (already `complete` from Phase B)
- does NOT change public API surface of the touched auth/DRM types beyond adding `@Sendable`
  to already-existing protocol completion requirements

## Files in scope

- Palace.xcodeproj/project.pbxproj
- Palace/SignInLogic/TPPSignInBusinessLogic.swift
- Palace/SignInLogic/TPPSignInBusinessLogic+DRM.swift
- Palace/SignInLogic/TPPSignInBusinessLogic+SignOut.swift
- Palace/FeatureFlags/RemoteFeatureFlags.swift
- Palace/MyBooks/BookReturnService.swift
- Palace/Reader2/ReaderStackConfiguration/AdobeDRM/AdobeDRMContentProtection.swift
- Palace/AppInfrastructure/TPPAppDelegate.swift
- Palace/Utilities/DeviceSpecificErrorMonitor.swift
- PalaceTests/Mocks/TPPDRMAuthorizingMock.swift
- ios-audiobooktoolkit/PalaceAudiobookToolkit/Core/PalaceAuthTokenProvider.swift (submodule)
- .forgeos/intent/swift6-phasec-language-mode-flip.md
