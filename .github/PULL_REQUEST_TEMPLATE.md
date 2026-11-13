<!-- Aim for about 20 lines; the PR hygiene check fails a body over ~1,500 characters
     (screenshots and these comments do not count). Title: imperative, 72 chars max,
     no internal run IDs. See "Writing conventions" in CLAUDE.md. -->

## What
<!-- 1-3 sentences on the change. -->

## Why
<!-- 1-3 sentences on the problem it solves for patrons or developers. Jira link if any. -->

## How verified
<!-- One line per test added or changed and what it asserts (4 bullets max), plus any
     manual or device checks. Screenshots for UI changes. -->
-

## Evidence
<!-- Required when the PR changes Palace/ or PalaceTests/; one line per key, about 600
     characters in all, not counted in the body limit. "not run: <reason>",
     "not applicable: <reason>" or "none; <reason>" is fine without maintainer-only tools.
     Red first: tests that failed before the change.
     Mutation: killed N, survived N, errored N on changed lines (or per file
       `File` N/N/N (killed/survived/errored)).
     Simulator: in-app steps and the result.
     Reviews: N independent reviews, approved at <short sha>; or none.
     Known behavior kept: PP keys from `// Known:` markers this PR adds; or none. -->
- Red first:
- Mutation:
- Simulator:
- Reviews:
- Known behavior kept:

## Not done
<!-- Optional: known gaps and follow-ups. Delete if empty. -->
