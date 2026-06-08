---
date: 2026-06-05
pr: "#TBD-swarm_162a3219-Module-D3"
source: shipped-bug
reviewer_ids: []
changeset_id: swarm_162a3219
walls: [contract, implementer, hook, verify-pr]
wall: hook
severity: high
wall_status: proposed
applied_in: ""
detector_script: scripts/check-completion-nil-error-suppression.py
name: pp4419-completion-nil-error-suppression
type: evolving
status: active
created: 2026-06-05
last_refresh: 2026-06-05
freshness_window: 365d
owners: [signin]
description: PP-4419 / HelpSpot 17870 — SAML sign-in silently failed because `completion(nil, title, message)` suppressed the consumer's `if let error` alert guard
---

# PP-4419 — `completion(nil, title, message)` suppresses consumer alert path

## Finding (verbatim from bug report)

> HelpSpot 17870: patron taps "Sign In" via SAML, SAML web sheet completes,
> tap "Done"/"Login" → nothing happens. No alert. No retry. App appears hung
> until the patron force-quits.
>
> Root cause: `Palace/SignInLogic/TPPSignInBusinessLogic+OAuth.swift` invoked
> `completion(nil, title, message)` from 3 failure exits (patron-ID extraction
> failed / auth-token missing / JSON parse failed). Consumer `TPPSAMLHelper`
> guards with `if let error, let errorTitle, let errorMessage` — a nil error
> blocks the alert path EVEN when title/message are non-nil. The error never
> surfaces. The user sees a tap with no observable consequence.

Fix landed in commit `547e185aa` (3-bug bundle for 3.2.0). Each failure exit
now synthesizes
`NSError(domain: "OAuth.SignIn", code: 0, userInfo: [NSLocalizedDescriptionKey: ...])`
and passes that as the first arg; the consumer's `if let error` guard then
succeeds and the alert path runs.

## What actually happened

The completion closure signature is `(Error?, String?, String?) -> Void`. The
implementer reading the failure-exit ladder thought "I don't have a real Error
object here, just a title/message — passing nil for the Error argument and
filling in title/message is the natural shape." That's natural-looking but
wrong: every consumer of the closure is a sign-in alert path that guards on
`if let error, let title, let message`. A nil error suppresses the alert
silently — there is no compile-time, lint-time, or test-time signal that this
is wrong, because every individual position is "correctly Optional."

The bug class is the asymmetry between PRODUCER (passes nil error + title +
message to mean "show this title/message to the user") and CONSUMER
(interprets nil error as "no error, no alert"). The closure type doesn't
encode the consumer's invariant; the implicit contract lives only in the
consumer's `if let` ladder.

## Walls that should have caught it (and why they didn't)

- **contract**: the OAuth extension's contract specified "call completion on
  failure" without specifying "must pass a non-nil Error so the consumer's
  guard succeeds." The closure signature `(Error?, String?, String?)` is
  permissive; the consumer's invariant is invisible at the type level.
- **implementer**: the implementer matched the closure shape, not the
  consumer-side semantic. No test exercised "what does the consumer DO with
  this call?" — only that the call was made.
- **TDD**: tests existed for the success path. Failure-path tests asserted
  "completion was called" without asserting "the consumer's alert path
  surfaced an error to the user." A consumer-side smoke test would have
  caught it (see CLAUDE.md "Consumer-side smoke test" rule).
- **mutation**: no mutation reached the consumer-side guard from a producer-
  side test — the producer-side tests didn't model the consumer at all.
- **verify-pr**: no static check for the specific shape
  `completion(nil, "literal", "literal")` existed.
- **hook**: no pre-commit hook flagged the pattern.

## Proposed permanent fix

A static detector (`scripts/check-completion-nil-error-suppression.py`) that
flags the PR547e185aa pre-fix shape at the line where the consumer-suppression
suppression occurs. Phase-1a-revised predicate:

> Flag a call where the receiver ends in `completion` (with or without `?`)
> AND ARG-1 is exactly `nil` AND args 2+ contain ≥1 String-typed top-level
> expression (bare string literal, interpolated string, bare
> `NSLocalizedString(...)`, `Strings.<...>` constant, or a `title`/`message`/
> `errorTitle`/`errorMessage` identifier bound via `let <name> = "..."`
> earlier in the same function body).

False-positive guard explicitly EXCLUDES:
- `completion?(nil, nil, nil)` — OAuth success path
  (`Palace/SignInLogic/TPPSignInBusinessLogic+OAuth.swift:244`, verified).
- `completion?(nil, response, error)` — failure-passthrough where the error
  IS supplied in a non-arg-1 position
  (`Palace/Network/TPPNetworkExecutor.swift:464,484`).
- `completion(nil, nil, DPLAError.requestError("..."))` — the DPLA cert-key
  callback signature `(Data?, Date?, Error?)` — error in arg 3, string
  literal nested inside the Error constructor doesn't count as a top-level
  String-typed arg.

Annotation escape: `// no-nil-error-suppression: <reason>` on the call line
or any of the 3 preceding lines.

Wire-in: verify-pr.sh runs the detector at `--severity-floor high` against
the staged diff; a high finding blocks the PR. Mirror the existing M1
detector convention.

## Stale-doc contribution

n/a — `stale-doc` is not in `walls`.

## Application log

- 2026-06-05 — detector + tests + 7 fixtures landed in swarm_162a3219 Module
  D3. Scan of the repo at land time: 0 survivors (PR #1029-stack already
  fixed all known sites; the original 3 sites are at OAuth lines that the
  canonical PR547e185aa fix replaced with NSError-synthesizing variants).

## Related entries

- `2026-05-28-backfill-pr1018-blast-radius.md` — sibling D-detector family
  (BR-* prevention).
- `2026-05-28-backfill-pr1022-claim-drift.md` — sibling static-detector
  precedent (claim-drift gate).
- `2026-06-05-pr1018-icarus-cross-host-logout.md` — sibling Module B
  detector (FH-1, host-scoping); same swarm.
