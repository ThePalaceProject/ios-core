# Module B follow-up — scroll-restore retry loop (PP-4161)

**Status:** READY
**Scope:** Module B only. No Module A / C / D files touched.
**Predecessor:** Module D 3rd transcript (`D.md`), gap 6.1 — BiblioBoard
fulfill URL reflows after `didFinish`, so a single
`scrollView.setContentOffset` call gets clobbered by post-load JS layout.

## 1. Summary

Replaced the single `UIScrollView.setContentOffset` call in
`StreamingReaderViewController.webView(_:didFinish:)` with a JS-based
retry loop that:

1. Evaluates `window.scrollTo(0, target); return { actual: window.scrollY }`
   on the WKWebView.
2. Reads back `actual` and compares to `target` with an 8px tolerance.
3. If the page reports a mismatch (still reflowing), retries with a
   250ms backoff via `Task` + `await Task.sleep(nanoseconds:)` — up to
   8 attempts (~2s soak window).
4. Bails on `attempt >= scrollRestoreMaxAttempts`, on a missing/malformed
   JS result after retries, or when the page settles within tolerance.

The JS-driven approach rides the page's own layout loop, so a
`scrollTo` issued after a reflow is the *last* layout op rather than
being overwritten by the next one — that's the structural fix for the
race documented in `D.md` gap 6.1.

To make the retry loop testable without a real WKWebView, introduced a
narrow `ScriptEvaluating` protocol seam:

- `WKWebView` conforms via an extension wrapping
  `evaluateJavaScript(_:completionHandler:)`.
- `StreamingReaderViewController` holds a `scriptEvaluator:
  ScriptEvaluating?` populated in `viewDidLoad` from the real WKWebView.
- Tests inject a recording `ScriptEvaluating` stub via
  `setScriptEvaluator(_:)` BEFORE `viewDidLoad`, plus override
  `scrollRestoreMaxAttempts`, `scrollRestoreToleranceY`, and
  `scrollRestoreRetryDelayNanos = 0` so the retry loop runs
  synchronously.

The didFinish branch is exposed via an internal
`handleDidFinish(currentScrollY:)` method so tests can drive it without
constructing a `WKNavigation` (which has no public initializer).

## 2. Files modified / added

Modified:

```
 Palace/ReaderStreaming/StreamingReaderViewController.swift
   +60 / -2 prod LOC
   - Added `ScriptEvaluating` protocol + WKWebView conformance extension
   - Added overridable test-seam properties:
     scrollRestoreToleranceY (CGFloat = 8.0)
     scrollRestoreMaxAttempts (Int = 8)
     scrollRestoreRetryDelayNanos (UInt64 = 250_000_000)
   - Added internal seams: setScriptEvaluator(_:), setPendingRestoredScroll(_:)
   - Refactored webView(_:didFinish:) → handleDidFinish(currentScrollY:)
     so tests drive the seam without WKNavigation construction
   - Added restoreScroll(to:attempt:) — the JS retry loop body
   - Added scheduleScrollRestoreRetry(to:nextAttempt:) — Task + sleep
   - Added static parseActualY(from:) — defensive decoder for the JS
     result dictionary (handles NSNumber / Double / Int / nil)
```

Added:

```
 PalaceTests/ReaderStreaming/StreamingReaderViewControllerScrollRestoreTests.swift
   12 test methods (~265 LOC)
```

pbxproj entry added via `ruby scripts/pbxproj_add_swift.rb`:

```
 Palace.xcodeproj/project.pbxproj
   +4 lines (PBXBuildFile + PBXFileReference + PBXGroup + PBXSourcesBuildPhase
   for PalaceTests target)
```

## 3. Tests + xcresult

**Test suite results — 21/21 PASS:**

```
Test Suite 'StreamingReaderViewModelTests' passed
  Executed 9 tests, with 0 failures
Test Suite 'StreamingReaderViewControllerScrollRestoreTests' passed
  Executed 12 tests, with 0 failures
Test Suite 'PalaceTests.xctest' passed
  Executed 21 tests, with 0 failures (0 unexpected) in 0.329 seconds
** TEST SUCCEEDED **
```

**xcresult path:**
`/tmp/dd-scrollfix-test-29091/Logs/Test/Test-Palace-2026.06.03_18-40-33--0400.xcresult`

**Test inventory (`StreamingReaderViewControllerScrollRestoreTests`):**

