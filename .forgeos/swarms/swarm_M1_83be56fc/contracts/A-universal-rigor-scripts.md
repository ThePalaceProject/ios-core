# Module A — Universal rigor scripts (M1)

**Critical-path-meta.** Defects propagate to every future commit. Architect + qa_test + clean_code review required.

## Goal

Ship 4 stdlib-only Python 3 scripts that catch the gap classes wave 1-4 manual review exposed.

## Deliverables

### `scripts/check-contract-reconciliation.py`
- Reads commit body / PR body / intent file / swarm contract.
- Parses claims via regex: "removes X" / "migrates Y to Z" / "adds field A to type B" / "renames X to Y" / "extracts X into P" / "fixes N findings".
- Greps the staged diff for each claim's reconciliation evidence.
- Exit 1 if any claim unsupported; exit 0 if all reconcile.
- Flags: `--commit-msg <file>`, `--pr-body <file>`, `--intent <file>`, `--swarm-contract <path>`, `--diff <file>`, `--quiet`, `--dry-run`.
- KNOWN-BAD fixture: wave 4 commit a6f60dbf2's parent body claimed "removes HostingController" while diff renamed. Script MUST exit 1.
- KNOWN-GOOD fixture: a6f60dbf2 cleanup body claiming 11 finding fixes; diff shows 11 edits. Script MUST exit 0.

### `scripts/check-blast-radius.py`
- Scans staged diff for:
  - BR-1 (high): new `public`/`open` symbols on non-test files
  - BR-2 (high → medium if XCTest env-gated): new `#if DEBUG` on non-test files
  - BR-3 (high): `public private(set)` whose docstring mentions "test"/"verify"/"spy"
  - BR-4 (high): new init params on `AppContainer` or `*Container.swift`
  - BR-5 (medium): `let _ = fn(...)` discard without `// TODO(ticket):` justification
- Output: `file:line: severity: description`. Exit 1 on any HIGH.
- Flags: `--diff <file>`, `--quiet`, `--severity-floor <low|medium|high>`, `--no-block`.
- KNOWN-BAD: wave 4 pre-cleanup had `authenticateCallCount` as `public private(set)` test-only — must report BR-3 high.
- KNOWN-GOOD: post-cleanup version with `internal private(set)`. Exit 0.

### `scripts/check-adjacency-staleness.py`
- For every removed/renamed type in diff (regex `^-\s*(class|struct|enum|protocol|func)\s+(\w+)`), grep surviving codebase COMMENTS for old name.
- Warn-only (always exit 0).
- Skip `Carthage/`, `Pods/`, `ios-audiobooktoolkit/`, `.forgeos/wall-failures/`, `.forgeos/swarms/`.
- KNOWN-BAD: wave 4 pre-cleanup state where `SignInModalHostingController` rename left 4 doc-comment refs stale. Must report 4 warnings.

### `scripts/check-intent-recorded.py`
- Counts added prod LOC under `Palace/` (excludes `PalaceTests/`, `scripts/`, `.forgeos/`).
- If ≥10 prod LOC: require `.forgeos/intent/<name>.md` matching staged commit subject (≥4 consecutive token match).
- Parse frontmatter: `name`, `created`, `author` required. Body sections required: `## Claims`, `## Anti-claims`, `## Files in scope`.
- Flags: `--diff <file>`, `--commit-msg <file>`, `--threshold-loc <N>` (default 10), `--intent-dir <path>`.
- KNOWN-BAD: wave 4 pre-cleanup had ≥10 prod LOC and no intent file. Exit 1.

## Companion test harnesses (4 files)

`scripts/test_check_<name>.py` for each. Each runs the script via subprocess against KNOWN-BAD + KNOWN-GOOD fixtures. Exit 0 if both behave as expected; exit 1 otherwise.

Fixtures live in `scripts/_fixtures/m1/`:
- `wave4-pre-cleanup.diff` (extracted from `git diff 830ed1c2a..a6f60dbf2^`)
- `wave4-final.diff` (extracted from `git diff 830ed1c2a..a6f60dbf2`)
- `intent-good.md` (hand-rolled valid intent file)
- `intent-missing.md` (intent file with missing required sections)

## Constraints

- stdlib only; no `pip install`.
- Each script ≤500 LOC (target ≤400). Existing `scripts/check-test-name-vs-body.py` is 431 LOC — that's the benchmark.
- Match the style of `scripts/check-test-name-vs-body.py`, `scripts/palace_mutate.py`, `scripts/resolve-tests-for.py`.
- `#!/usr/bin/env python3` shebang + `chmod +x`.
- Helpers prefixed `_` (module-private); only `main()` is public entry.

## Files OFF-LIMITS

- All `Palace/*.swift` (production code untouched)
- `PalaceTests/*.swift` (test code untouched)
- `.claude/agents/*` (Module B owns)
- `.claude/skills/*` (Module B/C own)
- `CLAUDE.md` (Module C owns)
- `scripts/verify-pr.sh`, `scripts/git-hooks/pre-commit` (Module C owns)

## Definition of Done (paste in transcript)

1. SUT instantiation — each test harness `subprocess.run(["python3", "scripts/check-*.py", ...])` ≥1.
2. Function-result usage — every subprocess call binds `result.returncode` and asserts.
3. Multi-step body — each test harness has BOTH KNOWN-BAD and KNOWN-GOOD case + assertions.
4. Scope coverage audit — 4 scripts × ≥2 fixtures each + companion test harnesses.
5. Mutation pass — each test harness's KNOWN-BAD failure assertion IS the equivalent of mutation testing for Python.
6. Build — `python3 -m py_compile scripts/check-*.py` clean; each script's `--quiet --dry-run` exits 0 on wave 4 final cleanup commit.
7. Wiring-claim check (N/A — no Swift production).

## Implementer prompt

You are implementer for Module A of swarm_M1_83be56fc. cd to `/Users/mauricework/PalaceProject/ios-core/.claude/worktrees/swarm_M1_83be56fc-A-universal-rigor-scripts`. Read this contract + plan.md + CLAUDE.md + `/tmp/wave-M1-A-prelude.md`. Build the 4 scripts + 4 test harnesses + 4 fixtures listed above. stdlib only. Each script ≤500 LOC. Match the style of existing `scripts/check-test-name-vs-body.py`. Fixtures: extract from `git diff` of wave 4 commits (the wave 4 worktree is at `/Users/mauricework/PalaceProject/ios-core/.claude/worktrees/swarm_d8f11437-orchestrator` — read its history with `git -C <path> log` and `git -C <path> diff`). Each script must pass BOTH its KNOWN-BAD and KNOWN-GOOD test cases. Do NOT touch Palace/, PalaceTests/, .claude/, CLAUDE.md, or verify-pr.sh — Module B and Module C own those. Paste all 7 DoD checks in transcript before READY. If a script grows past 500 LOC, STOP with BLOCKED + scope-deferral.
