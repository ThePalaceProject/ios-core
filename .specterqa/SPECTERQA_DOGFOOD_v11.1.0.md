# SpecterQA iOS Dogfood Report — v11.1.0

**Date:** 2026-04-07
**Reporter:** Palace iOS team (Maurice Carrier)
**App:** Palace iOS (org.thepalaceproject.palace)
**Environment:** macOS 15, Xcode 16.1, iOS 26 Simulator (iPhone 12)
**Previous report:** SPECTERQA_DOGFOOD_v10.1.0.md

---

## Executive Summary

**v11.1.0 ships the headline feature we asked for the most — `ios_webview_elements` — and it doesn't work.** The MCP tool exists and is registered, but the underlying XCTest runner returns `404 not found: GET /webview` when called. The MCP server was updated independently of the runner. This is a release-engineering failure.

Beyond that, v11.1.0 has **regressed the test suite from 16/17 → 6/17 in CI mode**, and even individual replays that passed cleanly in v10.0.0 now fail (smoke-test 4/5). The cross-replay state contamination from v10.1.0 has gotten dramatically worse — multiple replays now fail 0/X because the runner crashed during a previous replay and never recovered.

**This is the worst SpecterQA release we have tested.** It is a regression from v10.1.0, which was a regression from v10.0.0. The iteration speed that we celebrated in the previous report has now become a liability — features are shipping faster than they can be QA'd.

### Score Card

| Category | v10.1.0 | v11.1.0 | Trend |
|----------|---------|---------|-------|
| CI suite (17 replays) | 13/17 | **6/17** | ⬇⬇ |
| Critical gaps fixed | 1 (a11y audit) | **0** | ⬇ |
| New regressions | 1 (`ios_type` async crash) | **2+** (CI contamination worse, smoke-test broken individually) | ⬇ |
| Headline feature works | Yes (a11y audit) | **No** (`ios_webview_elements` returns 404) | ⬇⬇ |

---

## v11.1.0 Test Results

### Critical Bug Retests

| Gap | v11.1.0 status | Notes |
|-----|---------------|-------|
| **#1** WKWebView blindness | **Tool added but BROKEN** | `ios_webview_elements` MCP tool exists. Runner returns `404 not found: GET /webview`. Confirmed in EPUB reader with 8-page DAISY accessibility test book. |
| **#2** `press_key("return")` crash | **Still broken** | Same delayed-runner-crash. Tested in fresh session. |
| **#2b** `ios_type` async crash | **Still broken** | Same pattern. Triggers next-call failures. |
| **#3** `ios_set_appearance` during session | **Still broken** | Error message changed to "No booted simulators found". Behavior identical. |

### CI Suite Results

```
SUMMARY: 6 passed, 11 failed, 0 UI changed
```

| Replay | v10.0.0 | v10.1.0 | v11.1.0 | Notes |
|--------|---------|---------|---------|-------|
| app-launch | PASS | PASS | **PASS** | |
| book-detail | PASS | PASS | **PASS** | |
| book-transactions | PASS | PASS | **PASS** | |
| borrow-book | PASS | PASS | **PASS** | |
| catalog-browsing | PASS | PASS | **FAIL 1/2** | Regression |
| catalog-filter | PASS | PASS | **FAIL 1/3** | Regression |
| concurrent-borrow | (new) | FAIL 4/6 | **FAIL 3/6** | Worse |
| epub-reading | PASS | FAIL | **PASS 22/22** | Improved (!) |
| feed-refresh | (new) | PASS | **FAIL 0/1** | Regression |
| library-picker | (new) | PASS | **PASS** | |
| opds2-feed-parsing | PASS | PASS | **FAIL 18/20** | Regression |
| reservations-empty | PASS | PASS | **FAIL 2/3** | Regression |
| search-flow | PASS | FAIL | **FAIL 2/4** | Same regression as v10.1.0 |
| settings-screen | PASS | PASS | **FAIL 0/4** | Total runner crash |
| smoke-test | PASS | PASS | **FAIL 0/5** | Total runner crash |
| switch-library | PASS | PASS | **FAIL 0/4** | Total runner crash |
| tab-navigation | PASS | PASS | **FAIL 0/4** | Total runner crash |

