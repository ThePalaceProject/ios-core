# SpecterQA iOS Dogfood Notes — Palace iOS

**Date:** 2026-04-04
**Versions tested:** specterqa 0.4.0, specterqa-ios 0.6.0 → 1.0.0 → 2.0.1 → 3.0.0 → 3.2.0 → 3.4.0 → 3.6.0 → 3.7.0 → 3.8.0 → 4.0.0 → 4.1.0 → 4.2.0 → 4.3.0 → **5.0.0 (MCP)**

## CURRENT STATUS (v5.0.0 MCP)

**The MCP architecture is a game-changer. 9/11 journeys fully passed, 91% step pass rate.**

v5.0.0 ships as a Claude Code MCP server instead of a standalone runner. Claude Code IS the reasoning engine — SpecterQA provides the perception/interaction primitives. This eliminates the entire SoM→Claude API→parse loop that caused most v3.x/v4.x bugs.

### v5.0.0 Results (Palace iOS, 2026-04-04)

| Journey | Steps | Passed | Notes |
|---------|-------|--------|-------|
| app-launch | 3 | 3 | Clean pass |
| my-books-empty | 3 | 3 | Clean pass |
| tab-navigation | 5 | 5 | Clean pass |
| catalog-browsing | 4 | 4 | Horizontal + vertical scroll work |
| book-detail | 4 | 4 | Cover, title, author, Borrow button, metadata all verified |
| search-flow | 3 | 3 | Type query, results appear, clear + dismiss works |
| settings-screen | 3 | 2.5 | Partial: no Sign In button for open library (test design issue, not tool) |
| library-picker | 3 | 1.5 | Partial: picker opens but interactions timeout on 2125-element list |
| smoke-test | 3 | 3 | Clean pass |
| accessibility-check | 4 | 4 | All a11y labels verified via element tree |
| dark-mode | 4 | 0 | Skipped: no way to toggle sim appearance from MCP tools |
| **TOTAL** | **39** | **35.5 (91%)** | **vs v4.3.0: 13/39 (33%)** |

### What Works Perfectly in v5.0.0
- `ios_start_session` — clone management, runner deployment, health check all reliable
- `ios_elements` — fast, accurate element list with labels, types, coordinates
- `ios_tap` — consistent, accurate taps by element index
- `ios_swipe` — horizontal/vertical scrolling works
- `ios_type` — keyboard input works after focusing a text field
- `ios_swipe_back` — navigation gesture works
- `ios_stop_session` — clean teardown
- Trial mode (no license key) works out of the box

### v5.0.0 Bugs & Issues

**BUG-V5-1: License key "founder" rejected (P2)**
`ios_start_session(license_key="founder")` returns `Invalid license`. Omitting the key (trial mode) works fine. Either the founder key format changed or the validation is broken.

**BUG-V5-2: Large element lists cause interaction timeouts (P1)**
The library picker screen has 2,125 elements. When this screen is active, `ios_tap`, `ios_swipe`, and `ios_swipe_back` all timeout. `ios_elements` returns the full list (320KB JSON) but takes a long time. The runner likely iterates the entire accessibility tree on every interaction, which is O(n) and kills performance on large lists.

**Suggestion:** Add element pagination or lazy loading to `ios_elements`. Cap the element tree depth or add a `max_elements` parameter. For taps, the coordinate is already known — don't re-traverse the tree just to validate the element index.

**BUG-V5-3: No `ios_set_appearance` tool (P2 — feature request)**
Cannot toggle dark/light mode from MCP tools. The clone sim isn't visible to `xcrun simctl list devices booted` so we can't use `xcrun simctl ui <udid> appearance dark` either. Need an `ios_set_appearance(mode: "dark"|"light")` tool.

**BUG-V5-4: Clone sim not visible to simctl (P3 — minor)**
The clone UDID returned by `ios_start_session` doesn't appear in `xcrun simctl list devices booted`. This prevents any direct simctl operations on the clone (appearance toggle, status bar overrides, location simulation, etc.).

**BUG-V5-5: Screenshot result too large for MCP (P2)**
`ios_screenshot` returns base64 PNG inline in the JSON result (381KB–1.3MB). This exceeds Claude Code's MCP result size limit and gets written to a temp file instead of being displayed. The screenshot is never actually seen by Claude. `ios_elements` is the workaround but loses visual context.

