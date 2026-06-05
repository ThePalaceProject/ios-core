# Module D3 — `completion(nil, title, message)` consumer-guard suppression detector

**Owner module:** scripts/ + verify-pr.sh
**Risk:** critical_path (sign-in / SAML / OAuth flows)
**Est LOC:** ~220

## Background

PP-4419 / HelpSpot 17870: SAML sign-in silently fails when `TPPSignInBusinessLogic+OAuth.swift` calls `completion(nil, title, message)`. The consumer `TPPSAMLHelper` guards `if let error, let errorTitle, let errorMessage` — a nil error blocks the alert path even when title/message are set. The pattern: a 3-arg completion `(Error?, String?, String?)` called with `nil` for the error while the consumer requires non-nil error to surface the alert.

## Scope (in)

| File | Change | Est LOC |
|------|--------|---------|
| `scripts/check-completion-nil-error-suppression.py` (NEW) | Detects `completion(nil, "...", "...")` or `completion(nil, title,` style calls where the function signature is `(Error?, String?, String?) -> Void` (or similar Optional<Error>-first). Heuristic: scan added/modified Swift; find `completion?(nil, ` patterns; report. Annotation: `// no-nil-error-suppression: <reason>`. | +140 |
| `scripts/test_check_completion_nil_error_suppression.py` (NEW) | 5 tests — violation, clean-with-synth-NSError (the canonical fix), clean-when-completion-omits-title, clean-with-annotation, no-completion-in-scope. | +50 |
| Wiring + hook + wall-failure entry | (analogous) | +30 |

## Predicted survivors

Scan: `grep -rn "completion?(nil," Palace/SignInLogic/`. Predict 0-3 (PR547e185aa addressed the known cases; OIDC migration covers most). Wipe any survivor with the canonical NSError synthesis pattern.

## Scope (out)

- Non-completion-based async APIs (`async` functions) — different shape.
- Test-mock completions — out of scope (annotation suffices).

## Verification, tests, acceptance — same shape as D1.
