# SpecterQA iOS -- Gaps & Issues Report

## Version: 7.0.0 → 8.0.0 | App: Palace iOS | Date: 2026-04-06

**Reporter:** Palace iOS team (Maurice Carrier)
**Environment:** macOS 15 (Darwin 25.0.0), Xcode 16.1, iOS 26 Simulator (iPhone 12), Apple Silicon (M-series)
**Scope:** 13 audited E2E replays (120+ steps) against Palace iOS reading app (EPUB, PDF, audiobooks, OPDS catalogs, multi-library auth)

### v8.0.0 Retest Results (2026-04-06)

| Issue | v8 Status | Notes |
|-------|-----------|-------|
| #1 WKWebView blindness | **Still open** | Not addressed |
| #2 press_key("return") crash | **Still broken** | Returns "ok" but kills session silently — delayed crash |
| #3 ios_set_appearance during session | **Still broken** | Same "Shutdown" error via simctl |
| #4 Screenshots too large | **FIXED** | New `quality` param: `thumbnail` (25%), `standard` (50%), `full` |
| #5-7 Assertion/wait/indices | **Still open** | No changes |
| New: WDA backend | **Added** | `specterqa-ios wda` — WebDriverAgent for headless CI |

---

### Critical (Blocks Test Coverage)

**1. WKWebView content invisible to XCTest accessibility tree**

EPUB readers (Readium 3.x), PDF viewers, and any WKWebView-based UI render outside the XCTest accessibility tree. `ios_elements()` cannot discover reader navigation controls (back button, settings gear, table of contents), typography/font controls, or bookmark management UI. Page body text is partially visible but navigation chrome is not.

This blocks test coverage for:
- EPUB reading and page navigation verification
- PDF reading
- Reader typography and display settings
- Bookmark creation and management
- Any audiobook UI rendered in a web view

`ios_swipe_back` does not exit the reader either -- it is interpreted as a page-turn gesture. The only escape path (tap center to toggle nav bar, then tap back) fails because the toggled nav bar buttons never appear in `ios_elements()`.

**Suggestion:** Consider injecting a JavaScript bridge into the WKWebView during test sessions, or use XCTest's `app.webViews.element` query API which can access web content elements. Alternatively, expose a test-only accessibility overlay that mirrors the web view controls as native accessible elements.

---

**2. `ios_press_key(key="return")` crashes XCTest runner**

On iOS 26, calling `ios_press_key(key="return")` after `ios_type()` causes a SIGABRT in the XCTest runner process, killing the entire session. The crash occurs in the key event synthesis layer.

**Workaround:** Do not press return. Search fields auto-submit after typing, so return is unnecessary for search. But this workaround does not cover:
- Sign-in forms (barcode + PIN fields that require return or explicit submit)
- Any multi-field form where tab/return advances focus
- Alert dialogs with text input

**Suggestion:** Fix the key event synthesis for iOS 26, or provide an `ios_submit_form()` tool that triggers the form's default action without synthesizing a key press.

---

**3. `ios_set_appearance` and `ios_simctl` fail during active sessions**

Both tools report the simulator as "Shutdown" even when it is actively booted and running the app. The XCTest runner process takes exclusive control of the simulator, blocking other simctl commands.

**Workaround:** Set appearance via bash (`xcrun simctl ui <UDID> appearance dark`) BEFORE calling `ios_start_session`. But this means dark mode toggle testing requires: stop session, run bash command, restart session -- which resets the app to its launch state and loses all navigation context.

**Suggestion:** Route simctl commands through the XCTest runner process itself (which already has a connection to the simulator) instead of spawning a separate simctl process.

---

### Major (Degrades Test Quality)

**4. `ios_screenshot` exceeds MCP transport size limit**

Screenshots are too large for the MCP message transport. The tool either fails or returns truncated data. `ios_elements()` is the only way to observe UI state, which means:
- No visual regression testing
- No color or theme verification (dark mode appearance cannot be confirmed)
- No layout verification (element overlap, alignment, spacing)
- No image or icon correctness checks
- No verification of loading states, spinners, or progress indicators that lack accessibility labels