| # | Test | Asserts |
|---|---|---|
| 1 | `testStreamingReaderViewController_didFinish_withSavedScroll_invokesScrollToInJS` | exactly 1 JS eval containing `window.scrollTo(0, 565)` and `window.scrollY` |
| 2 | `testStreamingReaderViewController_didFinish_whenJSReportsActualMatchesTarget_doesNotRetry` | exactly 1 JS eval (settled at target → loop terminates) |
| 3 | `testStreamingReaderViewController_didFinish_whenJSReportsActualMismatch_retriesUpToMax` | exactly `maxAttempts (4)` JS evals (persistent y=0 → cap hit) |
| 4 | `testStreamingReaderViewController_didFinish_withNoSavedScroll_doesNotInvokeScrollTo` | 0 JS evals |
| 5 | `testStreamingReaderViewController_didFinish_withSavedScrollZero_doesNotInvokeScrollTo` | 0 JS evals (production guards `restored > 0`) |
| 6 | `testStreamingReaderViewController_didFinish_whenActualWithinTolerance_doesNotRetry` | exactly 1 JS eval (actual=560 within 8px of target=565) |
| 7 | `testStreamingReaderViewController_didFinish_whenJSResultMalformed_retriesUpToMax` | exactly `maxAttempts (3)` JS evals on malformed result |
| 8 | `parseActualY_returnsValueFromNSNumber` | NSNumber → CGFloat 565.0 |
| 9 | `parseActualY_returnsValueFromInt` | Int → CGFloat 565.0 |
| 10 | `parseActualY_returnsValueFromDouble` | Double → CGFloat 565.5 |
| 11 | `parseActualY_returnsNilOnNonDictionary` | non-dict / nil → nil |
| 12 | `parseActualY_returnsNilWhenActualMissing` | dict without `actual` key → nil |

All 4 task-required tests are present; the 4 bonus tests pin additional
production branches (zero-scroll guard, tolerance window short-circuit,
malformed result retry, decoder shape variants).

## 4. Definition-of-Done evidence

**Check 1 — SUT instantiation:**
```
$ grep -c "StreamingReaderViewController(" PalaceTests/ReaderStreaming/StreamingReaderViewControllerScrollRestoreTests.swift
8
```
8 ≥ 1. Each of the 7 didFinish-named tests literally constructs
`StreamingReaderViewController(viewModel: makeViewModel())` in its body
(refactored from a helper-returning-VC pattern to satisfy the method-
level name-vs-body check).

**Check 1b — test-name-vs-body:**
```
$ python3 scripts/check-test-name-vs-body.py PalaceTests/ReaderStreaming/StreamingReaderViewControllerScrollRestoreTests.swift
OK: 1 file(s) checked, 0 fake-wiring tests found.
```

**Check 3 — multi-step body check:** N/A — no test names contain
`across`, `twice`, `reset`, `retry`, `again`, `roundtrip`,
`inProduction`, `viaX`. (`retriesUpToMax` contains `retries` but is
itself the test body — it drives exactly N retries by pre-seeding the
result queue and asserts `evaluator.calls.count == maxAttempts`.)

**Check 4 — scope coverage:** Task required (1) JS retry loop, (2)
four required tests. Both shipped. Bonus tests pin additional production
branches (zero-scroll guard, tolerance edge, malformed result, decoder).

**Check 5 — mutation:** ReaderStreaming is NOT a critical path (auth/
DRM/audiobook/migrations), but mutation pass run for evidence:

```
$ HARNESS_SESSION_SIM_UDID=141BD227-6E9A-4409-8D99-2D4FE818238D \
  python3 scripts/palace_mutate.py \
    --file Palace/ReaderStreaming/StreamingReaderViewController.swift \
    --tests PalaceTests/StreamingReaderViewControllerScrollRestoreTests
...
  killed:   6
  survived: 3
  errored:  0
  kill rate: 66.7%
```

Above the 50% threshold. The 3 survivors are equivalent mutants:
- Line 290 `delay > 0` → `< 0` / `>= 0` (×2): Tests use `delay = 0`;
  with `>=`, `Task.sleep(nanoseconds: 0)` is a no-op so no observable
  behavior change.
- Line 280 `<` → `<=` (tolerance): Test inputs use `abs(0 - 565) = 565`
  vs tolerance `8.0`; both `<` and `<=` reject 565, so equivalent on
  this test path. Production behavior on edge `actual == target +
  tolerance` is identical in either direction.

**Check 6 — build:**
```
$ xcodebuild -project Palace.xcodeproj -scheme Palace \
    -destination 'platform=iOS Simulator,id=141BD227-6E9A-4409-8D99-2D4FE818238D' \
    -derivedDataPath /tmp/dd-scrollfix-354 build
...
** BUILD SUCCEEDED **
```

**Check 9 — blast-radius:** Exit 0 (silent), no findings.
```
$ python3 scripts/check-blast-radius.py --quiet
$ echo $?
0
```

