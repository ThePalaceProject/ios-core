---
date: 2026-06-05
pr: "#935"
source: shipped-bug
reviewer_ids: []
changeset_id: cs_162a3219_D4
wall: contract
walls: [contract, TDD, reviewer]
severity: high
wall_status: applied
applied_in: "5c66f108c"
detector_script: "scripts/check-nserror-problemdoc-preservation.py"
detector_status: built
no-detector: ""
contributing_docs: []
# doc-lifecycle metadata
name: 2026-06-05-pp3956-nserror-problemdoc
type: evolving
status: active
created: 2026-06-05
last_refresh: 2026-06-05
freshness_window: 365d
owners: [auth, network]
description: NSError(...) construction in token-refresh re-wrap discarded the upstream RFC 7807 problem document, fallback "Invalid Credentials" leaked to userFacingSignInError instead of the server-supplied title/detail.
---

# PP-3956 / PR #935 — NSError construction discards upstream TPPProblemDocument context

## Finding (verbatim from PR #935 commit body)

> Background: PR #931 (dbernstein) fixed TokenRequest in isolation. This PR
> generalizes the fix and closes a second instance of the same class-of-bug —
> TPPNetworkExecutor's token-refresh re-wrap was discarding the upstream
> problemDocument via localizedDescription-only, so token-refresh failures still
> showed the generic "Invalid Credentials" fallback even with #931 in place.
>
> [...]
>
> **Deferred:** Lint rule that would grep Palace/SignInLogic/ + Palace/Network/
> for `NSError(domain:` constructions without `makeFromHTTPResponse` /
> `makeFromProblemDocument` and flag them at review time. Would prevent future
> regressions of this class.

## What actually happened

`TPPNetworkExecutor.refreshTokenAndResume` received an upstream error whose
`userInfo` already carried an RFC 7807 problem document (e.g. server-supplied
title `"Expired Card"`). The token-refresh failure branch then re-wrapped the
error into a fresh `NSError(domain: TPPErrorLogger.clientDomain, code:
.invalidCredentials, userInfo: [NSLocalizedDescriptionKey: "Token refresh
failed: ..."])` — and the upstream `problemDocument` key was dropped from
`userInfo`.

Downstream, `TPPSignInBusinessLogic.userFacingSignInError(for:problemDocument:)`
reaches for `problemDocument.title / .detail` first, but with the problemDoc
dropped during the re-wrap it falls through to the generic
`Strings.Error.invalidCredentialsErrorTitle / Message`. Users with expired
cards saw a generic "Invalid Credentials" prompt instead of the
server-supplied "Expired Card" explanation, masking the actual remediation
path.

PR #931 fixed the same class in `TokenRequest`. PR #935 generalized the
fix with a `NSError.makeFromHTTPResponse(...)` / `makeFromProblemDocument`
helper, refactored the executor's re-wrap to consult `(error as
NSError).problemDocument` and embed it via the helper, and added
`AuthErrorProblemDocSeamTests` to lock the cross-class contract.

## Walls that should have caught it (and why they didn't)

- **contract**: The original TokenRequest acceptance criteria did not
  require a cross-class seam test ensuring `TokenRequest →
  NSError.problemDocument → userFacingSignInError` survived intermediate
  re-wraps. The class-of-bug definition lived only in the PR #931 retro,
  not in any structural artifact.
- **TDD**: `TPPNetworkExecutor.refreshTokenAndResume` had no unit test
  that drove a problem-doc-bearing failure through the closure and
  asserted the resulting NSError's `problemDocument` accessor returned
  non-nil. The lack of a seam test meant the discarding re-wrap looked
  identical to a clean one at code-review time.
- **reviewer**: A human reviewer reading the re-wrap saw a plausibly
  structured NSError construction. Without a grep-able lint rule for
  "NSError construction in HTTP-response context with no
  problemDocument preservation," the pattern was indistinguishable
  from a legitimate `NSError(...)` for a non-HTTP error (e.g. empty
  username validation).

## Proposed permanent fix

Build `scripts/check-nserror-problemdoc-preservation.py` (the deferred lint
rule called out explicitly in PR #935's commit body). Predicate D4-1:

  Within a single Swift function body in a production file under `Palace/`,
  the function receives a `TPPProblemDocument` somewhere in scope (parameter
  declaration, `(error as NSError).problemDocument` binding,
  `TPPProblemDocument.fromProblemResponseData(...)`, etc.) AND constructs
  `NSError(...)` AND the userInfo dictionary does NOT reference
  `problemDocument.title` / `problemDocument.detail` / `NSError.problemDocumentKey`
  / `makeFromProblemDocument(...)` / `makeFromHTTPResponse(...)`.

  Annotation escape: `// no-problemdoc-preservation: <reason>` on the
  NSError-construction line or the 3 preceding lines.

