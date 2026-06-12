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
   statement (after existing cleanup). Sound independent of everything below —
   it never enters the `atexit`/static-destructor list.
2. **Forced/watchdog:** `applicationDidEnterBackground` installs an idempotent
   `atexit { _exit(0) }` interceptor (via
   `AdobeDRMService.registerStaticDestructorBypassIfNeeded()`) — but **only once
   Adobe DRM has been used this session** (`didUseAdobeDRMThisSession`, set by the
   reader decrypt path) — for the watchdog `exit()` that skips
   `applicationWillTerminate`. Background entry is chosen because it is
   guaranteed-after-all-DRM-this-session and adjacent to the background
   suspension where the crashes fire (see Ordering). The earlier revision
   installed at `applicationDidFinishLaunching`; that was withdrawn (see below).

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
  `NYPLADEPT.sharedInstance()` (Adobe fulfillment/activation), but does NOT cover
  the **reader decrypt path**: opening a downloaded Adobe-DRM EPUB runs
  `AdobeDRMContentProtection` → `AdobeDRMContainer.decode(...)`, which drives the
  RMSDK runtime that owns the mutex. That path is ungated, so the crash still
  fires on iOS-on-Mac. (Code-read of `AdobeDRMContentProtection.swift` +
  `AdobeCertificate.swift`; `isDRMAvailable` wraps only `AdobeDRMService`.)
- **`AdobeDRMService.prepareForTermination`** — clears our cached reference but
  (by its own comment) never destroys the underlying C++ object.

**Construction timing of Adobe's `recursive_mutex` is UNMEASURED.** Whether its
`__cxa_atexit` destructor is registered at dylib-load (file-scope static) or
lazily on first DRM use (function-local Meyers static) has NOT been measured on
the real arm64 device binary in this environment. (An earlier "dylib-load"
inference and a later "lazy Meyers" claim were both unverified; neither is cited
as fact. A real CHECK 1 — `otool`/`nm`/`DYLD_PRINT_INITIALIZERS` on the device
slice — can resolve it on the Mac, but the fix below does not depend on it.)

## Ordering rationale — robust to the unmeasured timing (the lynchpin)

`atexit` handlers and C++ static destructors (`__cxa_atexit`) share one LIFO
list, so to pop `_exit(0)` BEFORE Adobe's destructor we must register ours
**after** Adobe's `__cxa_atexit(dtor)`. We install the interceptor at
**`applicationDidEnterBackground`, gated on `didUseAdobeDRMThisSession`** (the
reader decrypt path sets that flag). By the time the app backgrounds, every
Adobe-DRM `decode()` of this session has run, so Adobe's dtor is already
registered — whenever it was going to be. The install is therefore LIFO-after
Adobe's dtor in **both** possible timings:

- **Load-time:** Adobe's dtor registered at dylib-load (before `main`) — earlier
  than our background-time install. ⇒ ours pops first.
- **Lazy:** Adobe's dtor registered during whichever DRM op first constructs the
  mutex (a `decode()` earlier this session) — earlier than our install at
  background. ⇒ ours pops first.

So `_exit(0)` runs before Adobe's faulting destructor regardless of the
construction timing — the placement, not a timing measurement, is the
correctness argument. `_exit` performs an immediate syscall: it runs **no**
`atexit` handlers and **no** static destructors, so on the normal (Cmd-Q) path
the bare `applicationWillTerminate` `_exit(0)` is sufficient on its own and never
touches the atexit list (Path A is sound independent of all of the above).

**Why background entry, not the decode site (the trap avoided):** installing
*at* the first `decode()` would re-introduce the same ordering-assumption class
that sank the launch-time install — it assumes the *first* decode is the op that
constructs the mutex. If construction lands on a *later* DRM op, the at-most-once
idempotency guard would **lock in** a too-early install. Background entry has no
such assumption: it is unconditionally after all DRM use of the session, and it
is temporally adjacent to the background suspension where **all 294 crashes
fire** (the watchdog `exit()` happens during background suspension). The reader
DRM path therefore only **marks** that DRM was used; it does not install.

**Mark-site coverage (must dominate every mutex-constructing path):** the install
only fires if `didUseAdobeDRMThisSession` is set, so the mark must precede every
ungated op that can construct `dp::DPCriticalSection`. Those ops
(`decode` / `displayUntilDate` license-read / `init` → `GPFile::lock`) all run
inside an `AdobeDRMContainer` method, and **every** `AdobeDRMContainer` is
constructed at exactly one site — `AdobeDRMContentProtection.open` (the sole
`.adept` content-protection entry). The mark is placed at that construction, so
it dominates and precedes all of them. The gated `AdobeDRMService` / `NYPLADEPT`
fulfillment/activation path is not a concern: `isDRMAvailable` is false on
iOS-on-Mac, so it never runs there.

**Residual (flagged for CHECK 2):** background entry does NOT cover a
foreground/active forced `exit()` (no backgrounding) after DRM use. The 294
events are all background-suspension, so this is empirically not the observed
crash — but CHECK 2 should confirm (and, if a foreground watchdog path is found,
a non-idempotent decode-site install would be the addition, accepting the
atexit-list growth).

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
