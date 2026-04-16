# SpecterQA v12.5.1 Dogfood Report

**Reporter:** Maurice Carrier (Palace iOS)  
**Period:** 2026-04-15 (full day session)  
**App:** Palace iOS v3.0.0 (453), branch `modernize/whole-shot`  
**Device:** iPhone 12 Simulator (31CF5C43-DD55-4889-B3B2-9A6810B4E98F), iOS 26  
**Host:** macOS 25.0.0, Xcode 16.1, Apple Silicon (Rosetta)  
**MCP Client:** Claude Code (Opus 4.6)  
**Previous version:** specterqa-ios 11.4.0 → 12.5.0 → 12.5.1

---

## What We Tested

Full regression hardening of a 871-file modernization refactor. The session covered:

- **40 replay files** — bulk-updated (Reservations→Holds rename), trimmed to structural assertions, 7 core replays verified green
- **6 distributor lanes** — ODL, Accessible EPUB, Audible, Palace Marketplace, Palace Bookshelf, OverDrive
- **Book detail screens** — ODL ebook detail, Audible audiobook detail, metadata rendering, related books
- **My Books** — 7 borrowed books across 2 distributors, download states, due dates, sort controls
- **Holds** — 2 active holds with position info, manage/preview actions
- **Tab navigation** — Catalog → My Books → Holds → Settings → Catalog (all transitions)
- **Filter switching** — All / Ebooks / Audiobooks segmented control
- **Dark/Light mode** — toggle both directions without crash
- **Performance profiling** — perf_baseline → actions → perf_compare across all flows
- **Accessibility audits** — Settings screen, Holds screen
- **Crash monitoring** — ios_crashes checked after every flow
- **Error logging** — ios_logs(level: "error") checked across full session

## What Works Well

### Reliable Tools
- `ios_elements()` — fast, accurate, consistent. This was our primary perception tool all session
- `ios_tap(label:)` — label-based tapping worked flawlessly for tab bar, filter buttons, book covers, settings items
- `ios_wait_for_element()` — correctly detected book detail screen loads (e.g., waiting for "Borrow" button)
- `ios_wait_idle()` — worked for navigation transitions
- `ios_perf_baseline()` / `ios_perf_compare()` — produced consistent, actionable metrics. Verdict system (OK / ISSUES_FOUND) is useful
- `ios_crashes()` — correctly distinguished app crashes from runner crashes. Reported 0 app crashes when the app was fine despite runner dying
- `ios_logs(level: "error")` — returned clean results, correctly showed 0 errors
- `ios_set_appearance()` — dark/light mode toggle worked mid-session
- `ios_accessibility_audit()` — found real issues (missing labels, small targets, duplicates)
- `ios_save_replay()` — saved replays with correct `expect_elements` assertions
- `ios_start_recording()` — clean buffer reset, multiple recordings per session

### Replay System
- `specterqa-ios replay` CLI works well for CI-style execution
- `--verbose` flag shows per-step pass/fail with missing element details
- Exit codes (0=pass, 1=fail, 2=stale) are correct and useful
- `expect_elements` assertions catch real regressions (we found the Reservations→Holds rename this way)

### v12.5.1 Improvements Over v11.4.0
- Session response now includes `device_type` and `target_udid` — helpful for multi-device testing
- `ios_tap` now returns `cache_refreshed: true` when element cache was updated — good for debugging
- Runner startup seems slightly faster

---

## Issue 1: XCTest Runner Crashes During Network-Triggered State Transitions

**Severity:** HIGH — blocks borrow, download, return, and library-switch flow testing  
**Impact:** Cannot test the most critical user journeys (acquire book, read book, return book)

### Reproduction Steps (Borrow)
```
1. ios_start_session(bundle_id: "org.thepalaceproject.palace")
2. ios_tap(label: "Diario de una cantante")   # any book in catalog
3. ios_wait_for_element(label: "Borrow", timeout: 10)  # book detail loads
4. ios_tap(element_index: 4)                   # tap Borrow button
5. ios_wait_for_element(label: "Download", timeout: 15)
   → ERROR: "Session crashed (runner unreachable)"
```

### Reproduction Steps (Download)
```
1. ios_start_session(...)
2. ios_tap(label: "My Books")                  # navigate to My Books
3. ios_tap(label: "Animal Farm")               # tap borrowed audiobook
4. ios_tap(label: "Download")                  # start download
5. ios_wait(seconds: 5)                        # survives initial tap
6. ios_wait_for_element(label: "Listen", timeout: 30)
   → ERROR: "Session crashed (runner unreachable)"
```

