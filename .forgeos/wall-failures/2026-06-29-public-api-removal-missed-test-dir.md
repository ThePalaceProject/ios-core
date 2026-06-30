---
date: 2026-06-29
source: near-miss
walls: [verify-pr]
severity: medium
wall_status: applied
applied_in: "feat/swift6-palacelogging (#1129)"
---

# public-api-removal-missed-test-dir

## Finding

PR #1129 (PalaceLogging → Swift 6) removed the public `Log.dateFormatter`
(localized it to a private helper to drop a non-`Sendable` global). The module
built clean and its own tests passed, but the full-app CI `build-and-test`
FAILED: `PalaceTests/Logging/LogTests.swift:187:29: error: type 'Log' has no
member 'dateFormatter'`. A test in the app's test target still referenced the
removed public API.

## What actually happened

Before removing the public API I grepped for callers — but scoped the search to
`Palace/` (the app source dir): `grep -rn "Log.dateFormatter" Palace ...`. The
repo keeps its unit tests in a SIBLING dir, `PalaceTests/`, NOT under `Palace/`,
so the search never saw `LogTests.swift`. It returned empty → "no external
callers, safe to remove." The single remaining caller lived in exactly the dir
the search excluded. It compiled fine locally (the package + module build don't
include the app test target) and only surfaced on CI's full-app build.

## Walls that should have caught it

- **verify-pr / pre-merge build:** the only thing that caught it was the
  spike's full-app CI — which is *why* spike-first exists (prove one module
  end-to-end before fan-out). But the BREAK was avoidable at authoring time: an
  API-removal usage-search that omits the test dir is structurally incomplete.
  No gate enforced "search the whole repo before removing a public symbol."

## Proposed permanent fix

When changing or removing a `public`/`open` symbol, search the WHOLE repo, not
the app source dir:

    grep -rn "<Symbol>" Palace PalaceTests --include='*.swift'   # both dirs
    # or simply: grep -rn "<Symbol>" . --include='*.swift' | grep -v '/.build/'

Make it structural, not "remember to": a pre-commit/verify-pr check that, for any
diff hunk REMOVING a `public`/`open` declaration `X`, greps the whole working
tree (excluding `.build/`, `.derived/`, `.claude/worktrees/`) for remaining
references to `X` and blocks if any survive outside the changed file. This is the
modernization-relevant detector — every module conversion removes/changes public
symbols, so the whole-repo-search must be the default, enforced path.

## Application log

- 2026-06-29: caught by #1129 full-app CI. Fixed by moving the format coverage
  into PalaceLogging's own test target (`LogFormatTests`, via the now-`internal`
  `Log.formattedTimestamp`) and dropping the stale `PalaceTests/Logging/LogTests`
  test. Whole-repo grep confirmed `LogTests.swift:187` was the only real caller.
