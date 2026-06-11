# WS-4 Mac-validation runbook (the promotion-ceiling gate)

The iPad-on-Mac `_exit(0)` static-destructor bypass (commit `e85119b8a`, ADR
`ipad-on-mac-exit-static-destructor-bypass.md`, changeset `cs_b77ea7cc`) is
**UNVERIFIED** until both checks below pass on a real Apple Silicon **Mac host**
(needs Chairman authorization + a Mac — NOT runnable from a sim worktree).
Unit-green ≠ verified. This runbook is executable verbatim.

## What we're proving

The fix has two independent exit paths:

- **Path A — normal Cmd-Q:** `applicationWillTerminate` → `_exit(0)` as the last
  statement. **Correct independent of atexit ordering** — it never relies on the
  LIFO list. Covered even if the load-time assumption below were wrong.
- **Path B — forced/watchdog exit** (skips `applicationWillTerminate`): our
  `atexit { _exit(0) }`, installed at `didFinishLaunching`, must fire **before**
  Adobe RMSDK's static `recursive_mutex` destructor.

Path B is correct **only if** the load-bearing assumption holds:

> Adobe's faulting `recursive_mutex` is a **dylib-load** (`__mod_init_func`)
> file-scope global — its `__cxa_atexit` destructor is registered at image load,
> **before `main`/`didFinishLaunching`** — NOT a lazy Meyers function-local
> static constructed on first `NYPLADEPT.sharedInstance()`.

If load-time: our later `atexit` registration is LIFO-after Adobe's ⇒ runs first
⇒ `_exit(0)` before the fault. **CHECK 1 proves this.** **CHECK 2** proves the
end-to-end behavior on both paths.

---

## CHECK 1 — arm64 binary confirmation (static-init ordering)

The iOS-app-on-Mac runtime executes the **iOS arm64** binary, so inspect the
`iphoneos` slice (the one with Adobe RMSDK linked; the simulator slice does NOT
contain Adobe — verified: the Debug-iphonesimulator Palace binary has zero
Adobe/`recursive_mutex` symbols and no `__mod_init_func`).

```bash
# 1. Build the arm64 device slice WITH Adobe linked (FEATURE_DRM_CONNECTOR on).
#    CODE_SIGNING_ALLOWED=NO yields an unsigned binary — fine for inspection.
xcodebuild -project Palace.xcodeproj -scheme Palace \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/ws4-device-dd \
  -configuration Release CODE_SIGNING_ALLOWED=NO build
BIN=/tmp/ws4-device-dd/Build/Products/Release-iphoneos/Palace.app/Palace

# 2. Confirm arch + that Adobe RMSDK is actually present in THIS slice.
lipo -archs "$BIN"                                              # expect: arm64
nm -arch arm64 "$BIN" | grep -icE 'NYPLADEPT|adept|rmsdk|recursive_mutex'   # expect: > 0
otool -L "$BIN" | grep -iE 'adobe|rmsdk|adept' || echo "RMSDK is statically linked (folded into main executable)"
#    If RMSDK shows as a separate dylib, run steps 3-6 against that dylib instead.

# 3. Are there load-time static initializers at all?
otool -arch arm64 -l "$BIN" | grep -A4 -i mod_init_func
#    → expect: sectname __mod_init_func, segname __DATA_CONST (or __DATA), size > 0.
#      Nonzero size = the image HAS C++ global constructors that run at load.

# 4. List the per-translation-unit static-init thunks (file-scope statics).
nm -arch arm64 "$BIN" | grep -E '__GLOBAL__sub_I_|___cxx_global_var_init'
#    → each runs from __mod_init_func at image load. Find the RMSDK/Adobe TU
#      (dp_*, adept, the TU that owns the mutex).

# 5. PROOF: confirm the mutex's destructor is registered at LOAD.
#    Disassemble the suspect static-init thunk; confirm it constructs a
#    std::recursive_mutex AND calls ___cxa_atexit to register its dtor.
otool -arch arm64 -tV "$BIN" \
  | sed -n '/__GLOBAL__sub_I_<rmsdk_tu>/,/^_[A-Za-z]/p' \
  | grep -iE 'recursive_mutex|__cxa_atexit'
#    → a ___cxa_atexit call INSIDE a __mod_init_func thunk = dtor registered at
#      dylib LOAD (before main, before didFinishLaunching). ← LOAD-TIME CONFIRMED.

# 6. DISCONFIRM the lazy (Meyers function-local) alternative.
nm -arch arm64 "$BIN" | grep -E '___cxa_guard_(acquire|release)'
#    → if the mutex construction is ___cxa_guard-protected INSIDE the owning
#      function (sharedInstance) and ABSENT from __mod_init_func, it is lazy.
```

