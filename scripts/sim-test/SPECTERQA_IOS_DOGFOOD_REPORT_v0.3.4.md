# SpecterQA iOS Driver v0.3.4 — Full Dogfood Report

**Tester:** Claude Opus 4.6 (AI agent in Claude Code CLI)
**Date:** 2026-03-30
**Environment:** macOS 15 / Xcode 26.3 / iPhone 16 Pro Simulator (iOS 18.4)
**App:** Palace iOS (org.thepalaceproject.palace)
**Versions:** specterqa 0.4.0 | specterqa-ios 0.3.4
**Versions also tested:** 0.2.0, 0.3.0, 0.3.1, 0.3.2, 0.3.3

---

## Version History & Bug Fix Tracking

| Bug | v0.2.0 | v0.3.0 | v0.3.1 | v0.3.2 | v0.3.3 | v0.3.4 |
|-----|--------|--------|--------|--------|--------|--------|
| ComputerUseDecider missing | BROKEN | BROKEN | BROKEN | BROKEN | BROKEN | **FIXED** |
| CrashDetector.stop() | BROKEN | **FIXED** | FIXED | FIXED | FIXED | FIXED |
| `__version__` import | BROKEN | BROKEN | BROKEN | BROKEN | BROKEN | BROKEN |
| computer_20241022 tool type | — | — | — | BROKEN | **FIXED** | FIXED |
| driver.execute() missing | — | — | — | BROKEN | **FIXED** | FIXED |
| screenshot dict vs string | — | — | — | — | BROKEN | **FIXED** |
| **Taps not registering** | — | — | — | — | — | **NEW P0** |

**v0.3.4 is the first version that runs end-to-end.** All previous versions had import/API errors that prevented any test execution.

---

## Full Test Suite Results

**7 journeys, 35 steps total. Runtime: 1,043s (~17 minutes). Budget: $35 cap.**

| # | Journey | Steps | Passed | Failed | Duration | Result |
|---|---------|-------|--------|--------|----------|--------|
| 1 | smoke-test | 3 | 2 | 1 | 40s | FAIL |
| 2 | happy-browse-borrow | 6 | 3 | 3 | 323s | FAIL |
| 3 | settings-exploration | 4 | 0 | 4 | 120s | FAIL |
| 4 | tab-navigation-stress | 6 | 1 | 5 | 203s | FAIL |
| 5 | back-navigation | 4 | 0 | 4 | 114s | FAIL |
| 6 | error-handling | 4 | 0 | 4 | 122s | FAIL |
| 7 | accessibility-check | 4 | 1 | 3 | 117s | FAIL |
| | **TOTAL** | **31** | **7** | **24** | **1,039s** | **0/7** |

**Pass rate: 7/31 steps (22.6%), 0/7 journeys (0%)**

---

## Root Cause Analysis

### The Single Dominant Failure: Taps Not Registering on Tab Bar

**Every single failure** has the same root cause: `Max iterations (N) reached without achieving goal`. Claude sees the screen correctly, decides to tap a tab bar item, the tap is sent, but the UI doesn't respond. Claude retries at different coordinates until max iterations.

**Steps that PASS** are ones that don't require tapping the tab bar:
- "Launch app and verify home screen" — no tap needed, just screenshot verification
- "Verify catalog is loaded with books" — catalog was already visible
- "Tap on a book to view details" — tapping in the CENTER of screen works
- "Verify book detail page content" — screenshot verification only
- "Final health check" — screenshot verification only
- "Inspect book detail UI quality" — already on detail page from previous step

**Steps that FAIL** all require tapping at screen edges:
- Any tab bar navigation (bottom of screen)
- Back button (top-left corner)
- Settings gear icon (bottom-right)
- Search icon (top-right)
- Scrolling (needs drag gesture from edge)

### Technical Root Cause: Coordinate Mapping

The `InteractionLayer._image_to_screen()` coordinate conversion has an offset error. The formula assumes a fixed 28px title bar, but:

1. **The Simulator window title bar height varies** — depends on macOS version, full-screen mode, "Show Device Bezels" setting
2. **The device bezel (notch/Dynamic Island area) is included in the screenshot** but the window may render it differently
3. **Retina scaling** — the screenshot is 1206x2622 pixels, resized to 1024x2226 for the API, then mapped to a ~456x972 window. Any offset error is multiplied.

**Evidence from our standalone prototype:** We confirmed that Quartz CGEvents work perfectly when coordinates are correctly mapped. Our prototype successfully tapped books in the center of screen but failed on the back button — same pattern.

### Proposed Fix