### Pattern: 4 replays fail 0/X with `Remote end closed connection`

```
smoke-test: tap (x5) failed: XCTest runner /source request failed at http://localhost:8222/source: Remote end closed connection
settings-screen: tap (x4) failed: same error
switch-library: tap (x4) failed: same error
tab-navigation: tap (x4) failed: same error
```

These are simple, native, fast replays that have passed every prior version. They cannot fail on first step unless **the runner is already dead before the replay starts**. The `ci` command is not killing/restarting the runner between replays. A previous replay (likely `search-flow` typing or `concurrent-borrow` failing) crashes the runner, and every subsequent replay inherits a dead runner.

### Verification: Individual replay runs

When run individually with `specterqa-ios replay <file>`:
- `tab-navigation`: PASS 4/4 ✓
- `smoke-test`: FAIL 4/5 (timing assertion, not runner crash) — different from CI failure mode

So there are **two distinct regressions** in v11.1.0:
1. **`ci` runner cleanup is completely broken** — runner crashes propagate to all subsequent replays
2. **Individual replay timing has gotten more aggressive** — assertions that passed in v10 now race the UI

---

## The `ios_webview_elements` Bug

This is the headline feature of v11.1.0 and the most-requested gap in our entire dogfood history. **It is a paper feature.**

### Repro steps

```python
ios_start_session(bundle_id="org.thepalaceproject.palace", device_id="...")
ios_tap(label="Fundamental Accessibility Tests: Basic Functionality")  # navigate to book detail
ios_tap(label="Borrow")
ios_tap(label="Read")  # opens EPUB reader (Readium 3.x WKWebView)
ios_tap(label="Stay")  # dismiss resume dialog
ios_wait(seconds=3)
ios_elements()
# Returns 3 native elements (cover, page count, title) — reader chrome invisible as expected
ios_webview_elements()
# Returns: {"status": 404, "error": "not found: GET /webview"}
```

### Diagnosis

The MCP server in v11.1.0 has the `ios_webview_elements` tool registered and documented:

> "Get elements inside WKWebView content (EPUB readers, PDF viewers, audiobook UI rendered in WKWebView). Use this for testing EPUB readers, PDF viewers, audiobook UI rendered in WKWebView. XCTest can see WKWebView descendants via the .webViews chain — this is the only way to interact with web content embedded in a native app."

But the runner that gets deployed doesn't have a `/webview` endpoint. The MCP server was shipped independently of the runner. This is a release-engineering failure. **The headline feature of the release was not actually shipped end-to-end.**

### Why this is the worst possible bug

This is the gap that has blocked us across **5 versions** (v7.0.0 → v11.1.0). It is the single biggest blocker for testing reading apps. When v11.1.0 shipped with `ios_webview_elements` listed as a new tool, our reaction was "they finally did it." Then we tested it and it doesn't work.

This will erode customer trust faster than any other failure mode. It is better to **not ship the tool at all** than to ship a broken one that customers will excitedly try and then lose faith over.

---

## What v11.1.0 Did Not Fix (vs our gap report)

| Gap | Status | Versions still broken |
|-----|--------|----------------------|
| #1 WKWebView blindness | Tool added but broken | v7→v11.1 |
| #2 `press_key("return")` async crash | Still broken | v7→v11.1 |
| #2b `ios_type` async crash | Still broken | v10.1→v11.1 |
| #3 `ios_set_appearance` during session | Still broken | v7→v11.1 |
| #5-7 Assertion primitives | Still missing | v7→v11.1 |
| `ci` cross-replay cleanup | **Worse** | new in v10.1, much worse in v11.1 |

---

## The Strategic Pattern Has Worsened

In our v10.1.0 dogfood report we wrote:

> The hard ones require architecture work — WKWebView bridges, runner lifecycle, key event synthesis, simctl routing. Layering more capabilities on top of a foundation with known cracks is going to bite you.

v11.1.0 is exactly that biting. The team appears to have:

