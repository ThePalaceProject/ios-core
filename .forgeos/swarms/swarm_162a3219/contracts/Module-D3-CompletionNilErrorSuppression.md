# Module D3 — `completion(nil, title, message)` consumer-guard suppression detector

**Owner module:** scripts/ + verify-pr.sh
**Risk:** critical_path (sign-in / SAML / OAuth flows)
**Est LOC:** ~220

## Background

PP-4419 / HelpSpot 17870: SAML sign-in silently fails when `TPPSignInBusinessLogic+OAuth.swift` calls `completion(nil, title, message)`. The consumer `TPPSAMLHelper` guards `if let error, let errorTitle, let errorMessage` — a nil error blocks the alert path even when title/message are set. The pattern: a 3-arg completion `(Error?, String?, String?)` called with `nil` for the error while the consumer requires non-nil error to surface the alert.

## Scope (in)

| File | Change | Est LOC |
|------|--------|---------|
| `scripts/check-completion-nil-error-suppression.py` (NEW) | Detects the **PP-4419 bug shape specifically**: a completion call where ARG-1 is `nil` AND args 2+ contain ≥ 1 string literal (e.g. `completion(nil, "Sign In Failed", "...")` or `completion?(nil, title, message)` where the call is preceded by `let title = "..."` / `let message = "..."`). **Phase-1a-revised: do NOT match `completion?(nil, nil, nil)` — that's the OAuth success path and a false positive (verified at `Palace/SignInLogic/TPPSignInBusinessLogic+OAuth.swift:244`).** Heuristic: scan added/modified Swift; require at least one string-literal positional arg in positions 2-3 OR a recently-bound `title`/`message` variable in scope. Annotation: `// no-nil-error-suppression: <reason>`. | +140 |
| `scripts/test_check_completion_nil_error_suppression.py` (NEW) | 5 tests — violation, clean-with-synth-NSError (the canonical fix), clean-when-completion-omits-title, clean-with-annotation, no-completion-in-scope. | +50 |
| Wiring + hook + wall-failure entry | (analogous) | +30 |

## Predicted survivors

Scan: `grep -rn "completion?(nil," Palace/SignInLogic/`. Predict 0-3 (PR547e185aa addressed the known cases; OIDC migration covers most). Wipe any survivor with the canonical NSError synthesis pattern. **Phase-1a-revised false-positive guard:** `Palace/SignInLogic/TPPSignInBusinessLogic+OAuth.swift:244` (`completion?(nil, nil, nil)`) is the OAuth success path — the detector predicate must NOT flag this. If the implementer's detector hits this site, the predicate is too broad (return to drawing board, do not silently annotate).

## Scope (out)

- Non-completion-based async APIs (`async` functions) — different shape.
- Test-mock completions — out of scope (annotation suffices).

## Verification, tests, acceptance — same shape as D1.
