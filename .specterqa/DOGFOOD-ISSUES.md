# SpecterQA v12.5.1 Dogfood Issues

## Issue 1: XCTest Runner Crashes During Book Borrow Actions

**Severity:** High — blocks borrow/download/return flow testing  
**Version:** specterqa-ios 12.5.1  
**Date:** 2026-04-15  
**Device:** iPhone 12 Simulator (31CF5C43-DD55-4889-B3B2-9A6810B4E98F), iOS 26  
**App:** Palace iOS v3.0.0 (453)

### Reproduction Steps
1. `ios_start_session(bundle_id: "org.thepalaceproject.palace")`
2. Navigate to any book detail screen (tap a book cover in catalog)
3. `ios_tap(label: "Borrow")` — taps the Borrow button
4. `ios_wait_for_element(label: "Download", timeout: 15)` — waits for state change
5. **Result:** `Session crashed (runner unreachable)`

### Expected
Runner should survive the borrow action and detect the Download button appearing.

### Actual
Runner process dies during the borrow network call. The **app itself does NOT crash** — only the XCTest runner. The Palace app continues running fine and can be relaunched with a new session.

### Crash Report Analysis
```
Exception Type: EXC_BREAKPOINT (SIGTRAP)
Crashed Thread: XCTRunnerIDESession logDebugMessage:
Stack: ___CFBasicHashFindBucket_Linear → CFDictionaryGetValue → 
       _appendObject → __CFBinaryPlistWriteOrPresize → 
       -[NSKeyedArchiver finishEncoding] → -[NSKeyedArchiver encodedData] →
       -[XCTRunnerIDESession logDebugMessage:]
```

The crash is in CoreFoundation's dictionary serialization within the runner's debug logging system, NOT in app code. The borrow action triggers:
1. Network POST to CM
2. OPDS response parsing
3. `TPPBookRegistry` state change notifications (multiple)
4. UI updates (book cell model, download button, badge count)

This flood of concurrent UI/state changes appears to overwhelm the runner's observation logging.

### Crash Report Location
`~/Library/Logs/DiagnosticReports/Palace-2026-04-15-140614.ips`

### Workaround
- For borrow/download/return flows: test with the Mock Backend Service (avoids real network calls) or test post-hoc (borrow manually, then verify state via SpecterQA)
- Navigation, browsing, filtering, tab switching, settings — all work reliably

### Additional Context
- The runner also crashes when tapping "Switch Library" button (library picker presentation)
- The runner does NOT crash during scrolling, tab switching, or filter changes
- The runner survives the Settings screen, search activation, and catalog browsing
- This suggests the runner has difficulty with:
  - Modals/sheets being presented
  - Rapid concurrent notification-driven UI updates
  - Network-triggered state machine transitions

---

## Issue 2: ios_screenshot Returns Image Parsing Error

**Severity:** Medium — forces use of ios_elements instead  
**Reproduction:** Call `ios_screenshot(quality: "standard")` on any screen  
**Error:** `cannot identify image file <_io.BytesIO object>`  
**Workaround:** Use `ios_elements()` — returns the same element data without the image