1. **Started the WKWebView fix** (added the MCP tool, started the runner endpoint)
2. **Shipped before the runner work was complete** (404 on the endpoint)
3. **Did not regression-test** existing replays before release (would have caught the smoke-test failure)
4. **Did not test `ci` behavior across replays** (would have caught the runner-cleanup regression)

**This is what happens when iteration speed exceeds QA capacity.** We celebrated 5 tools in 1 day in our previous report. We are now seeing the cost: a release where the headline feature is broken, the existing test suite is in pieces, and the underlying critical bugs are still unfixed.

### Recommendation: Slow down. Stabilize. Then ship.

We are repeating our previous recommendation more strongly:

> **Stop shipping new MCP tools for one release cycle.** Devote that cycle entirely to:
> 1. Making the existing test suite pass on a clean install
> 2. Fixing the `ci` runner cleanup so suites are reliable
> 3. Completing the `ios_webview_elements` runner endpoint that was half-shipped
> 4. Writing a regression test that runs the Palace iOS replay corpus on every internal build

That last point is critical. **You need a regression test for your own product.** Pick 5-10 replays that should always pass. Run them on every PR. If they fail, do not ship. We are happy to share our replay corpus as an integration test for SpecterQA itself.

---

## What Still Works

Credit where due:

- **`ios_tap(label=...)`** — still excellent
- **`ios_wait_for_element`** — works correctly
- **`ios_accessibility_audit`** — works correctly
- **`ios_start_recording` / `ios_stop_recording`** — works correctly
- **`ios_screenshot(quality="thumbnail")`** — works correctly
- **`ios_elements`** — works correctly
- **`ios_swipe`, `ios_swipe_back`** — works correctly
- 4 of our 17 replays still pass cleanly in `ci` (app-launch, book-detail, book-transactions, borrow-book)
- `epub-reading` actually IMPROVED from v10.1 (22/22 vs 11/22) — not sure why but we'll take it

The MCP tool layer is still solid. It is the **runner integration and release process** that is failing.

---

## Honest Customer Stance — Update

In our v10.1.0 report we said:

> We will keep using SpecterQA. The recording workflow with Claude is genuinely good, and we have 16/17 reliable tests we want to keep maintaining.

**This is now in question.**

Our test suite has gone from 16/17 reliable to **6/17 reliable in `ci` and unknown reliability individually** (we've only spot-checked a few). For us to keep using SpecterQA, we need v11.2.0 or v12.0.0 to:

1. Restore the 17/17 baseline that worked in v10.0.0
2. Actually ship a working `ios_webview_elements`
3. Fix the `ci` runner cleanup

If the next release does not deliver these, we will pause SpecterQA adoption and run our XCUITest suite as the primary testing path until the SpecterQA team has stabilized. We will continue to file gap reports but stop investing in new SpecterQA replays.

**This is not a threat. This is signal.** The reason we wrote this report is the same reason we wrote the previous ones — we want SpecterQA to win. But we need to manage the risk that the velocity we admired is now actively eroding the product.

### A specific ask

Please do one of the following before v12:

1. **Roll back v11.1.0** and re-cut as v10.2.0 with only the fixes that don't regress the runner.
2. **Ship v11.2.0** within 48 hours that restores v10.0.0 baseline and fixes the `/webview` 404.
3. **Publish a known-issues advisory** for v11.1.0 telling customers not to upgrade until the runner is fixed.

The worst path forward is ignoring the regression and shipping v12 with more new features on top of a broken foundation.

---

## Verdict

**v11.1.0 is the first SpecterQA release we cannot recommend.** It regresses the test suite, the headline feature is broken end-to-end, and the critical bugs from our gap report remain unfixed. The iteration speed that was the team's biggest asset is now compounding architectural debt faster than the team can pay it down.

**Specific quote we want the SpecterQA team to internalize:**

> Every customer who excitedly tested `ios_webview_elements` today and got `404 not found: GET /webview` is now slightly less likely to believe your next release notes. That trust is your most valuable asset in the agent-first marketplace race against Maestro. Spend it carefully.

We are still rooting for you. Please ship a fix.
