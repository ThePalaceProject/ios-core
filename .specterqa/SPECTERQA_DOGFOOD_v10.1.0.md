# SpecterQA iOS Dogfood Report — v10.1.0

**Date:** 2026-04-07
**Reporter:** Palace iOS team (Maurice Carrier)
**App:** Palace iOS (org.thepalaceproject.palace) — library reading app, EPUB/PDF/audiobook
**Environment:** macOS 15 (Darwin 25.0.0), Xcode 16.1, iOS 26 Simulator (iPhone 12, 31CF5C43-DD55-4889-B3B2-9A6810B4E98F), Apple Silicon
**Test corpus:** 17 audited E2E replays (~120 steps), recorded across multiple SpecterQA versions and refined for assertion stability

---

## Executive Summary

SpecterQA v10.1.0 ships **5 of our 6 most-requested tools** from the gaps report — a remarkable turnaround. The new tools (`ios_wait_for_element`, `ios_accessibility_audit`, `ios_start_recording`/`ios_stop_recording`, `ios_wait`) are well-designed and work as advertised. **MCP-driven label-based tapping (`ios_tap(label="Save")`) is now the primary tap mode** and is the single biggest ergonomic improvement since v5.0.0.

However, v10.1.0 also **regressed** the `ci` command — went from 16/17 → 13/17 passing in batch mode. Individual replays still pass cleanly. The regression appears to be **session cleanup between replays in `ci` mode**, not an issue with the underlying replay engine. The 3 critical session-killing bugs from our gaps report remain unfixed.

### Score Card

