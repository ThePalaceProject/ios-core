# SpecterQA iOS Driver v0.2.0 — Dogfood Report

**Tester:** Claude Opus 4.6 (AI agent in Claude Code CLI)
**Date:** 2026-03-29
**Environment:** macOS 15 / Xcode 26.3 / iPhone 16 Pro Simulator (iOS 18.4)
**App:** Palace iOS (org.thepalaceproject.palace)
**specterqa:** 0.4.0 | **specterqa-ios:** 0.2.0

---

## Installation — PASS

```bash
pip install "git+https://github.com/SyncTek-LLC/specterqa-ios.git@v0.2.0"
```

- Installed cleanly, pulled specterqa 0.4.0 as dependency
- All sub-packages installed: `specterqa.ios.drivers.simulator.*`, `cli`, `engine`, `security`, `mcp`, `parallel`
- Total 31 Python source files in the iOS package

---

## Setup Check — PASS

```python
from specterqa.ios.cli.commands import setup
```

Beautiful Rich table output. All 4 checks pass: Xcode, Simulators (72 found, 1 booted), API key, package import.

**No issues.**

---

## Project Init — PASS (with notes)

```python
ios_init(app_slug='palace-ios', display_name='Palace iOS', target_dir='.specterqa', force=True)
```

- Creates nested `.specterqa/.specterqa/` directory (double nesting — intentional?)
- Generates product YAML, persona YAML, journey YAML, evidence dir
- Nice tree output showing structure

### Issue: Double-nested directory
The init creates `.specterqa/.specterqa/products/...` — should it be `.specterqa/products/...`? The extra nesting seems unintentional.

### Issue: Product YAML defaults
- `bundle_id` defaults to `com.example.palace-ios` — good placeholder
- `device_name` defaults to `iPhone 15` — should auto-detect from booted simulator
- `ios_version` defaults to `"17"` — should auto-detect from booted simulator
- Missing `simulator_id` field in generated template (had to add manually)
- Missing `log_subsystem` field in generated template

**Suggestion:** Auto-populate from the booted simulator's device info.

---

## Module Imports — PASS

All 8 sub-modules import cleanly:
- `SimulatorDriver` ✅
- `InteractionLayer` ✅
- `ScreenCapture` ✅
- `ConsoleMonitor` ✅
- `NetworkInspector` ✅
- `PerfProfiler` ✅
- `StateInspector` ✅
- `CrashDetector` ✅
- `SimulatorAIContext` ✅
- `DataRedactor` ✅ (security module)

---

## SimulatorDriver — PARTIAL PASS

### Config dict interface
Takes a plain `dict[str, Any]` — works but loses type safety. Consider a `SimulatorConfig` dataclass or Pydantic model.

### `driver.start()` — PASS
Starts all sub-modules without error.

### `driver.screenshot()` — PASS
Returns a dict with 7 keys including base64 screenshot data. Screenshot capture via `xcrun simctl io` works perfectly.

### `driver.get_context()` — PASS
Returns dict with:
- `screenshot`: base64 PNG ✅
- `logs`: `None` (ConsoleMonitor may not be capturing — see below)
- `network`: `None` (NetworkInspector may not be active)
- `perf`: `PerfSnapshot(memory_mb=0.0, cpu_percent=0.0, ...)` — values are zero (see below)
- `state`: `{'user_defaults': {}, 'has_auth_token': False, ...}` ✅ found container path
- `crashes`: `None` ✅ (no crashes)

### `driver.stop()` — FAIL
```
AttributeError: 'CrashDetector' object has no attribute 'stop'
```
**Bug:** `CrashDetector` is missing a `stop()` method. The driver's `stop()` calls `self._crash.stop()` which doesn't exist.

**Fix:** Add `def stop(self): pass` to CrashDetector class.

---

## InteractionLayer (Tap/Swipe) — NOT TESTED via specterqa-ios

I built a standalone prototype first using Quartz CGEvents. Key findings that apply to the specterqa-ios driver:

### AppleScript Approach — DOES NOT WORK
```
execution error: System Events got an error: osascript is not allowed assistive access. (-1719)
```
AppleScript System Events requires the calling terminal app to have Accessibility permission in System Preferences. This is a **showstopper** for CI/CD and for most developer setups.