The detector is wired into `scripts/verify-pr.sh` and the
`.claude/settings.json` PreToolUse hook so any future `NSError(...)`
construction in a function that has a problemDoc in scope must explicitly
embed the title/detail (or route through the canonical helper, or
annotate the discard with rationale). Structurally impossible to land
the original drop pattern without the annotation reviewer pass would
catch.

## Detector script

**Script:** `scripts/check-nserror-problemdoc-preservation.py`
**Tests:** `scripts/tests/test_check_nserror_problemdoc_preservation.py`
**Wired into:** `scripts/verify-pr.sh` (both `--quick` and full);
`.claude/settings.json` PreToolUse hook (Edit/Write/MultiEdit on
`Palace/Network/**` and `Palace/SignInLogic/**`).

**What it catches:** Any Swift function body in `Palace/Network/` or
`Palace/SignInLogic/` that (a) receives or binds a `TPPProblemDocument`
in scope and (b) constructs an `NSError(domain:..., code:..., userInfo:...)`
whose userInfo dictionary makes no reference to `problemDocument.title`,
`problemDocument.detail`, `NSError.problemDocumentKey`,
`makeFromProblemDocument(`, or `makeFromHTTPResponse(`. The canonical fix
shape — either embed `problemDocument.title` / `.detail` directly into
userInfo or route the construction through `NSError.makeFromHTTPResponse`
— is detected by the preservation regex set, so the canonical fix passes
without an annotation.

**False-positive escape hatch:** `// no-problemdoc-preservation: <reason>`
on the same line as the NSError construction or up to 3 lines above it.
Used when the surrounding function legitimately re-wraps to a generic
error and the upstream problemDoc is logged elsewhere (e.g.
`TPPErrorLogger.logNetworkError(...)`). Reviewer-readable rationale
required.

**Severity (high) and rationale:** This is a critical-path auth UX
regression — wrong sign-in error string masks the actual remediation
the user needs to take (expired card, blocked account, etc.). Severity
high matches the sibling detectors on critical-path code (FH-1, D1, D3).

**Coverage measured at landing:** 5/5 pytest cases pass against the
fixture surface (violation, clean-title-preserved, clean-detail-preserved,
annotated, no-problemdoc-in-scope). The fixture surface exercises every
branch of `_scan_file`: in-scope detection, NSError construction (inline
and multi-line), preservation evidence, annotation escape, and the
no-problemdoc-in-scope false-positive immunity case.

## Application log

- 2026-05-11 — original fix landed in PR #935 (commit `5c66f108c`).
- 2026-06-05 — detector + 5 pytest cases + fixture surface landed via
  swarm `swarm_162a3219` Module D4.

## Related entries

- `2026-06-05-pr1018-icarus-cross-host-logout.md` — adjacent auth-error
  classification class; the FH-1 detector and the D4-1 detector together
  cover the two halves of "auth-error context preservation" — FH-1 catches
  401-dispatch that drops host scoping; D4-1 catches NSError re-wrap that
  drops problem-doc content.
- The `dishonest migration` cluster (PR #1018 arch3): same upstream-call
  shape (`call new helper / discard outcome`); the D4-1 detector's
  preservation-evidence regex is the inverse — "call the new helper OR
  embed the preserved fields directly, otherwise flag."