### Reproduction Steps (Library Switch)
```
1. ios_start_session(...)
2. ios_tap(label: "Switch Library")
   → ERROR: "Session crashed (runner unreachable)"
```

### What Happens
- The **XCTest runner process dies** — not the app
- The app continues running perfectly in the simulator
- `ios_crashes()` correctly reports 0 app crashes
- A new `ios_start_session()` reconnects to the still-running app

### Crash Report
```
Location: ~/Library/Logs/DiagnosticReports/Palace-2026-04-15-140614.ips

Exception Type:  EXC_BREAKPOINT (SIGTRAP)
Signal:          SIGTRAP

Crashed Thread Stack:
  ___CFBasicHashFindBucket_Linear      (CoreFoundation)
  CFDictionaryGetValue                 (CoreFoundation)
  _appendObject                        (CoreFoundation)
  __CFBinaryPlistWriteOrPresize        (CoreFoundation)
  -[NSKeyedArchiver finishEncoding]    (Foundation)
  -[NSKeyedArchiver encodedData]       (Foundation)
  -[XCTRunnerIDESession logDebugMessage:]  (XCTest)
  __45-[XCTDefaultDebugLogHandler logDebugMessage:]_block_invoke  (XCTest)
  -[XCTDefaultDebugLogHandler _locked_flushDebugMessageBufferWithBlock:]  (XCTest)
```

### Root Cause Analysis
The crash is in the XCTest runner's **debug logging system**, not in app code. The runner uses `NSKeyedArchiver` to serialize debug messages, and a `CFDictionaryGetValue` call hits a bad pointer during serialization.

The trigger appears to be **rapid concurrent UI/state changes** that flood the runner's observation system:
- Borrow action → network POST → OPDS response → `TPPBookRegistry` state change → multiple `NotificationCenter` posts → UI updates (book cell, download button, badge count, tab badge)
- Download action → download progress callbacks → book state transitions → UI updates
- Library switch → modal presentation → account change → catalog reload → notification cascade

### What Does NOT Crash the Runner
- Tab switching (Catalog → My Books → Holds → Settings)
- Scrolling (swipe up/down in catalog and book lists)
- Filter switching (All / Ebooks / Audiobooks)
- Settings navigation
- Search activation
- Dark/light mode toggle
- Book detail view (tapping a book cover to see detail)
- Pull-to-refresh

### Pattern
The runner survives **read-only UI operations** but dies during **state-mutating operations** that trigger notification cascades. The more concurrent notifications an action produces, the more likely the crash.

### Workaround Used
- Tested borrow/download flows post-hoc (manually trigger action, reconnect with new session, verify state)
- Used API-level unit tests for bookmark/annotation sync instead of UI-level tests
- Verified book detail screens without tapping action buttons

### Suggested Fix Direction
The crash is in `[XCTRunnerIDESession logDebugMessage:]` → `NSKeyedArchiver`. Possible approaches:
- Rate-limit or debounce the runner's debug message logging during rapid UI updates
- Use a thread-safe serialization approach instead of `NSKeyedArchiver` for debug messages
- Add a `CFDictionaryGetValue` nil check before serialization

---

## Issue 2: ios_screenshot Returns Image Parsing Error

**Severity:** MEDIUM — blocks visual verification, forces use of ios_elements  
**Impact:** Cannot capture annotated screenshots for visual regression testing

### Reproduction
```
ios_screenshot(quality: "standard")
→ {"error": "cannot identify image file <_io.BytesIO object>"}

ios_screenshot(quality: "full")
→ same error

ios_screenshot(quality: "thumbnail")
→ same error
```

### Context
- Happens on every screen, every session
- Started with v12.5.0 (was working in v11.4.0 — needs verification)
- The runner IS capturing screenshots (the XCTest call succeeds) but the Python-side image decoding fails
- Likely a Pillow/PIL version issue or a change in the screenshot format between iOS versions

### Workaround
`ios_elements()` returns the same structured element data (labels, types, positions, sizes) without the image. This is sufficient for functional testing but blocks visual regression / screenshot comparison workflows.

### Environment
```
Python: 3.13
Pillow: 12.2.0
iOS Simulator: iOS 26 (beta SDK)
```

The iOS 26 simulator may be returning screenshots in a format that Pillow 12.2.0 doesn't handle (e.g., Display P3 color space, HDR, or a new PNG variant).