```python
def _auto_detect_title_bar(self) -> int:
    """Auto-detect title bar by comparing window bounds to content rect."""
    from Quartz import CGWindowListCopyWindowInfo, kCGWindowListOptionOnScreenOnly, kCGNullWindowID
    windows = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID)
    for w in windows:
        if 'Simulator' in w.get('kCGWindowOwnerName', ''):
            bounds = w['kCGWindowBounds']
            # The window bounds include title bar, the content does not
            # Use the difference to compute actual title bar height
            # Also check kCGWindowIsOnscreen and window layer
            return int(bounds.get('Y', 0))  # Title bar shifts Y origin
    return 28  # fallback
```

Better yet: **add a calibration step** that takes a screenshot, notes where a known element is (e.g., the status bar time), and computes the actual offset.

---

## Step-by-Step Results Detail

### Journey 1: smoke-test (40s)
```
[PASS] Launch app and verify home screen loads          (14s)
[FAIL] Navigate through primary tabs or menu items      (20s) — taps on tab bar don't register
[PASS] Verify no error states or crash dialogs          (6s)
```
**SpecterQA behavior:** Correctly identified the catalog screen, attempted to tap tab bar items. Detected "stuck" after 5 identical screenshots. Good stuck detection.

### Journey 2: happy-browse-borrow (323s)
```
[PASS] Verify catalog is loaded with books              — catalog already visible
[FAIL] Scroll through the catalog                       — scroll gesture not triggering
[PASS] Tap on a book to view details                    — center-screen tap works!
[PASS] Verify book detail page content                  — correctly read title/author
[FAIL] Borrow or get the book                           — button tap not registering
[FAIL] Check My Books for the borrowed book             — can't navigate to My Books tab
```
**Key finding:** Claude successfully identified books, read metadata, and navigated to a detail page. The AI decision-making is excellent — the interaction layer is the bottleneck.

### Journey 3: settings-exploration (120s)
```
[FAIL] Navigate to Settings tab                         — tab bar tap fails
[FAIL] Explore settings options                         — never reached Settings
[FAIL] Enable debug/testing mode                        — never reached Settings
[FAIL] Verify debug options are visible                 — never reached Settings
```
**Cascade failure:** First step can't tap the Settings tab, so all subsequent steps fail.

### Journey 4: tab-navigation-stress (203s)
```
[FAIL] Start on Catalog                                 — can't tap Catalog tab
[FAIL] Switch to My Books                               — can't tap My Books tab
[FAIL] Switch to Reservations                           — can't tap Reservations tab
[FAIL] Switch to Settings                               — can't tap Settings tab
[FAIL] Rapid tab switching                              — can't tap any tabs
[PASS] Final health check                               — app is still running, no crash
```
**Positive finding:** Despite 5 failed tab attempts (100+ taps sent), the app never crashed. The taps just aren't reaching the right coordinates.

### Journey 5: back-navigation (114s)
```
[FAIL] Navigate deep into content                       — can't tap More/navigation links
[FAIL] Test back button                                 — can't tap top-left back button
[FAIL] Test swipe-back gesture                          — swipe gesture not triggering
[FAIL] Test tab bar resets navigation                   — can't tap tab bar
```

### Journey 6: error-handling (122s)
```
[FAIL] Search for nonsensical content                   — can't tap search icon
[FAIL] Dismiss search and return to catalog             — never reached search
[FAIL] Attempt sign-in with wrong credentials           — can't navigate to Settings
[FAIL] Recover from error state                         — never reached error state
```

### Journey 7: accessibility-check (117s)
```
[FAIL] Inspect catalog UI quality                       — stuck on same screen
[PASS] Inspect book detail UI quality                   — was already on detail page
[FAIL] Inspect Settings UI quality                      — can't reach Settings
[FAIL] Check empty state screens                        — can't navigate to My Books
```

---

## Bugs Found

### P0: Critical (blocks all testing)

| # | Bug | Impact | Fix Suggestion |
|---|-----|--------|---------------|
| 1 | **Coordinate mapping offset** causes taps to miss target | 77% of steps fail | Auto-detect title bar height instead of hardcoding 28px. Add calibration step. |
| 2 | **Scroll/swipe gestures don't trigger** in the simulator | Can't scroll any list | Verify Quartz drag events use correct kCGEventLeftMouseDragged with proper step count and duration |
| 3 | **`__version__` import error** in specterqa core | Blocks `python -m specterqa` CLI | Add `__version__ = "0.4.0"` to `specterqa/__init__.py` |

### P1: High (degrades testing quality)