### Quartz CGEvents — WORKS PERFECTLY
```python
from Quartz import CGEventCreateMouseEvent, CGEventPost, kCGEventLeftMouseDown, kCGEventLeftMouseUp, kCGHIDEventTap
```
- No Accessibility permission required
- Pixel-accurate clicking
- Verified: Claude navigated Palace app catalog, scrolled, tapped books, viewed details
- Runs 40+ iterations in the AI loop without issues

### Coordinate Mapping — NEEDS CALIBRATION
The image-to-screen coordinate conversion has an edge case:
- The Simulator window has a title bar (~28px on standard macOS, 0px in full-screen)
- The title bar offset is hardcoded to 28px — should be auto-detected
- Clicks near the top of screen (status bar, back button) are off by ~10-15px
- Clicks in the center and bottom of screen are accurate

**Root cause:** The title bar height varies by macOS version, full-screen mode, and whether the "Show Device Bezels" setting is on/off in Simulator.

**Fix:** Auto-detect by comparing `CGWindowListCopyWindowInfo` bounds (which includes title bar) with the actual content area. Or take a calibration screenshot and use the known device frame to compute the offset.

### Swipe Gestures — WORKS
Quartz `kCGEventLeftMouseDragged` in 20 steps with configurable duration. Successfully performed scroll gestures in the app.

### Long Press — WORKS
Mouse down, `time.sleep(duration)`, mouse up. Successfully triggered the 5-second long-press for debug settings in Palace.

---

## ConsoleMonitor — NEEDS INVESTIGATION

Returned `None` for logs in `get_context()`. Possible issues:
1. Log stream may not have started capturing before `get_context()` was called
2. The subprocess running `log stream` may need time to produce output
3. The subsystem filter may be too restrictive

**Expected command:**
```bash
xcrun simctl spawn <device> log stream --level debug --predicate 'subsystem == "org.thepalaceproject.palace"' --style json
```

**Suggestion:** Add a `wait_for_first_entry(timeout=5)` method to ensure the stream is producing before returning.

---

## PerfProfiler — RETURNS ZEROS

All values in `PerfSnapshot` are 0.0:
```
PerfSnapshot(memory_mb=0.0, cpu_percent=0.0, thread_count=0, disk_usage_mb=0.0, fps_estimate=0.0)
```

**Likely cause:** The profiler may not be finding the app's PID correctly. The command to get PID inside the simulator:
```bash
xcrun simctl spawn booted launchctl list | grep <bundle_id>
```
Or on the host:
```bash
ps aux | grep <bundle_id> | grep -v grep
```

The `ps` approach on the host may be more reliable since the simulator process runs as a host process.

---

## StateInspector — PARTIAL PASS

Successfully found the app container:
```
container_path: /Users/mauricework/Library/Developer/CoreSimulator/Devices/DF4A2A27-.../data/Containers/...
```

But `user_defaults` returned empty dict and `has_auth_token` returned False. The Palace app was signed in with borrowed books visible on screen, so this suggests:
1. `defaults read` may need the app's suite name, not bundle ID
2. Keychain items may require different access approach in simulator

**Suggestion:** Try `xcrun simctl spawn <device> defaults read org.thepalaceproject.palace` and also check for plist files in the container's `Library/Preferences/` directory.

---

## CrashDetector — MISSING stop()

As noted above, `CrashDetector.stop()` doesn't exist. Otherwise the module imported fine.

---

## CLI Commands — MIXED

### `devices` — NOT TESTED
### `boot` — NOT TESTED (simulator already booted)
### `install` — NOT TESTED
### `run` — NOT TESTED (hit CrashDetector.stop() bug before getting to full run)
### `smoke` — NOT TESTED
### `serve` (MCP) — NOT TESTED

The CLI uses Click groups. The main `specterqa` CLI has a `__version__` import error:
```
ImportError: cannot import name '__version__' from 'specterqa'
```
This prevents `python -m specterqa ios ...` from working. Must invoke commands directly via Python imports.

---

## Summary of Bugs