---

## Issue 3: Replay Runner Health Timeout Between Sequential Replays

**Severity:** LOW — affects batch replay execution, not individual replays  
**Impact:** Sequential replay runs fail intermittently when the previous runner isn't fully cleaned up

### Reproduction
```bash
# Run 10 replays sequentially
for replay in smoke-test tab-navigation settings-screen ...; do
  specterqa-ios replay .specterqa/replays/${replay}.yaml --verbose
done

# Result: ~30% of replays fail with:
# "ERROR — Runner at http://localhost:8222/health did not become healthy 
#  within 60s. Last error: <urlopen error [Errno 61] Connection refused>"
```

### Root Cause
The replay CLI's runner cleanup between executions doesn't fully wait for the previous XCTest runner process to release port 8222. The next replay starts, tries to launch a new runner, but the port is still held.

### Workaround
```bash
# Kill stale runners between replays
pgrep -f "xcodebuild test-without-building" | xargs -r kill -9
sleep 2  # wait for port release
specterqa-ios replay next-test.yaml
```

### Suggested Fix
- Add a port-availability check before launching the runner
- Or: reuse the runner across sequential replays (don't restart per replay)
- Or: add a `--cleanup-delay` flag to the CLI

---

## Feature Requests

### 1. Multi-Session / Multi-Device Support
**Use case:** Cross-device bookmark sync testing  
**Current limitation:** Only one `ios_start_session` can be active at a time  
**Request:** Allow connecting to multiple simulators simultaneously, or support session switching without killing the runner:
```python
session_a = ios_start_session(bundle_id: "...", device_id: "sim-A")
session_b = ios_start_session(bundle_id: "...", device_id: "sim-B")
# Interact with session_a
ios_tap(session: session_a, label: "Bookmark")
# Switch to session_b and verify
ios_wait_for_element(session: session_b, label: "Bookmark", timeout: 10)
```

### 2. Notification Flood Resilience
**Use case:** Testing state-mutating operations (borrow, download, sign-in)  
**Request:** The runner should handle rapid `NotificationCenter` posts without crashing. This is the #1 blocker for testing critical paths.

### 3. Structural Assertion Mode for Replays
**Use case:** Durable replays that survive content rotation  
**Current behavior:** `ios_save_replay` captures ALL visible elements as `expect_elements`  
**Request:** Add an option to capture only structural elements (nav bar, tab bar, controls) and exclude dynamic content (book titles, author names):
```python
ios_save_replay(name: "smoke-test", assertion_mode: "structural")
# Only asserts on elements with accessibilityIdentifier or known control types
```

### 4. Replay Suite Runner
**Use case:** Running 40 replays in CI  
**Request:** A `specterqa-ios replay-suite` command that handles runner lifecycle between replays:
```bash
specterqa-ios replay-suite .specterqa/replays/ --parallel 1 --cleanup-delay 2
```

---

## Test Coverage Achieved This Session

| Area | Method | Result |
|------|--------|--------|
| Catalog structure (6 lanes) | SpecterQA | ✅ All lanes render |
| Tab navigation (4 tabs) | SpecterQA + Replay | ✅ 7/7 replays pass |
| Book detail (ODL + Audible) | SpecterQA | ✅ Full metadata shown |
| My Books (7 books, 2 distributors) | SpecterQA | ✅ States correct |
| Holds (2 holds) | SpecterQA | ✅ No error banner |
| Filter switching | SpecterQA + Replay | ✅ All/Ebooks/Audiobooks |
| Dark/Light mode | SpecterQA | ✅ No crash |
| Settings screen | SpecterQA + Replay | ✅ All items render |
| Performance (RSS/threads) | SpecterQA perf | ✅ OK verdict, stable |
| Accessibility | SpecterQA audit | ⚠️ 6 minor issues (pre-existing) |
| Cross-device bookmark sync | Unit tests (12) | ✅ All pass |
| Borrow flow | ❌ BLOCKED | Runner crash |
| Download flow | ❌ BLOCKED | Runner crash |
| Audiobook playback | ❌ BLOCKED | Runner crash on download |
| EPUB reader | ❌ BLOCKED | WKWebView invisible to XCTest |
| Library switching | ❌ BLOCKED | Runner crash on modal |

**Bottom line:** SpecterQA is excellent for navigation, browsing, and structural verification. The runner crash on state-mutating operations is the critical gap blocking full flow testing.