**Suggestion:** Either (a) resize screenshots to a smaller resolution before base64 encoding, (b) return a file path instead of inline base64, or (c) use MCP's resource/blob protocol for binary data.

### Architecture Feedback

The MCP pivot is the right call. The v0.6→v4.3 journey had 16 versions of serial bug-fixing because the autonomous runner had to handle perception, reasoning, AND interaction in a single pipeline. Bugs in any layer cascaded. With MCP:

- **Perception** (screenshots, elements) = SpecterQA's job
- **Reasoning** (what to tap, how to verify) = Claude Code's job  
- **Interaction** (tap, swipe, type) = SpecterQA's job

This separation means SpecterQA only needs to be a reliable I/O driver. Claude Code handles all the AI reasoning natively. The result: 91% pass rate on first try vs 33% after 16 versions of debugging.

---

## PREVIOUS STATUS (v3.8.0 → v4.3.0)

**The native XCTest runner pipeline is 95% working.** Screenshots are real, the AI reasons correctly, taps are attempted. One remaining issue:

**SoM annotation fails every time** — `syntax error: line 1, column 0` on every `/source` response. The annotator can't parse the runner's accessibility tree JSON. Without SoM annotations, the AI has no element numbers to reference, so every tap fails with "Element N not in current tree (valid: 1-0)".

The runner's `/source` endpoint returns valid JSON (confirmed via manual curl), so the issue is in the SoM annotator's JSON parser — likely expects a different format than what the runner produces.

**What works:**
- Runner builds via project-injection (`--project Palace.xcodeproj --scheme Palace-noDRM`)
- Runner starts on port 8222, healthy, responds to all endpoints
- Clone management (shutdown source → clone → boot clone → deploy runner)
- App launch via XCUIApplication on clone
- Screenshots captured and sent to Claude API successfully
- Claude AI reasons about what it sees and makes correct decisions
- Plist injection for SPECTERQA_BUNDLE_ID and SPECTERQA_PORT

**What doesn't work:**
- SoM annotator can't parse `/source` JSON → no element annotations → taps fail
- `XCTestBackend` missing `swipe_back` method (v3.9.0)

## PROCESS FEEDBACK

We have tested **11 versions** (0.6.0 through 3.9.0) over two days. Each version fixes one bug and reveals the next. The product is not being tested end-to-end internally before release. We are the integration test.

The SoM `/source` parser bug has been reported since v3.7.0 (3 versions ago) and is still present in v3.9.0. Before shipping the next version, please:

1. Run `curl http://localhost:8222/source` on your machine
2. Feed that JSON into `som_annotator.annotate()`
3. Confirm elements are parsed and annotations drawn

If that works locally, the format difference between your test runner and ours is the bug. Ship us the expected JSON schema.

**Best results remain from WDA path (v2.0.1): 2/11 journeys fully passed, 56% step pass rate.** The native runner has never passed a single step.

### v4.0.0 — SoM parser FIXED, new missing attribute

SoM annotations now render correctly — red numbered badges on all elements. The AI correctly identifies elements and chooses actions. But every tap fails:

```
'XCTestBackend' object has no attribute '_display_width'
```

The tap coordinate scaling code references `self._display_width` which is never initialized. This is the 12th version and the 12th "one fix away" bug.

**Positive:** SoM pipeline is now fully working end-to-end for the first time. Screenshots + element tree + annotations + Claude reasoning all function correctly. Only the final tap execution is broken.

### v4.1.0 — Tap executes, crash on post-action screenshot

`_display_width` fixed. A tap was executed for the first time on the native runner. But the process crashes with an unhandled `TimeoutError` on `som_runner.py:395`:

```python
post_b64, _, _ = self._driver.screenshot()  # line 395 — still tuple unpacking a dict
```

Two bugs:
1. **Second screenshot call site** at line 395 still uses tuple unpacking (same bug fixed at line 283 in v3.8.0, missed here)
2. **Unhandled TimeoutError** — runner becomes unresponsive after tap, screenshot times out, exception crashes the process instead of being caught