### Easiest empirical cross-check (no disassembly)

`dyld` can print every initializer as it runs at load, before `main`:

```bash
# On the Mac host, launch the "Designed for iPad" app with:
DYLD_PRINT_INITIALIZERS=1 <path-to-app-binary> 2>&1 | grep -iE 'adept|dp|rmsdk|adobe'
```

If an Adobe/RMSDK initializer prints during launch (i.e. before the app's own
`[BUILD MARKER]` log line), the static constructs at **load time** — assumption
confirmed empirically.

### Decision rule

| Observation | Verdict | Action |
|---|---|---|
| Mutex dtor registered by a `__mod_init_func` thunk (step 5) AND no `__cxa_guard` around it (step 6) AND/OR Adobe initializer prints under `DYLD_PRINT_INITIALIZERS` | **CONFIRMED load-time** | Path B LIFO ordering holds. Proceed to CHECK 2. |
| Mutex construction is `__cxa_guard`-protected in the owning function, absent from `__mod_init_func` | **REFUTED (lazy)** | Path B not guaranteed by didFinishLaunching registration. Path A (Cmd-Q) still correct. Revisit: register the atexit at the earliest possible point, or accept Path-A-only and document Path B as residual risk. Escalate to w-mutex. |

---

## CHECK 2 — simdrive Mac round-trip (end-to-end, both paths)

Runs the "Designed for iPad" build on the Apple Silicon Mac host (where
`ProcessInfo.processInfo.isiOSAppOnMac == true` — this is false on the simulator,
so the crash cannot be reproduced in a sim). Journey skeleton:
`.simdrive/journeys/ws4-ipad-on-mac-exit-adobe-drm.yaml`.

1. Launch; ensure a library with **Adobe-DRM** content is added + signed in.
2. Borrow + **open an Adobe-DRM (ACSM/Adobe-EPUB) book** — exercises the full
   RMSDK path (note: even cold launch constructs the load-time static, but
   opening a book is the strongest exercise).
3. **Path A (normal):** quit via **⌘Q**. Assert: no `recursive_mutex` /
   `EXC_*` / SIGABRT in Console; no new Crashlytics `9a91840677` event.
4. Relaunch + reopen the book. **Path B (forced/watchdog):** trigger the
   `FinalTerminationWatchdog` / force-quit so `applicationWillTerminate` is
   **skipped**. Assert: atexit interceptor fires (`_exit(0)`); same no-crash
   assertion as Path A.
5. **Device regression** (real iPhone/iPad, `isiOSAppOnMac == false`): confirm
   normal termination is **unchanged** (no `_exit` short-circuit) and Adobe
   borrow / open / return still work.

PASS = both paths quit clean on Mac AND device behavior unchanged.

---

## Promotion gate

`cs_b77ea7cc` does **not** advance past the testing/verification gate until
CHECK 1 = CONFIRMED and CHECK 2 = PASS. Behind M0 regardless. On pass, fold in
the two non-blocking review findings (stale `iPadOnMacRMSDKGuardTests` file
header describing the old #928 approach; ADR coverage-section note that the
side-effecting `registerStaticDestructorBypassIfNeeded` atexit path is covered
by the Mac run, not a unit test).