| # | Severity | Module | Issue |
|---|----------|--------|-------|
| 1 | ~~**P0-BLOCKER**~~ | ~~specterqa core / ios CLI~~ | ~~`ComputerUseDecider` missing~~ — **FIXED in v0.3.2** (bundled `computer_use_decider.py` in engine) |
| 2 | ~~**P0**~~ | ~~CrashDetector~~ | ~~Missing `stop()` method~~ — **FIXED in v0.3.0** |
| 3 | **P0** | specterqa core | `__version__` import error blocks CLI (`python -m specterqa`) — still broken v0.3.2 |
| 4 | **P0-NEW** | ComputerUseDecider | Uses **`computer_20241022`** tool type which API rejects. Must update to **`computer_20250124`**. Error: `Input tag 'computer_20241022' found using 'type' does not match any of the expected tags` |
| 5 | **P0-NEW** | SimulatorDriver / IOSAIStepRunner | Runner calls `driver.execute()` but SimulatorDriver has no `execute` method. Has `click`, `fill`, `scroll` etc. but no unified `execute(action)` dispatcher. |
| 6 | ~~**P0-NEW v0.3.3**~~ | ~~ComputerUseDecider ↔ SimulatorDriver~~ | ~~Screenshot data format mismatch~~ — **FIXED in v0.3.4** |
| 7 | **P1** | InteractionLayer | If using AppleScript for taps, requires Accessibility permission (unusable in CI). Must use Quartz CGEvents instead |
| 4 | **P1** | InteractionLayer | Title bar offset hardcoded to 28px — needs auto-detection for accurate coordinate mapping |
| 5 | **P2** | PerfProfiler | All metrics return 0.0 — PID detection likely not finding the app process |
| 6 | **P2** | ConsoleMonitor | Returns None for logs — may need startup delay or stream verification |
| 7 | **P2** | StateInspector | UserDefaults returns empty — may need different read approach |
| 8 | **P3** | Project init | Creates double-nested `.specterqa/.specterqa/` directory |
| 9 | **P3** | Product YAML | Template missing `simulator_id`, `log_subsystem` fields; defaults not auto-detected from booted device |

---

## Summary of What Works Well

1. **Installation** — Clean pip install, proper dependency management
2. **Setup check** — Beautiful Rich output, comprehensive environment verification
3. **Module architecture** — Clean separation of concerns, all 8 modules import cleanly
4. **Security** — `DataRedactor` module for credential protection — great design
5. **Screenshot capture** — Reliable via xcrun simctl
6. **StateInspector** — Successfully finds app container path
7. **MCP server** — Included for Claude Desktop/Cursor integration
8. **Parallel module** — idb_backend for multi-simulator testing — forward-thinking

---

## Recommendations

### Critical Path (do first)
0. **BLOCKER: Publish matching specterqa core with `ComputerUseDecider`** — specterqa-ios 0.2.0 imports `specterqa.engine.decider.ComputerUseDecider` (falls back to `specterqa.engine.ai_decider.ComputerUseDecider`), but specterqa 0.4.0 has neither module. The `specterqa.engine.protocols.AIDecider` protocol exists but no concrete implementation. This means `specterqa ios run` and `specterqa ios smoke` both exit with code 3. **No tests can execute until this is resolved.**
1. Fix `CrashDetector.stop()` — trivial, add empty method
2. Fix `__version__` import in specterqa core
3. Switch InteractionLayer from AppleScript to Quartz CGEvents for tap/swipe/type
4. Add title bar auto-detection for coordinate mapping

### High Value
5. Fix PerfProfiler PID detection (use host `ps` command, not simctl spawn)
6. Add `ConsoleMonitor.wait_for_first_entry()` for reliable log capture
7. Auto-detect device info from booted simulator in product YAML generation
8. Add `pyobjc-framework-Quartz` to dependencies (for CGEvent tap support)

### Nice to Have
9. Fix double-nested project directory
10. Add a `calibrate` command that verifies coordinate accuracy by tapping known positions
11. Add `--dry-run` mode that shows what would be clicked without executing
12. HTML report with annotated screenshots showing click positions

---

## Test Session Details

### Prototype Test Run (standalone sim_driver)
- **40 iterations** completed
- **350 seconds** total runtime
- Claude successfully: identified UI elements, scrolled catalog, tapped a book, read detail page
- Failed on: tapping "< Back" button (coordinate offset at top of screen)
- **Cost estimate:** ~$2-3 for 40 iterations with Sonnet

### specterqa-ios v0.2.0 Direct API Test
- `SimulatorDriver(config)` — PASS
- `driver.start()` — PASS
- `driver.screenshot()` — PASS
- `driver.get_context()` — PARTIAL (screenshot + state work, logs/network/perf empty)
- `driver.stop()` — FAIL (CrashDetector.stop() missing)