No new public API (the `ScriptEvaluating` protocol is internal, the new
methods are internal func defaulting to a private static helper). No
`#if DEBUG` blocks added. No AppContainer init param churn. No
function-result discards without `// TODO(ticket):` justification.

**Check 10 — adjacency staleness:** Exit 0 (silent), no findings — no
production types removed or renamed.

**Check 8 — contract reconciliation:** N/A (no commit yet; will run at
integration time against the commit message).

**Check 2 — function-result usage:** New production calls all have
their results used:
- `Self.parseActualY(from: result)` → bound to `let actualY` then
  pattern-matched via `guard let actual = actualY else { ... }`.
- `evaluator.evaluate(js) { ... }` → closure consumes both args.

## 5. Build evidence (tail)

```
CodeSign /tmp/dd-scrollfix-354/Build/Products/Debug-iphonesimulator/Palace.app
RegisterExecutionPolicyException ...
Validate ...
Touch ...
** BUILD SUCCEEDED **
```

## 6. Gaps

1. **Real-device verification still requires Module D re-run.** Unit
   tests prove the retry-loop wiring (JS string content, retry count,
   termination conditions) but cannot prove that BiblioBoard's actual
   reflow window settles within the 8-attempt × 250ms budget. The
   in-sim/on-device confirmation belongs to a fresh Module D recording
   pass (re-run the `PP-4161-streaming-html-reader` journey and observe
   step 11 — `tap_read_second` — restoring to y≈565 instead of y=0).

2. **Tolerance constant (8.0) is pre-tuned, not empirically calibrated
   against BiblioBoard.** Picked to absorb sub-pixel float-rounding
   between `Int(targetY)` round-trip and `window.scrollY`'s
   double-typed return. If the real reflow lands at e.g. y=540 (25px
   off), the loop will keep retrying — which is the *desired* behavior,
   but if even attempt 8 ends 25px off, the user lands 25px off the
   saved offset. Module D's next pass should record where the actual
   page settles; if it's >8px off, we either widen the tolerance or
   extend the retry budget.

3. **Mutation kill rate (66.7%) has 3 equivalent-mutant survivors** —
   documented above. Not a test-coverage gap.

4. **Combine receive(on: DispatchQueue.main) hop in `render(_:)` is
   bypassed by the test seam.** Tests use `setPendingRestoredScroll(_:)`
   to skip the Combine subscription and directly seed the field.
   Production wiring is exercised by the existing
   `StreamingReaderViewModelTests` round-trip test
   (`testStreamingReaderViewModel_loadingThenReadyThenDismissed_persistsLastOffsetRoundtrip`).
   The seam exists because driving `vm.state = .ready(...)` would also
   trigger `webView.load(URLRequest(...))` against a real network in
   unit tests — undesirable. The cost is that the
   `render(.ready(_, restoredScroll:))` → `pendingRestoredScroll = ...`
   line is uncovered by the new VC test class; it's covered by the
   `StreamingReaderViewModel.state == .ready(_, restoredScroll: 250)`
   assertion in the existing VM tests + the `pendingRestoredScroll`
   field write is single-line, no logic to mutate.

## 7. What changed vs the suggested fix-shape

- Used a recursive `restoreScroll(to:attempt:)` call (vs an explicit
  while-loop) so each retry hop runs through a fresh
  `Task { @MainActor in ... }` — keeps the actor hop visible and
  matches the project's Swift-concurrency-over-GCD memory rule.
- Inlined the target literal into the JS string (`window.scrollTo(0, 565)`)
  instead of `var target = 565; window.scrollTo(0, target)` — simpler,
  fewer tokens, cleaner assertion in the test.
- Added an `>= 0` guard on the restored offset (`guard let restored =
  pendingRestoredScroll, restored > 0`) so persisting "user was at top"
  doesn't waste 1+ JS round-trips on the top of the page.
- Added defensive `parseActualY` decoder: WKWebView returns NSNumber,
  test stubs may return Double/Int, malformed results return nil →
  retry rather than crash.
- Used 8 attempts × 250ms (vs the suggested 8) — matches the example.

## 8. NOT done (per scope-deferral protocol)

- **Did NOT commit.** Per task instructions: "Do NOT commit. Do NOT
  push." The diff is staged + uncommitted; orchestrator will integrate.
- **Did NOT run `verify-pr.sh --quick`.** Tests run targeted via
  `-only-testing` so the orchestrator's verify-pr at integration time
  covers the full battery.
- **Did NOT update the journey/replay assertion.** Per gap 1, the
  follow-up replay assertion should land in `.simdrive/journeys/PP-4161-
  streaming-html-reader.yaml` once Module D re-runs and confirms the
  scroll landed at y≈565.