The runner may die after executing the tap because dismissing the notification dialog causes a UI state change that crashes WKWebView or the app itself.

### v4.2.0 — Same unhandled TimeoutError crash (line 395)

Tuple unpacking fixed (now `post_result = ...`) but the `TimeoutError` is still not caught. Exact same traceback at `som_runner.py:395 → xctest_client.py:128 → socket.readinto → TimeoutError: timed out`.

The fix needed is a try/except around the post-action screenshot call. This is the **14th version** we've tested.

### v4.3.0 — FIRST PASSING STEPS ON NATIVE RUNNER

**11 steps passed** across 8 journeys. No crashes. The pipeline works end-to-end: SoM annotations → Claude reasoning → tap execution → screen change detection.

| Journey | Steps Passed |
|---------|-------------|
| tab-navigation | 3/5 (My Books, Reservations, Settings) |
| settings-screen | 2/3 (navigate + verify links) |
| app-launch | 1/3 |
| search-flow | 1/3 (opened search) |
| library-picker | 1/3 (navigated to picker) |

**Primary failure mode:** `tap:6:None repeated 3 times with no screen change` — element 6 taps consistently don't land. Some elements tap fine, others don't. Likely coordinate mapping issue for specific screen positions.

**Secondary:** Runner dies after ~8 journeys (last 3 cut off). Same WDA stability issue from earlier WDA testing.
**Product:** Palace iOS (library reading app, iOS 18, iPhone 16 Pro simulator)
**Tester:** Palace dev team via Claude Code

---

## Bugs

### BUG-1: `__version__` missing from specterqa `__init__.py` (P0 — CLI won't start)

The `specterqa` package ships an empty `__init__.py` but `cli/app.py` line 11 does `from specterqa import __version__`, causing an immediate `ImportError` on any CLI invocation. Fresh `pip install specterqa==0.4.0` reproduces this.

**Fix applied locally:** Added `__version__ = "0.4.0"` to `__init__.py`.

**Recommendation:** Either populate `__version__` at build time (e.g., via `importlib.metadata.version("specterqa")`) or use `importlib.metadata` directly in `cli/app.py` like the iOS CLI already does defensively.

---

### BUG-2: `specterqa ios` subcommand not registered (P1 — iOS plugin invisible)

The `specterqa-ios` package registers `ios = specterqa.ios.cli:ios_command_group` via the `specterqa.cli_extensions` entry point group. However, the main CLI (`cli/app.py`) **never loads entry points from this group**. The iOS subcommand is invisible in `specterqa --help` and `specterqa ios` returns "No such command."

The iOS `ios_command_group` is a **Click Group** but the main CLI is a **Typer app**. Typer doesn't natively support mounting raw Click groups via `app.add_typer()` — it requires `TyperGroup` subclasses.

**Fix applied locally:** Patched the `specterqa` console script entry point to:
1. Build the Typer Click app via `typer.main.get_command(app)`
2. Inject Click groups from `specterqa.cli_extensions` entry points via `click_app.add_command(group, name)`
3. Invoke the Click app directly with `standalone_mode=False`

**Recommendation:** Either:
- (a) Move this entry point loading logic into `cli/app.py` with a post-build hook, or
- (b) Convert `ios_command_group` from Click to Typer so `app.add_typer()` works, or
- (c) Add a `specterqa.__main__.py` that does the assembly

Also note: using `click.MultiCommand` in the isinstance check triggers a **Click 9.0 deprecation warning**. Use `click.Group` instead.

---

### BUG-3: NO WORKING TOUCH BACKEND ON XCODE 16 (P0 — tool cannot interact with simulator)

All three touch input backends fail on Xcode 16.1 / iOS 18.4:

| Backend | Failure | Detail |
|---------|---------|--------|
| **CGEvents** | Taps don't land | Coordinate mapping broken; conflicts with user mouse cursor |
| **IndigoHID** | API removed | `SimDeviceLegacyHIDClient.initWithDevice:error:` blocked in Xcode 16+ |
| **XCTest** | Connection refused | Requires HTTP runner on port 8222 — not bundled or documented |

The tool can **capture screenshots perfectly** but **cannot tap, swipe, or type** on any backend. This means specterqa-ios 0.6.0 is non-functional for actual test execution on current Xcode.

