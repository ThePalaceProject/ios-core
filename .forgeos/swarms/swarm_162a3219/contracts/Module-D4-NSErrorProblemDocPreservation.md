# Module D4 — NSError construction discarding problemDocument detector

**Owner module:** scripts/ + verify-pr.sh
**Risk:** critical_path (user-facing error messaging on auth / borrow / return)
**Est LOC:** ~200

## Background

PP-3956 / PR #935: TPPNetworkExecutor's token-refresh re-wrap was discarding the upstream `problemDocument` via `localizedDescription`-only. The fix introduced `NSError.makeFromHTTPResponse(...)` as a single named entry point that embeds RFC 7807 problem docs. The class: any `NSError(domain:..., userInfo:...)` constructed from an HTTP response body that drops the `problemDocument` key.

## Scope (in)

| File | Change | Est LOC |
|------|--------|---------|
| `scripts/check-nserror-problemdoc-preservation.py` (NEW) | Detects `NSError(domain:..., code:..., userInfo:...)` calls in scope where `HTTPURLResponse` and a response-body `Data` (or `localizedDescription`-derived String) are in scope, AND the userInfo dict does NOT contain a `"problemDocument"` key or `.problemDocument` reference. Recommend `NSError.makeFromHTTPResponse(...)` in the finding message. Annotation: `// no-problemdoc-preservation: <reason>`. | +120 |
| `scripts/test_check_nserror_problemdoc_preservation.py` (NEW) | 5 tests — violation, clean-with-makeFromHTTPResponse, clean-with-explicit-problemDocument-key, annotated, no-HTTPURLResponse-in-scope. | +50 |
| Wiring + hook + wall-failure entry | (analogous) | +30 |

## Predicted survivors

Scan: `grep -rln "NSError(domain:" Palace/Network/ Palace/SignInLogic/`. Predict 1-4 (PR #935 was a partial sweep — "Sweep of other NSError constructions in Palace/Network/ — the deferred sweep" per commit body). Wipe survivors.

## Scope (out)

- NSErrors NOT constructed from an HTTP response (e.g. user-input validation).
- Test fixtures.

## Verification, tests, acceptance — same shape as D1.
