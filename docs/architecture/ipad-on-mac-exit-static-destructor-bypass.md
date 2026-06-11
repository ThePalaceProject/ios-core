# ADR (DRAFT — pending Chairman ratification): iPad-on-Mac exit-time static-destructor bypass via `_exit(0)`

- **Status:** DRAFT — proposed by w-mutex (WS-4), awaiting Chairman ratification.
- **Area:** app-lifecycle / DRM (Adobe RMSDK)
- **Branch:** `fleet/w-mutex` (local commit `e85119b8a`, not pushed)
- **Crashlytics:** 9a91840677 (294 events, 89 users, all `iOS_ON_MAC`)
- **Verification status:** UNVERIFIED — see "Consequences / verification gate".

## Decision

On **iOS-app-on-Mac only**, terminate the process with `_exit(0)` instead of
letting `exit()` run the C++ static-destructor pass. Implemented on both exit
paths, each gated on `ProcessInfo.processInfo.isiOSAppOnMac`:

1. **Normal (Cmd-Q):** `applicationWillTerminate` calls `_exit(0)` as its last
   statement (after existing cleanup).
2. **Forced/watchdog:** `applicationDidFinishLaunching` installs an idempotent
   `atexit { _exit(0) }` interceptor (via
   `AdobeDRMService.registerStaticDestructorBypassIfNeeded()`) for the path
   where a `FinalTerminationWatchdog`-style forced `exit()` skips
   `applicationWillTerminate`.

The decision is pinned by two pure, injectable helpers
(`shouldSkipStaticDestructorsOnExit(isiOSAppOnMac:)`,
`shouldRegisterStaticDestructorBypass(isiOSAppOnMac:alreadyRegistered:)`) so the
gating + one-shot timing are unit-testable without invoking the real
`atexit`/`_exit`.

## Context

Adobe RMSDK contains a static `recursive_mutex` whose destructor faults
(EINVAL) during the process-exit static-destructor pass when the iPad binary
runs under the "Designed for iPad on Apple Silicon Mac" runtime. Two prior
mitigations did not stop the crash:

- **`isDRMAvailable` returns false on `isiOSAppOnMac`** — prevents our
  `NYPLADEPT.sharedInstance()` call, but the faulting static is constructed at
  **dylib load** (`__mod_init_func`), independent of any runtime gate.
- **`AdobeDRMService.prepareForTermination`** — clears our cached reference but
  (by its own comment) never destroys the underlying C++ object.

**Evidence the faulting static is dylib-load-constructed, not lazy:** the only
`NYPLADEPT.sharedInstance()` call site in the app is
`AdobeCertificate.swift` inside `AdobeDRMService.adeptInstance`, gated by
`isDRMAvailable` (false on iOS-on-Mac). A function-local (Meyers) static
registers its `__cxa_atexit` destructor only on first construction. If the
mutex were function-local it would never construct on iOS-on-Mac (sharedInstance
never runs) ⇒ no destructor ⇒ no exit-time fault — yet 294/294 events ARE
iOS-on-Mac. Therefore the destructor was registered with zero app calls into
RMSDK ⇒ it is a file/namespace-scope global constructed at image load. This also
explains why both prior fixes failed: neither touches the C++ global's lifecycle.

## Ordering rationale (the lynchpin)

`atexit` handlers and C++ static destructors (`__cxa_atexit`) share one LIFO
list. Adobe's load-time static registers its destructor at dylib load, **before
`main`**. Our `atexit { _exit(0) }`, installed in `applicationDidFinishLaunching`
(after `main`), is therefore registered **later** ⇒ runs **first** at exit ⇒
`_exit(0)` hard-terminates before Adobe's faulting destructor executes. `_exit`
performs an immediate `_exit(2)` syscall: it runs **no** `atexit` handlers and
**no** static destructors, so on the normal path the bare `willTerminate`
`_exit(0)` is sufficient on its own.

The handler relies on **install-site gating only** (no exit-time re-check):
`isiOSAppOnMac` is process-invariant, the handler is installed only when it is
true, and the handler body is deliberately a bare `_exit(0)` syscall — at exit
time the Obj-C/Foundation runtime may be mid-teardown, so touching
`ProcessInfo` inside the handler would be strictly riskier and add no
correctness.

## Alternatives considered

- **Keep relying on `isDRMAvailable` gating / `prepareForTermination`** —
  rejected: proven insufficient (crash persists; neither touches the C++
  global's lifecycle).
- **Register the `atexit` interceptor at first `sharedInstance()` (the brief's
  original wording)** — rejected: that call site is unreachable on iOS-on-Mac
  (gated off), and the faulting static is load-time, not lazy, so the
  registration would never run on the exact platform being fixed.
- **Re-check `isiOSAppOnMac` inside the atexit handler** — rejected: redundant
  (process-invariant; handler only installed on Mac) and riskier (touches
  Foundation mid-teardown).
- **Destroy / null out the RMSDK C++ object at termination** — rejected: the
  object is owned by Adobe's closed binary; we have no destruction seam, which
  is exactly why `prepareForTermination` failed.

## Consequences / verification gate

- iOS-device exit path is **byte-for-byte unchanged** (all logic gated on
  `isiOSAppOnMac`). On Mac, normal app-teardown side effects that depend on the
  static-destructor pass are skipped — acceptable because the app is
  terminating and macOS reclaims process resources.
- **This fix is in-process-UNVERIFIABLE** (Mac-only, fires at `exit()`). It MUST
  NOT promote past the testing gate without:
  1. **Binary confirmation** on the arm64 device slice:
     `otool -arch arm64 -l <Palace> | grep -A3 __mod_init_func` (nonzero) +
     `nm -arch arm64 <Palace> | grep -iE 'GLOBAL__sub_I|cxx_global_var_init|recursive_mutex'`
     (a load-time init thunk constructing the mutex; absence of
     `__cxa_guard_*` confirms it is not a Meyers static).
  2. **simdrive Mac round-trip:** open an Adobe-DRM book, then quit via BOTH
     normal Cmd-Q AND forced/watchdog exit; assert no `recursive_mutex` /
     no new 9a91840677 on either path; plus a real-device regression that
     normal termination is unchanged and Adobe borrow/open/return still work.
- Unit evidence already in hand: build green; 5 guard tests pass; diff-scoped
  mutation 100% (1/1 killed).

## Prior art (SharedMind / ForgeOS ledger)

`forge_query_mind` surfaced two adjacent entries; neither addresses the
exit-time static-destructor crash, confirming this decision is net-new:

- **ObjC→Swift port (March 2026):** names `recursive_mutex` as a known crash
  class at the ObjC/Swift boundary ("ObjC methods called from async Swift
  contexts have no thread-safety enforcement"). General acknowledgment of the
  family — not a fix for the Adobe RMSDK exit-time static destructor.
- **PP-4289 iPad-on-Mac friendliness pass:** establishes the
  `isiOSAppOnMac`-gated platform-adaptation pattern (e.g.
  `SceneDelegate.applyMacWindowGeometry`) this ADR follows for its gating
  invariant.

## References

- Files: `Palace/AppInfrastructure/TPPAppDelegate.swift`,
  `Palace/Reader2/ReaderStackConfiguration/AdobeDRM/AdobeCertificate.swift`,
  `PalaceTests/RegressionGuards/iPadOnMacRMSDKGuardTests.swift`.
- Related guard suite: `PalaceTests/RegressionGuards/` (this crash family is
  entry #3 in the README).