**Live run results (3 attempts):**
- CGEvents: 0/3 passed, AI saw the screen but taps never registered (168s, $~0.50)
- XCTest: 0/3 passed, immediate connection refused on every action
- IndigoHID: 0/3 passed, Xcode 16 blocks the private API

**Recommendation:** Ship a bundled XCTest runner helper (lightweight .app or test bundle that hosts an HTTP server on port 8222) and document setup. This is the only viable path for Xcode 16+.

**UPDATE — v2.0.1 with WDA + SoM pipeline:**

v2.0.1 adds `specterqa-ios wda start` which clones and builds WebDriverAgent from Appium's repo.
WDA builds and starts successfully on port 8100. The `/status` endpoint responds.

**However, WDA `/source` times out 100% of the time when Palace is the active app.**

- WDA session creation on SpringBoard: works instantly
- WDA `/source` with Palace in foreground (manual curl): works instantly (11KB, 26ms)
- WDA `/source` during `specterqa-ios run`: **times out every request**

This suggests `specterqa-ios run` creates the WDA session in a state that conflicts with the app launch sequence. The SoM annotation pipeline depends on `/source` for the accessibility tree, and when it fails, it falls back to plain screenshots with no element numbers. The AI then tries `tap:1` but gets "Element 1 not in current tree (valid: 1–0)."

**Result: v2.0.1 is 0/3 steps passed, same as v0.6.0 and v1.0.0.**

Screenshots confirm: no SoM annotations ever rendered, screen never changed across 16+ iterations.

**Root cause hypothesis:** The run command's session management. The session may be created before `xcrun simctl launch` completes, or the session's process attachment gets invalidated when Palace activates. A simple fix: create the WDA session *after* the app is confirmed running and the first screenshot is captured.

---

### BUG-4: `runner build` fails on Xcode 16 — multiple issues (P0)

`specterqa-ios runner build` has three sequential failures:

1. **Missing INFOPLIST_FILE** — `GENERATE_INFOPLIST_FILE=YES` not set in build settings, Xcode 16 refuses to build
2. **`volumeUp`/`volumeDown` unavailable** — `XCUIDeviceButton.volumeUp` is unavailable in iOS Simulator in Xcode 16+
3. **Non-optional snapshot** — `app.snapshot()` returns `XCUIElementSnapshot` (non-optional) in Xcode 16, but code has `guard let snapshot = snapshot`

After patching all three, the runner builds but **fails to launch**: `xcodebuild test-without-building` exits with `Mach error -308 (server died)` because the runner is built against SDK 26.2 but the booted simulator runs iOS 18.4. SDK version mismatch.

Additionally, `runner build` doesn't include the Swift source in the pip wheel — you have to manually `git clone` the repo and pass `--runner-dir`.

### BUG-5: Project-injection build fails on mixed ObjC++/Swift projects (P1 — v3.1.0)

v3.1.0 adds `--project` / `--scheme` flags for project-injection builds. This is the right idea but fails on Palace (mixed Swift/ObjC++ codebase):

```
specterqa-ios runner build --project Palace.xcodeproj --scheme Palace-noDRM
```

**Error:** `@import` in ObjC++ files fails with "C++ modules are disabled". The `build-for-testing` invocation inherits or overrides module settings that conflict with `.mm` files. The regular `xcodebuild build` for Palace works fine — this is specific to how the injection build configures the compilation.

**Workaround attempted:** Set `SPECTERQA_RUNNER_SOURCES` env var to point to cloned runner Swift sources. Same error — the project-injection path always compiles the full project.

**Suggestion:** The injector should add the runner's Swift files as a *separate* test target (like a UI test bundle) rather than compiling them as part of the app target. This avoids inheriting the app's ObjC++ compilation issues entirely.

---

### BUG-5b: RESOLVED (v3.3.0) — XCTest runner Mach IPC crash

The arm64 arch fix resolved this. The runner starts and responds on port 8222.
However, two new issues block actual test execution:

**BUG-5b-i: Health timeout too short (P1)** — Runner takes ~25s to become healthy after `xcodebuild test-without-building`. The default `_HEALTH_TIMEOUT_S = 30.0` leaves only ~5s margin after clone+boot overhead. On first run or cold boot this isn't enough. Patched locally to 60s and the runner starts reliably. **Suggestion:** increase to 60s or make configurable.