**Suggestion:** Compress screenshots (JPEG at reduced quality), offer a `resolution` or `scale` parameter (e.g., 0.25x), or implement chunked base64 streaming. Even a 320px-wide thumbnail would be valuable.

---

**5. No assertion primitives beyond element label presence**

`expect_elements` in replay YAML only checks whether element labels exist on screen. There is no way to assert:
- Element is NOT present (verify a dialog was dismissed, a book was returned)
- Element state (enabled vs. disabled, selected vs. unselected, toggled on/off)
- Element value (text field contains specific text, progress shows "50%")
- Element count (exactly 3 books in My Books, exactly 5 items in a list)
- Element position or ordering (element A appears above element B)

This severely limits what replays can verify. Most of our 29 replays had to strip assertions down to trivial checks to achieve a passing rate.

**Suggestion:** Add assertion tools: `expect_not_elements` (absence), `expect_element_state` (enabled/disabled/selected), `expect_element_value` (text content), `expect_element_count` (cardinality), `expect_element_order` (relative position).

---

**6. No wait/retry mechanism in replay execution**

Replay steps execute immediately with no implicit wait for UI to settle. Navigation transitions, network responses, and animations cause assertion failures on valid UI that simply has not finished rendering.

In practice, this means:
- Tapping a catalog lane and immediately checking for books fails because the next screen has not loaded
- Borrowing a book and checking for "Read" button fails because the download has not completed
- Any network-dependent screen is unreliable in replays

We had to strip most mid-flow assertions to achieve reliable replay passes.

**Suggestion:** Add configurable wait-for-element with timeout (e.g., `wait_for: {label: "Read", timeout: 10}`), or implement implicit retry-with-backoff before evaluating assertions. A global `settle_timeout` in the replay header would also help.

---

**7. Element indices are ephemeral and fragile across runs**

Replays record actions using `element_index`, which is the position in the flat accessibility element list. This index changes between runs if ANY element is added, removed, or reordered -- which happens frequently due to:
- Dynamic catalog content (different books appear on each load)
- Network timing (elements load in different order)
- App state changes (signed in vs. signed out)

The replay tool falls back to x/y coordinate taps, which are equally fragile across device sizes and orientations.

**Suggestion:** Support element matching by label + type as the primary selector (e.g., `tap: {label: "Borrow", type: "button"}`), with element index as a fallback. This would make replays resilient to layout changes while remaining precise.

---

### Minor (Friction / Developer Experience)

**8. `ios_stop_session` leaves orphan xcodebuild processes**

Stopping a session sends SIGTERM to the xcodebuild process but does not wait for or clean up child processes. The orphan `xcodebuild test-without-building` process holds the testing port and blocks subsequent sessions.

**Workaround:** Run `pgrep -f "xcodebuild test-without-building" | xargs -r kill -9` before every new session.

**Suggestion:** Track the xcodebuild PID and its children, send SIGKILL if SIGTERM does not terminate within 5 seconds, and verify the process is gone before returning from `ios_stop_session`.

---

**9. Stale xcodebuild processes accumulate across sessions**

Each session that is not cleanly stopped leaves an orphan xcodebuild process. After 5-10 sessions of iterative testing, the machine has many zombie processes consuming CPU, memory, and simulator connections.

**Suggestion:** Implement a process registry that tracks all spawned processes per session. On `ios_start_session`, check for and kill any stale processes from previous sessions. Alternatively, use a PID file in a temp directory.

---

**10. `ios_save_replay` captures ALL actions from session start**

There is no way to save a subset of actions or mark a "start recording here" point. Every tap, swipe, and type since `ios_start_session` is included. For clean per-journey replays, you must start a completely new session for each test flow, which means:
- Re-launching the app for each journey
- Re-navigating to the starting point
- Longer recording sessions