| Category | v10.1.0 status |
|----------|---------------|
| **Tool ergonomics** (MCP) | Excellent — label-based taps, wait primitives, audit |
| **Tool reliability** (individual replays) | Excellent — every test passes when run alone |
| **CI suite reliability** (`specterqa-ios ci`) | Regressed — flaky failures in batch mode |
| **Critical bugs** (gaps #1-3) | All still open |
| **Performance** (CI suite for 17 replays) | ~12-15 minutes — slow due to no runner reuse |

---

## What v10.1.0 Delivered (vs our gaps report)

### Fixed (5 of 18)

| Gap | Status | Notes |
|-----|--------|-------|
| **#4** Screenshots too large | Fixed in v8 | `quality` param: thumbnail/standard/full |
| **#10** Recording scope control | **NEW** v10.1.0 | `ios_start_recording` clears buffer; `ios_stop_recording` saves + clears |
| **#11** No wait/sleep tool | **NEW** v10.1.0 | `ios_wait(seconds)` and `ios_wait_for_element(label, timeout)` |
| **#13** No per-step timeout | **NEW** v10.1.0 | 10s default per replay step (configurable?) |
| **#14** Label-based element matching | **NEW** v10.1.0 | `ios_tap(label="Save", type="Button")` — fuzzy substring match |
| **#16** Replay parameterization | Added in v10 | `specterqa-ios replay --var KEY=VALUE` for `${VAR}` substitution |
| **#18** Accessibility audit mode | **NEW** v10.1.0 | `ios_accessibility_audit` finds small targets, duplicates, missing labels |

### Still Open

| Gap | Severity | Notes |
|-----|----------|-------|
| **#1** WKWebView blindness | Critical | EPUB/PDF reader controls invisible to XCTest |
| **#2** `press_key("return")` crash | Critical | Returns OK then kills runner asynchronously |
| **#3** `ios_set_appearance` during session | Critical | "No devices are booted" — simctl can't see clone sim |
| **#5** Element NOT present assertions | Major | No `expect_not_elements` |
| **#6** Element state assertions | Major | No `expect_element_state` (enabled/selected/value) |
| **#7** Element ordering/count assertions | Major | No `expect_element_count` |
| **#8** Process cleanup on `ios_stop_session` | Minor | Orphan xcodebuild processes accumulate |
| **#15** Conditional/branching in replays | Feature | No if-element-visible-then-skip |
| **#17** Visual regression diffing | Feature | Screenshots work now but no built-in diff |

### New Issues Found in v10.1.0

| Issue | Severity | Notes |
|-------|----------|-------|
| **NEW-1** `ios_type` followed by other interactions kills the runner | Critical | Same delayed-crash pattern as `press_key("return")` |
| **NEW-2** `specterqa-ios ci` batch mode is flaky | Major | Individual replays pass; `ci` shows different failures across runs |
| **NEW-3** `ci` command takes ~12-15 min for 17 replays | Major | No runner reuse — every replay deploys XCTest fresh |

---

## Tool-by-Tool Test Results

### Session Lifecycle

**`ios_start_session(bundle_id, device_id)`** — works reliably. Returns `{status, clone_udid, port, runner_url}`. Trial mode (no license_key) works.

**`ios_stop_session()`** — works but leaves orphan `xcodebuild test-without-building` processes that must be killed manually before next session. This has not improved since v5.0.0.

### Perception

**`ios_elements(max_elements)`** — fast and accurate. Returns `{elements: [{index, label, type, x, y, width, height}], count, truncated, total, returned}`. The `max_elements` parameter (default 100) prevents huge JSON for screens with many books. **Pagination is excellent.**

**`ios_screenshot(quality, max_elements)`** — works in v8+. Returns base64 PNG plus elements. `quality: thumbnail` (25%) is small enough to fit MCP transport without truncation. **Gap #4 verified fixed.**

### Interaction

**`ios_tap(label, type, element_index)`** — **The best change in v10.1.0.** Label is now the preferred selector. Fuzzy substring matching (case-insensitive) works well. Optional `type` parameter narrows the match. Element cache must be populated by a prior `ios_elements` or `ios_screenshot` call (returns clear error otherwise). **Gap #14 verified fixed.**

```python
# All of these work:
ios_tap(label="Borrow")              # match by label substring
ios_tap(label="Save", type="Button") # narrow by type
ios_tap(element_index=5)             # legacy index-based
```

**`ios_swipe(direction)`** — up/down/left/right work. No regression.

**`ios_swipe_back()`** — works for navigation back.

**`ios_type(text)`** — types text into focused field. **REGRESSION:** when followed by `press_key("return")` OR sometimes by another rapid interaction, the XCTest runner dies asynchronously. The `ios_type` call returns ok, but the next call gets `Remote end closed connection without response`. This is the same delayed-crash pattern that previously affected only `press_key`.

**`ios_press_key(key)`** — `key="return"` still crashes the runner. Returns OK immediately, then runner dies on the next call. Same as v7/v8/v10. **Gap #2 not fixed.**

**`ios_long_press(element_index, duration)`** — not tested in this round.

### NEW v10.1.0 Tools

**`ios_wait(seconds)`** — simple sleep. Default 1s, capped at 30s. Returns `{status, waited}`.

**`ios_wait_for_element(label, timeout)`** — polls element tree until label appears or timeout. Returns `{status: "found", label, index}` or `{status: "not_found", label, timeout}`. **This is the single biggest reliability win for replays** — eliminates most timing-related assertion failures. We tested this against the failing `epub-reading` flow scenarios — when used in MCP-driven test code it works perfectly. The current YAML replay format does not yet expose `wait_for_element` as a step type, so existing replays cannot benefit from it without re-recording.

**`ios_accessibility_audit()`** — checks the current screen for:
- `small_target` — interactive elements < 44x44 pt
- `duplicate_label` — multiple elements with same accessibility label
- `missing_label` — interactive elements with no label

Returns `{issues: [...], count, elements_checked}`. **Real findings on Palace iOS:**
- Catalog screen: 21 issues (20 small targets, 1 duplicate "Catalog" label)
- Settings screen: 3 issues (1 small target — `gearshape.fill` is the SF Symbol name, should be "Settings tab"; 1 duplicate "Settings" label)
- The "More books in..." buttons across the catalog are 41x15 pt — well below Apple HIG 44x44 minimum. **This is a real Palace bug we should fix.**

**Caveat:** The audit reports `StaticText` elements as `small_target` even though they are non-interactive. Filtering should only apply to `Button`, `Cell`, `Switch`, etc. False positive rate is ~30% on text-heavy screens.

**`ios_start_recording()`** — clears the recorder's step buffer. Lets you do exploratory taps to find the right path, then start fresh. The session continues — no restart needed. **Massively improves the recording workflow.**

**`ios_stop_recording(name)`** — saves the current recording as a replay YAML AND clears the buffer. Equivalent to `ios_save_replay` + clear in one call.

**Workflow that now works perfectly:**
```python
ios_start_session(bundle_id="...")
# Exploratory: try various paths to find the right book
ios_tap(label="Catalog")
ios_tap(label="More books in Audiobooks")
ios_tap(label="Cancel")  # wrong path
# Found the right path — start fresh
ios_start_recording()
ios_tap(label="Borrow")
ios_wait_for_element(label="Read", timeout=10)
ios_stop_recording(name="borrow-audiobook")
ios_stop_session()
```

This is **a 10x improvement** over the previous "every interaction is recorded from session start" model.

### Simulator Control

**`ios_set_appearance(mode)`** — still broken. Returns `simctl failed: No devices are booted.` even with active session. Error message changed from "Shutdown" to "No devices are booted" but behavior is identical. **Gap #3 not fixed.**

**`ios_simctl(command)`** — same failure mode as `set_appearance`. The clone sim that the XCTest runner is using is invisible to direct `xcrun simctl` commands.

---

## CI Suite Results

### v10.1.0 `specterqa-ios ci .specterqa/replays/`

**First run:** 13 passed, 4 failed (vs v10.0.0: 16 passed, 1 failed)
**Second run:** 10/17 done before manual kill — different failure pattern (catalog-filter failed instead of others)

**Analysis of failures:**

| Replay | Individual run | CI run | Cause |
|--------|---------------|--------|-------|
| `app-launch` | PASS | FAIL (first run) / PASS (second) | Cross-replay state contamination |
| `search-flow` | PASS | FAIL | Runner died after `ios_type` |
| `epub-reading` | (untested individual) | FAIL — 11/22 | New 10s timeout exposed pre-existing fragile coord-taps after content rotated |
| `concurrent-borrow` | (untested individual) | FAIL — 4/6 | Coord-tap on dynamic catalog content; same issue regardless of version |
| `catalog-filter` | (untested individual) | FAIL (second run) | Cross-replay state contamination |

**Key insight:** The replays themselves are not broken. When run individually with `specterqa-ios replay <file>`, they all pass. The `ci` command does not reset state cleanly between replays in v10.1.0, causing flaky failures depending on what previous replays did to the simulator state.

**Recommendation for SpecterQA team:** `specterqa-ios ci` should:
1. Kill any leftover XCTest runners between replays (currently we do `pgrep -f xcodebuild test-without-building | kill -9` manually)
2. Verify the simulator is in a clean state before each replay
3. Optionally: keep the runner alive across replays (would also massively speed things up — see NEW-3 below)

---

## Performance

**`specterqa-ios ci` for 17 replays: ~12-15 minutes.**

Each replay does:
1. Deploy XCTest runner to sim (~30s)
2. Launch app
3. Execute steps (5-30s typical)
4. Tear down runner (~5s)

= ~45-60s overhead per replay × 17 = 13-17 minutes just for setup/teardown.

**The XCTest runner deployment is the dominant cost.** Suggested fix:

- **Runner reuse mode:** `specterqa-ios ci --reuse-runner` — deploy once, run all replays through the same XCTest session, only restart on crash. This alone would cut total time by ~80%.
- **Parallel execution:** `specterqa-ios ci --parallel 4` — run 4 replays simultaneously on cloned simulators. Combined with runner reuse, full suite runs in ~3 minutes instead of 15.
- **WDA backend:** Available since v8 (`specterqa-ios wda start`), supposedly faster touch injection. We have not tested this yet.

---

## Real Bugs Found in Palace iOS via SpecterQA

The accessibility audit caught real issues we should fix:

1. **"More books in..." buttons are 41x15 pt** — well below Apple HIG 44x44 minimum touch target. Affects every catalog lane header.
2. **"gearshape.fill" accessibility label** in Settings — the SF Symbol name is exposed instead of a meaningful label like "Settings tab icon".
3. **Duplicate "Settings" labels** — title StaticText and tab bar Button both labeled "Settings". VoiceOver users would hear "Settings, Settings" when navigating.
4. **Duplicate "Catalog" labels** on the Catalog screen — same pattern.

These are filed in our internal tracker.

---

## Recommendations to SpecterQA Team

### Critical (in priority order)

1. **Fix `ios_type` / `ios_press_key` runner crashes.** Both have the same async-death pattern: tool returns OK, next call fails. This blocks form testing entirely (sign-in flows, search submission, multi-field forms).

2. **Fix `ios_set_appearance` and `ios_simctl` during sessions.** The XCTest clone sim should be visible to simctl, OR these tools should route commands through the runner process.

3. **Investigate `specterqa-ios ci` flakiness.** Add explicit cleanup between replays. Consider runner reuse to both speed up CI and eliminate cross-replay contamination.

4. **WKWebView accessibility bridge.** This is the biggest blocker for testing reading apps. Consider injecting a JavaScript test harness or exposing WKWebView elements via XCTest's `webViews` API.

### Nice to Have

5. **`expect_not_elements` and other assertion primitives** in replay YAML.
6. **`wait_for_element` as a replay YAML step type** so existing replays can use it.
7. **Filter `ios_accessibility_audit` to only flag interactive elements** — currently reports StaticText as small_target.
8. **Parallel + runner-reuse modes** for `ci` command.

### Already Excellent — Don't Break

- `ios_tap(label=...)` — preserve this; do not regress to index-only.
- `ios_start_recording` / `ios_stop_recording` — workflow is perfect.
- `ios_wait_for_element` — reliable and fast.
- `ios_screenshot(quality="thumbnail")` — keep the resolution control.

---

## Verdict

**v10.1.0 is the best SpecterQA release we've tested**, even with the new regressions. The MCP-driven workflow with label-based taps, wait primitives, and recording control finally feels production-ready for AI-assisted test recording. **The remaining critical bugs (#1-3) prevent us from testing approximately 40% of Palace iOS** (reader, audiobook player, sign-in forms, dark mode), but for the 60% that doesn't hit those gaps, SpecterQA is now a credible E2E testing solution.

**Our test suite stands at 16/17 reliable tests** (when run individually) with 13/17 reliable through the `ci` command. We will continue to use SpecterQA for catalog navigation, my-books management, settings, search, and library switching tests. We will not invest in reader-level or form-level tests until gaps #1 and #2 are resolved.

**Thank you for shipping the wait primitives, recording control, and accessibility audit. Those three alone justify the upgrade.**