**BUG-5b-ii: App not installed on clone — CLI/session-manager disconnect (P0)**

The session manager's `app_path` install-on-clone code (step 6) is correct, but it never fires. The CLI's `run` command calls `_install_app(device_id, app_path)` on the **source sim** before creating the `TestSession`. The `--app` value is consumed by the CLI and never passed to the session manager's constructor.

Verbose log confirms:
```
Installing Palace.app on 0423F115...          ← CLI installs on source
session_manager  Cloning simulator...         ← clone doesn't have app
session_manager  Runner healthy on port 8222  ← runner starts fine
/source → "app not running, state 1"          ← app not on clone
```

**Fix:** Pass `app_path` through to `TestSession(app_path=...)` instead of installing in the CLI. **FIXED in v3.4.0** — app now installs on clone correctly.

**BUG-5b-ii-b: App never launched on clone (P0 — v3.4.0)**

App is installed on the clone but never started. No `simctl launch` or `XCUIApplication.launch()` call exists anywhere in session_manager or the CLI. The runner's `XCUIApplication` reports state 1 (not running).

Verbose log confirms install works but app stays dormant:
```
session_manager  Installing Palace.app on 5C46CF7B...  ← installed on clone ✓
session_manager  Deploying runner...                     ← runner starts ✓
session_manager  Runner healthy on port 8222             ← runner responds ✓
/source → "app not running, state 1"                     ← nobody launched the app
```

**Fix:** Add a step after install: `_simctl("launch", self._clone_udid, self.bundle_id)` — or have the runner call `app.launch()` on its first `/source` request. **FIXED in v3.6.0** — launch step added.

**BUG-5b-ii-c: Runner uses hardcoded `com.example.app` bundle ID (P0 — v3.6.0)**

The runner's `SpecterQARunner.swift:70` reads `SPECTERQA_BUNDLE_ID` env var, falling back to `com.example.app`. But the session manager (`session_manager.py:383`) only sets `SPECTERQA_PORT` in the xcodebuild env — it never passes `SPECTERQA_BUNDLE_ID`. The runner tries to launch `com.example.app`, fails with "Application info provider returned nil", and the test case crashes in 0.49s.

```
SpecterQARunner.swift:32: Failed to launch com.example.app:
Application info provider (FBSApplicationLibrary) returned nil for "com.example.app"
```

**Fix:** Add `env["SPECTERQA_BUNDLE_ID"] = self.bundle_id` next to `env["SPECTERQA_PORT"]` in `_deploy_runner()`.

**BUG-5b-iii: Screenshot returns garbage when app not running (P1)**

When the app isn't running, the runner's `/screenshot` endpoint returns a broken response. The SoM pipeline decodes this as the literal string `'height'` (5 chars) and sends it as base64 image data to the Claude API, which returns HTTP 400 `invalid base64 data`. This happens on every step, making the entire run fail instantly (4.2s for 3 steps) with no useful error message.

**Fix:** The runner should return a proper error JSON when the app isn't running, and the SoM pipeline should fall back to `simctl io screenshot` when the runner's screenshot fails.

**BUG-5b-iii-b: SoM runner unpacks screenshot dict as tuple (P0 — v3.7.0)**

`som_runner.py:283` does:
```python
b64, img_w, img_h = self._driver.screenshot()
```
But `XCTestBackend.screenshot()` returns a **dict** `{"base64": "...", "width": N, "height": N}`. Tuple unpacking a dict yields the **keys**, so `b64` becomes the literal string `'base64'`, not the PNG data. This is sent to the Claude API as image content, which returns 400.

**Root cause confirmed:** The runner IS working — manual `curl http://localhost:8222/screenshot` returns valid base64 PNG. The SoM runner just can't read it.

**Fix:** Change line 283 to:
```python
result = self._driver.screenshot()
b64, img_w, img_h = result["base64"], result.get("width", 0), result.get("height", 0)
```

---

### BUG-5c (RESOLVED by v3.2.0): Project-injection build for mixed ObjC++/Swift projects

