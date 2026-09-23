---
name: swift6-apptarget-drm-a5
created: 2026-07-01
author: Maurice Carrier
branch: swift6/apptarget-drm-a5
initiative: Swift 6 app-target Phase A.5 — DRM-decryption slice + TPPUserAccount Sendable (critical-path: DRM + credential storage)
priority: critical-path
---

# Intent: Swift 6 `targeted` concurrency — Phase A.5 DRM slice (+ TPPUserAccount Sendable)

## Context

App-target Phase A.4 measured 42 remaining `targeted` warnings on develop tip
`210f5713a` (Unit Tests run `28520895484`). This slice clears the 11 warnings in
the 4 Reader2/PDF DRM files that A.3 named but never touched. Fix-by-isolation only
(never `nonisolated(unsafe)`, no bare `@unchecked`). `SWIFT_VERSION` stays 5.0
(warnings, not errors). Critical path (DRM + credential storage) — architect + qa +
blast_radius SoD done. CI Unit Tests is the only build/warning gate (no local DRM
build). Fix-contract: `.forgeos/changesets/swift6-apptarget-drm-a5/fix-contract.md`.

## Claims

- Makes `LCPPDFOpenProgress.shared` and its `private init()` `nonisolated` so the
  background LCP-decrypt path can reference the `@MainActor` singleton without a hop
  (clears 6 warnings: TPPLCPClient ×4, LCPPDFDiskExtract ×2 — zero edits to those files).
- Adds `@preconcurrency` to the `ReadiumShared` import in `AdobeDRMContentProtection`
  (clears 3 warnings: the import + the `DRMDataResource` actor's `stream(consume:)`
  and `properties()` protocol-witness crossings).
- Makes `TPPUserAccount` conform to `@unchecked Sendable` by moving its three
  unsynchronized mutable control vars (`sessionIdentifier`, `signInGeneration`,
  `notifyAccountChange`) behind a dedicated `NSLock` (`controlLock`) with backing
  `_`-prefixed storage — NOT `accountInfoQueue` (those setters run inside its serial
  barrier via `atomicUpdate`, so routing them through it would deadlock). Clears the
  2 `AdobeCertificate:393` warnings (userAccount capture) with no edit to that file.
- Adds `TPPUserAccount.incrementSignInGeneration()` — a single locked atomic
  read-modify-write — and changes `TPPSignInBusinessLogic+SignOut.cancelPendingSignOut`
  to call it instead of the non-atomic `signInGeneration += 1`.
- Adds `PalaceTests/Accounts/TPPUserAccountConcurrencyTests.swift` pinning the atomic
  increment under `DispatchQueue.concurrentPerform` (kills the get-then-set TOCTOU mutant).
- Updates `docs/architecture/app-target-swift6-modernization-plan.md` to record the
  A.4 measurement (117 total / 42 app-target) and reopen A.5/A.6.

## Anti-claims

- Does NOT change `SWIFT_VERSION` (stays 5.0 — warnings, not errors).
- Does NOT use `nonisolated(unsafe)` or `MainActor.assumeIsolated`; the only
  `@unchecked Sendable` added is the one documented `TPPUserAccount` conformance.
- Does NOT route the 3 control vars through `accountInfoQueue` (deadlock) — dedicated
  leaf `controlLock` only.
- Does NOT edit `AdobeCertificate.swift` or the two LCP-decrypt consumer files
  (`TPPLCPClient.swift`, `LCPPDFDiskExtract.swift`) — their warnings clear via the
  root-cause type changes.
- Does NOT change observable DRM / sign-in / sign-out behavior — isolation/mechanism
  only, plus the new lock serialization + atomic increment (strictly safer than the
  prior unsynchronized `var`).

## Files in scope

- Palace/PDF/ReadiumPDF/LCPPDFOpenProgress.swift
- Palace/Reader2/ReaderStackConfiguration/AdobeDRM/AdobeDRMContentProtection.swift
- Palace/Accounts/User/TPPUserAccount.swift
- Palace/SignInLogic/TPPSignInBusinessLogic+SignOut.swift
- PalaceTests/Accounts/TPPUserAccountConcurrencyTests.swift
- Palace.xcodeproj/project.pbxproj
- docs/architecture/app-target-swift6-modernization-plan.md