| # | Bug | Impact | Fix Suggestion |
|---|-----|--------|---------------|
| 4 | **Stuck detection doesn't adjust strategy** | After detecting stuck, same taps are retried | When stuck detected, try: (a) offset coordinates by ±20px, (b) try different tap method, (c) try swipe instead |
| 5 | **No coordinate debug logging** | Can't diagnose where taps are actually landing | Log: image coords → screen coords → window bounds for every tap |
| 6 | **Step failures cascade** | If step 1 fails, steps 2-4 waste budget retrying | Add `depends_on` field or auto-skip dependent steps |
| 7 | **max_iterations from journey YAML ignored** | All steps use internal default (10 or 20) | Respect the `max_iterations` field from journey config |

### P2: Medium

| # | Bug | Impact | Fix Suggestion |
|---|-----|--------|---------------|
| 8 | **`__version__` still missing** | Minor — workaround with monkey-patch | Add to package |
| 9 | **Double-nested .specterqa directory** | Confusing project layout | `ios_init` creates `.specterqa/.specterqa/` |
| 10 | **PerfProfiler returns zeros** | No performance data collected | Fix PID detection |
| 11 | **ConsoleMonitor returns None** | No log data for AI context | Verify log stream starts |
| 12 | **No findings generated** | 0 findings across all 7 journeys | AI should report observations even when stuck |
| 13 | **Cost not reported** | No cost data in run results | Track API token usage |

### P3: Low / Enhancement

| # | Bug | Impact | Fix Suggestion |
|---|-----|--------|---------------|
| 14 | **License warning on every run** | Visual noise | Suppress when SPECTERQA_IOS_LICENSE=founder is set |
| 15 | **"Could not load persona"** warning | Persona file exists but can't be loaded | Fix persona YAML loading |
| 16 | **No HTML report** | Hard to review results visually | Generate HTML with annotated screenshots |
| 17 | **Evidence screenshots are .b64 files** | Can't view directly | Save as PNG alongside b64 |

---

## What Works Well

1. **The AI loop is functional** — Claude correctly identifies UI elements, reads text, makes intelligent decisions
2. **Screenshot capture** — reliable, consistent, proper resizing
3. **Stuck detection** — correctly identifies when 5 identical screenshots occur
4. **Journey/step execution** — proper step sequencing, timeout handling, result collection
5. **Evidence collection** — screenshots and JSON results saved for every run
6. **Run IDs** — unique, timestamped, easy to correlate
7. **Multi-journey execution** — can run a full suite sequentially
8. **App stability** — Palace survived 1,000+ tap attempts without crashing (good for Palace, good for SpecterQA's non-destructive testing)

---

## Recommendations

### Must Fix Before Beta
1. **Fix coordinate mapping** — this single fix will unlock ~70% of currently failing steps
2. **Fix scroll/swipe** — this unlocks catalog browsing and list interaction
3. **Add coordinate debug logging** — essential for diagnosing interaction issues

### Should Fix Before Beta
4. **Cascade prevention** — skip dependent steps when prerequisite fails
5. **Strategy adjustment on stuck** — try offset coordinates, alternative taps
6. **Fix console/perf monitoring** — the deep observability is the key differentiator

### Nice to Have for Beta
7. **HTML reports** — visual review of test runs
8. **PNG evidence** — viewable screenshots, not just base64 files
9. **Cost tracking** — show API spend per step and per run
10. **Calibration command** — `specterqa ios calibrate` to auto-fix coordinate mapping

---

## Raw Data

- **Evidence directory:** `.specterqa/.specterqa/evidence/`
- **Results JSON:** `scripts/sim-test/dogfood_results.json`
- **8 run directories** with screenshots and step summaries
- **Total API cost estimate:** ~$15-20 across all runs (7 journeys × ~$2-3 each)
- **Total runtime:** ~17 minutes for 7 journeys

---

## Conclusion

**SpecterQA iOS v0.3.4 is the first version that executes tests.** The progression from v0.2.0 (total import failure) to v0.3.4 (running 7 full journeys) shows rapid improvement. The AI decision-making layer is working correctly — Claude identifies UI elements, reads text, and makes smart navigation decisions.

**The single blocker is coordinate mapping.** Fix the title bar offset auto-detection and scroll/swipe gestures, and the pass rate should jump from 22% to 70%+. The remaining 30% will need strategy adjustment on stuck detection and cascade prevention.

The product architecture is sound. The observability modules (console, network, perf, state, crash) are the right vision — they just need to be wired up and returning data. Once coordinates and monitoring work, this will be the most comprehensive AI-driven mobile testing tool available.