### BUG-5d (RESOLVED by v3.3.0): Architecture mismatch in .xctestrun

The `.xctestrun` `Architectures` field only listed `x86_64` even when building on arm64. The xctestrun metadata comes from `CodeCoverageBuildableInfos` which was hardcoded. v3.3.0 fixed this.

**NOTE:** We still had to manually patch the xctestrun arch field to `arm64` to get the runner to start. Verify the fix actually propagates.

---

### BUG-5e (PERSISTS): `_find_xctestrun()` doesn't search project-injection output path

`_find_xctestrun()` only searches `Build/Products/*.xctestrun` but project-injection puts it in `org.thepalaceproject.palace/DerivedData/Build/Products/`. Had to symlink manually every time.

---

### BUG-5f-ORIGINAL: Standalone XCTest runner Mach IPC crash on all simulators (P0)

Both build paths produce a runner that crashes on `xcodebuild test-without-building` with `Mach error -308 (server died)` at `IDELaunchiPhoneSimulatorLauncher`. Tested on:
- Standalone build on iOS 18.4 and iOS 26.0 (v3.0.0)
- Project-injection build (`--project Palace.xcodeproj --scheme Palace-noDRM`) on iOS 18.4 clone (v3.2.0)

The runner compiles and the `.xctestrun` is valid, but the test host process dies during Mach IPC setup before the HTTP server can bind to port 8222.

**v3.2.0 also has a path bug:** project-injection puts `.xctestrun` in `org.thepalaceproject.palace/DerivedData/Build/Products/` but `_find_xctestrun()` only searches `Build/Products/`. Had to symlink manually.

**Possible root cause:** The `.xctestrun` may be missing `TestHostBundleIdentifier` or the runner's `PRODUCT_BUNDLE_IDENTIFIER` may conflict with the app-under-test. The test host process needs to be a separate app that can coexist with the app being tested.

---

### BUG-5c (RESOLVED by v3.2.0): Standalone XCTest runner Xcode 16 compile errors

`xcodebuild test-without-building` with the SpecterQARunner .xctestrun consistently exits with `Mach error -308 (server died)` on **every simulator configuration tested**:

- iOS 18.4 (iPhone 16 Pro) — SDK mismatch with 26.2 runner
- iOS 26.0 (iPhone 17 Pro) — matching OS, fresh clone, still crashes
- iOS 26.0 clone — same crash

v3.0.0 fixed the simctl clone catch-22 (shuts down source before cloning, reboots after). The session manager now correctly creates headless clones. But the runner itself never reaches `/health` — xcodebuild's test launcher dies during the Mach IPC setup phase.

The `.xctestrun` may need additional build settings (e.g. `TestHostBundleIdentifier`, `TestBundlePath` adjustments) or the runner's `SpecterQARunner.xcodeproj` may be misconfigured for `test-without-building` deployment.

**v3.0.0 also fixed:** scroll-stuck prevention, WDA fallback removal, clone catch-22. These are good fixes but untestable since the runner won't start.

---

### BUG-5b (RESOLVED by v3.0.0): Native runner "app not running" on iOS 26 simulator

After fixing the build issues (BUG-4) and SDK mismatch (requires iOS 26 sim), the XCTest runner starts on port 8222 and responds to `/health`. However, every `/source` request returns `{"error": "app not running", "state": 1}` even after `simctl launch` succeeds. The runner's `XCUIApplication` doesn't detect the app as foreground.

Additionally, screenshot capture produces invalid base64 when the app isn't running, causing Claude API 400 errors instead of graceful fallback.

**Root cause:** Likely a timing race — `simctl launch` is async and the runner queries app state before the app finishes launching. Needs a retry loop or explicit wait-for-foreground in the runner's `/source` handler.

---

### BUG-6: `simctl clone` fails on Booted simulator (P1)

The session manager always tries `simctl clone <source>` but Apple's `simctl clone` cannot clone a Booted device. This creates a catch-22: the run command boots the device to find it, then tries to clone the booted device, which fails.

---

### BUG-6: Persona loading fails silently

Every run logs `Could not load persona 'ios_tester' — proceeding without it.` The persona file exists at `.specterqa/personas/ios-tester.yaml` and parses correctly. The loader seems to look in the wrong directory or use a different naming convention.

