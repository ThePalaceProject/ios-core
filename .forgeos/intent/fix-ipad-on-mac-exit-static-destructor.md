---
name: fix-ipad-on-mac-exit-static-destructor
created: 2026-06-11
author: claude-opus-4-8
tracking: WS-4 (fleet) — 3.2.0 pre-regression crash triage, init_17bfe690, changeset cs_b77ea7cc; Crashlytics 9a91840677
related_prs: []
---

# Intent: WS-4 — iPad-on-Mac Adobe RMSDK static-destructor crash bypass (_exit(0))

## Problem
On iOS-app-on-Mac, process termination runs `exit()`, which invokes C++ static
destructors. Adobe RMSDK's static `recursive_mutex` destructor faults
(recursive_mutex EINVAL) at teardown — Crashlytics 9a91840677, 294 events, all
iOS_ON_MAC. The prior `prepareForTermination` fix FAILED (its own comment admits
it does not destroy the underlying C++ objects). The `isDRMAvailable`
iOS-on-Mac gate prevents our `NYPLADEPT.sharedInstance()` call but cannot
prevent RMSDK's load-time C++ static from being constructed/destructed.

## Approach (Chairman OPTION 1 — skip C++ static destructors via `_exit(0)`)
- (a) Normal Cmd-Q: `applicationWillTerminate` — after existing cleanup, if
  `isiOSAppOnMac`, call `_exit(0)` as the LAST statement.
- (b) Forced/watchdog exit can skip `applicationWillTerminate` → install an
  `atexit()` interceptor that calls `_exit(0)`, registered at launch (after
  RMSDK's load-time statics have constructed, so LIFO ordering runs ours first).

## Claims
- Adds pure helper `shouldSkipStaticDestructorsOnExit(isiOSAppOnMac:) -> Bool`.
- Adds pure helper `AdobeDRMService.shouldRegisterStaticDestructorBypass(isiOSAppOnMac:alreadyRegistered:)`.
- Adds idempotent `AdobeDRMService.registerStaticDestructorBypassIfNeeded()` (atexit interceptor, gated on isiOSAppOnMac, NSLock-serialized).
- Adds `AdobeDRMService.markAdobeDRMUsed()` / `didUseAdobeDRMThisSession` (NSLock-guarded session flag), marked at `AdobeDRMContainer` construction (`AdobeDRMContentProtection.open`).
- `applicationWillTerminate` calls `_exit(0)` last, gated on isiOSAppOnMac.
- `applicationDidEnterBackground` calls the registration helper under `#if FEATURE_DRM_CONNECTOR`, gated on `didUseAdobeDRMThisSession`. Installing at background — after all DRM use of the session — is LIFO-after Adobe's dtor regardless of its (unmeasured) construction timing; a launch-time install was withdrawn as too-early.
- 5 guard tests in `iPadOnMacRMSDKGuardTests`.

## Anti-claims
- Does NOT change iOS-device exit behavior (everything gated on isiOSAppOnMac).
- Does NOT remove the prior `prepareForTermination` cleanup.
- Does NOT touch `AdobeDRMHandler.swift` or `isDRMAvailable` gating.
- Does NOT attempt simdrive Mac validation (flagged as required follow-up).

## Files in scope
- Palace/AppInfrastructure/TPPAppDelegate.swift
- Palace/Reader2/ReaderStackConfiguration/AdobeDRM/AdobeCertificate.swift
- PalaceTests/RegressionGuards/iPadOnMacRMSDKGuardTests.swift

## Validation
- Unit: pure-helper gating + idempotency. Diff-scoped mutation 100% (1/1 killed).
- Build green; verify-pr.sh --quick (full battery) run separately.
- Crash-at-exit is NOT in-process testable → tagged UNVERIFIED; simdrive Mac
  round-trip (Cmd-Q + watchdog) + arm64 `__mod_init_func` binary confirmation
  REQUIRED before promotion past the testing gate.