**Suggestion:** Add `ios_start_recording()` and `ios_stop_recording()` marker tools, or allow specifying a step range in `ios_save_replay` (e.g., `from_step: 15, to_step: 30`).

---

**11. No explicit wait or sleep tool**

Sometimes the UI needs time to load (network fetch, animation, download progress). There is no `ios_wait` or `ios_sleep` tool. The only workaround is polling `ios_elements()` in a loop, which wastes MCP round-trips and clutters the recorded action list.

**Suggestion:** Add `ios_wait(seconds: float)` for simple delays and `ios_wait_for_element(label: string, type: string, timeout: float)` for condition-based waiting.

---

**12. `specterqa-ios ci` exit code does not distinguish failure modes**

The CLI returns exit code 1 for both "one flaky test failed" and "the entire runner crashed." This makes CI/CD pipelines unable to differentiate between actionable failures and infrastructure issues.

**Suggestion:** Use structured exit codes: 0 = all pass, 1 = one or more test failures, 2 = runner crash or infrastructure error. Also provide a JSON summary file (e.g., `results.json`) with per-replay pass/fail/error status and timing.

---

**13. No per-step timeout in replays**

If a replay step targets an element that does not exist (e.g., index out of range, or the screen changed unexpectedly), the step either hangs indefinitely or fails with an opaque error. There is no configurable timeout per step.

**Suggestion:** Add a configurable `step_timeout` (default 10s) in the replay header, with per-step override capability. On timeout, report which step failed, what elements were visible, and what was expected.

---

### Feature Requests

**14. Element matching by accessibility label + type**

Instead of fragile index-based taps, allow `ios_tap(label="Borrow", type="button")`. This would:
- Make replays stable across app updates that change element ordering
- Eliminate the need to re-record replays when new UI elements are added
- Make replay YAML files human-readable and reviewable in PRs

This is the single highest-impact improvement for replay reliability.

---

**15. Conditional branching in replays**

Allow "if element X is visible, tap it; otherwise skip to step N." This handles variable app states:
- Book already borrowed vs. available (show "Read" vs. "Borrow")
- Already signed in vs. signed out
- Alert/modal present vs. not
- Different catalog content between runs

---

**16. Replay parameterization with variables**

Allow variables in replay YAML (e.g., `${BOOK_TITLE}`, `${LIBRARY_NAME}`, `${BARCODE}`) so one replay template can test different content or credentials. Variables could be supplied via CLI flags or an environment file.

---

**17. Built-in visual regression diffing**

Capture baseline screenshots during initial recording. During replay, capture new screenshots at the same points and diff against baselines. Flag pixel differences above a configurable threshold. This would enable visual regression detection without external tooling -- especially valuable given that `ios_screenshot` currently does not work over MCP.

---

**18. Accessibility audit mode**

Since `ios_elements()` already returns accessibility properties (labels, types, traits, frames), add a mode that performs automated accessibility checks:
- Missing accessibility labels on interactive elements
- Insufficient touch target sizes (below 44x44 pt)
- Duplicate accessibility labels on the same screen
- Missing accessibility traits (e.g., button without `.button` trait)
- Heading hierarchy violations

This would add significant value with minimal additional infrastructure, turning every E2E replay into a free accessibility audit.

---

### Summary

| Severity | Count | Key Theme |
|----------|-------|-----------|
| Critical | 3 | WKWebView blindness, key press crash, simctl lockout |
| Major | 4 | No screenshots, weak assertions, no waits, fragile selectors |
| Minor | 6 | Process cleanup, recording control, CI exit codes |
| Feature Request | 5 | Label-based taps, conditionals, variables, visual diff, a11y audit |

The three critical issues collectively block approximately 40% of Palace iOS test coverage (all reader-related flows, form submission, and dark mode testing). The major issues degrade the remaining 60% by forcing us to use minimal assertions and accept flaky replay results.

The most impactful single fix would be **label-based element matching** (issue 14), which would transform replays from fragile index recordings into stable, human-readable test scripts.
