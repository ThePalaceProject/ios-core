# RegressionGuards

Targeted XCTest cases that guard against four high-volume Crashlytics crash
families seen post-3.0.0. Each test exercises the **fix path** so that a
future code change which reverts or bypasses the fix will fail this suite
loudly, rather than escaping silently to production.

These are **not** "I'm testing the unit's API" tests — they are
"if a developer breaks the regression fix, the test fails first" tests.

## Crash families covered

### 1. UIAlertController CACommit (`UIAlertCACommitGuardTests`)

- **Crashlytics events**: 55 (post-3.0.0)
- **Symptom**: `NSInternalInconsistencyException` thrown during
  `_UIAfterCACommitBlock` — UIKit barfs when an alert is asked to present
  during a view-controller transition or against a nil/invalid presenter.
- **Fix surface**: `Palace/ErrorHandling/TPPAlertUtils.swift`
  - `presentFromViewControllerOrNil` adds nil-presenter, transitionCoordinator,
    isBeingPresented/Dismissed, view-not-in-window, and already-presenting-alert
    guards plus retry-with-backoff and ObjC exception catcher around
    `presenter.present()`.
  - `setProblemDocument(controller:document:append:)` short-circuits on nil.
- **What the guards verify**:
  - Nil controller → no crash, no work attempted.
  - Nil presenter + nil top VC fallback → exits gracefully, calls completion.
  - Empty/garbage error domain → produces a valid `UIAlertController` instead
    of throwing.

### 2. Botan X509 CRL decode in R2LCPClient (`LCPBotanCRLGuardTests`)

- **Crashlytics events**: 249
- **Symptom**: C++ exception escapes from `R2LCPClient.decrypt` when the
  Botan library encounters a malformed CRL during license context creation.
  Untrapped C++ exceptions abort the process.
- **Fix surface**: `Palace/Reader2/ReaderStackConfiguration/LCP/TPPLCPClient.swift`
  - `decrypt(data:using:)` and the extension `decrypt(data:)` short-circuit
    when the DRM context is invalid or the input data is empty — preventing
    the path that lets Botan run with bad input.
  - PR #929 adds an ObjC++ exception wrapper on top of this; this guard
    keeps the upstream short-circuits honest regardless of the wrapper.
- **What the guards verify**:
  - Empty data → returns nil, no R2LCPClient call.
  - Non-`DRMContext` context → returns nil, no R2LCPClient call.
  - `createContext` propagates errors instead of returning silent nil.

### 3. iPad-on-Mac RMSDK static destructors (`iPadOnMacRMSDKGuardTests`)

- **Crashlytics events**: 294
- **Symptom**: `recursive_mutex` lock failure during Adobe RMSDK static
  destructor when the iPad app runs on Apple Silicon Macs.
- **Fix surface**: PR #928 — `Palace/MyBooks/AdobeDRMHandler.swift` short-circuits
  Adobe DRM init when `ProcessInfo.processInfo.isiOSAppOnMac` is true.
- **Status**: **PR #928 not yet merged.** This file currently contains
  **placeholder tests** that document the expected guard. Once #928 lands,
  expand them to assert the gating behavior (`AdobeDRMHandler.shouldEnable
  == false` on iPad-on-Mac, and `== true` otherwise).

### 4. Findaway FAEChapterStatus semaphore dispose (`FindawayChapterStatusGuardTests`)

- **Crashlytics events**: 16 + 8 (combined)
- **Symptom**: Vendor SDK (Findaway / PalaceAudiobookToolkit submodule) holds
  a `dispatch_semaphore_t` past dealloc. Crashes during chapter switching
  on long audiobooks.
- **Fix status**: **No app-side fix possible** (vendor SDK). This guard
  documents the workaround surface — Palace ensures the chapter-status path
  doesn't allocate FAEChapterStatus objects on threads that are likely to
  deallocate concurrently.
- **What the guard verifies**: any Palace code that handles audiobook chapter
  status keeps a strong reference to the chapter object until the
  observer/callback completes — encoded as a documentation comment + a
  stub test that fails if the canonical reference pattern is removed.

## Adding a new regression guard

1. Capture the Crashlytics finding in memory at
   `~/.claude/projects/-Users-mauricework-PalaceProject-ios-core/memory/`.
2. Identify the production fix surface and the **specific pre-condition the fix
   establishes** (e.g. "a nil-check at line 137").
3. Write one XCTestCase here named `<ShortDescription>GuardTests.swift`.
4. Each test method's name should describe the **regression it would catch**
   (e.g. `testPresentFromViewControllerOrNil_WithNilController_DoesNothing`).
5. The test must fail if the fix is reverted. Run mutation testing on the
   fix surface to verify:
   ```bash
   python3 scripts/palace_mutate.py \
     --file Palace/ErrorHandling/TPPAlertUtils.swift \
     --tests PalaceTests/RegressionGuards/UIAlertCACommitGuardTests
   ```
   Aim for ≥1 mutation killed by your guard test specifically.

## When to remove a guard

Never. Crash families recur. The cost of a fast, cheap test is far less
than the cost of the same crash escaping again because we forgot.