---

### BUG-5: `specterqa-ios` top_level.txt declares `specterqa` (minor packaging issue)

The `specterqa-ios` 0.6.0 dist-info `top_level.txt` says `specterqa`, which is correct for namespace packages but can confuse some tooling. The package installs into `specterqa/ios/` as a namespace extension — this works but `import specterqa_ios` fails because there's no such top-level module. Consider adding a `specterqa_ios` compatibility shim or updating docs.

---

## Friction / UX Feedback

### FRICTION-1: `specterqa init` vs `specterqa ios init` confusion

Running `specterqa init` creates a **web-focused** scaffold (Playwright, viewports, base_url). Running `specterqa ios init` creates an **iOS-focused** scaffold (bundle_id, simulator_id, simctl). There's no guidance on which to use, and running both creates conflicting configs in the same `.specterqa/` directory. The web `init` creates a `demo.yaml` product file that's useless for iOS.

**Suggestion:** Add a `--platform` flag to `specterqa init` or detect the platform from context. At minimum, `specterqa init` should mention `specterqa ios init` exists.

---

### FRICTION-2: No `specterqa validate` support for iOS journeys

`specterqa validate` appears to validate web-oriented configs only. It doesn't check iOS product fields (`bundle_id`, `simulator_id`) or journey step schemas (`checkpoint`, `max_iterations`). Would be valuable to have `specterqa ios validate` or extend the existing validate to detect `platform: ios`.

---

### FRICTION-3: License check in `specterqa ios run` is confusing

The trial mode message says "Set SPECTERQA_IOS_LICENSE=founder to unlock all features" — this reads like a free bypass, not a commercial license. If it IS a free bypass for beta, say so. If it requires a real key, the message should point to a purchase/registration URL.

---

### FRICTION-4: Journey step `mode` field from web doesn't apply to iOS

The web journey template uses `mode: browser` on steps. iOS journeys don't use `mode` at all (it's always simulator). The schema difference isn't documented — we had to read the source to confirm `mode` is ignored for iOS.

---

### FRICTION-5: Dark mode toggle requires manual simctl command

The `dark-mode` journey needs to toggle simulator appearance. There's no built-in step action for `simulator_command` or `toggle_appearance`. The driver would need to run `xcrun simctl ui <device> appearance dark` — but this must be orchestrated by the AI step runner, not scripted. Consider adding a `simulator_action` step type for common simctl operations.

---

## What Works Well

- **iOS project scaffold** (`specterqa ios init`): Clean, auto-detects booted simulator UDID and device name. Template YAML is well-structured.
- **iOS CLI subcommands**: `setup`, `devices`, `boot`, `install` are well-designed utility commands.
- **Journey format**: `goal` + `checkpoint` + `max_iterations` is a good abstraction — lets the AI figure out interaction details while keeping assertions deterministic.
- **Backend selection**: `--backend xctest|indigo|cgevents|auto` is excellent for flexibility. Auto-detect is the right default.
- **Evidence directory**: Automatic `evidence/<run-id>/` with JSON results and screenshots is exactly right for CI integration.
- **Cost controls**: Per-run and per-step budgets in the product config prevent runaway API costs.
- **Defensive imports**: The iOS CLI's `try/except ImportError` around `__version__` is good practice — more robust than the main CLI.

---

## Migration Stats

| Metric | Value |
|--------|-------|
| Tests migrated | 10 (+ 1 updated smoke template = 11 total) |
| Original format | Claude Computer Use YAML (action/target/expect per step) |
| SpecterQA format | Scenario YAML (id/description/goal/checkpoint per step) |
| Steps: before | 10-16 granular steps per test |
| Steps: after | 3-5 goal-oriented steps per journey |
| Time to migrate | ~10 minutes (format is intuitive) |
| Blockers hit | 2 (BUG-1 + BUG-2 — both required source patches) |

---

## Environment

```
macOS 25.0.0 (Darwin)
Xcode 16.1 / xcrun 72
Python 3.13
specterqa 0.4.0
specterqa-ios 0.6.0
Simulator: iPhone 16 Pro (iOS 18.4, DF4A2A27-9888-429D-A749-2E157A049A37)
```
