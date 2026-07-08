---
name: clean-code
description: Audit staged or branch-scoped code for clean-code violations before commit/PR — DRY/duplication, dead code, premature abstraction, fluff tests, banned patterns (force unwraps, GCD where async exists, useless comments), and copy-paste drift. Use when about to commit code, when the harness pre-commit hook reports findings, when a subagent finishes an implementation, when the user says "clean code review", "check for duplication", "review my diff", "is this clean", or whenever you've just written non-trivial code and want a second pass. Auto-invoked by the pre-commit hook when static detectors find candidates.
tools: Bash, Read, Edit, Grep, Glob, Agent
---

# /clean-code — production-code hygiene review

You audit the in-flight code for clean-code violations and (when authorized) fix the obvious ones. Designed to be invoked **before** committing — by the main agent, by subagents, or by the harness pre-commit hook flagging static-detector findings.

Your judgment matters here. The static detectors catch literal patterns; you catch the things that need a reader to interpret intent (premature abstraction, fluff tests, useless comments). Be honest. Approving sloppy code defeats the purpose.

## When invoked

The user (or a hook) wants a clean-code review of pending changes. You have to determine SCOPE and APPLY the project's conventions.

## 1. Scope the diff

Determine what code to review. In order of preference:
1. **User-specified files/PR** (e.g. "review PalaceCatalog/CatalogVM.swift").
2. **Staged changes** — `git diff --cached --name-only` if non-empty. This is the most common case (invoked at commit time).
3. **Branch vs base** — `git diff origin/develop...HEAD --name-only` (or `origin/main` if no `develop`). Use when nothing is staged but the user wants a pre-PR review.
4. **Working tree** — `git diff --name-only` (unstaged) as a last resort.

Filter to source code: skip `*.md`, `*.json` lock files, `*.pbxproj`, generated code, vendored dependencies. For Palace iOS specifically: only `Palace/**/*.swift`, `Palace/**/*.m`, `PalaceTests/**/*.swift`.

Read the full files for context, not just the diff hunks — DRY/duplication checks need surrounding code.

## 2. Load project conventions

Before judging, read what THIS project considers clean:
- `CLAUDE.md` — project-level rules (the Palace iOS one has hard rules: no force unwraps, banned test patterns, no comments-without-why, no safety-net fallbacks, etc.)
- `.swiftlint.yml` or equivalent linter config — already-codified rules
- `MEMORY.md` and any linked `feedback_*.md` entries about code style — these are the user's *learned* preferences ("don't reflexively make services final", "Swift concurrency, not GCD hybrids", etc.)

Apply the project's rules as primary; fall back to the general principles below only where the project is silent.

## 3. Audit categories

For each changed file, evaluate against these categories. Cite **file:line** for every finding.

### A. Duplication (DRY)
- **Literal copy-paste**: identical or near-identical blocks ≥5 lines repeated in the diff or between the diff and existing code. Use `grep -rn` to check whether new code re-implements something that already exists in the codebase.
- **Structural duplication**: same shape with different names (e.g. two parsers that differ only in the type they construct). Suggest a generic helper *only when* there are ≥3 sites and the abstraction is obvious — per the system prompt: "Three similar lines is better than a premature abstraction."
- **Re-implementing stdlib / existing helpers**: e.g. hand-rolling `compactMap`, re-deriving a `URLSession` extension that already exists in `Utilities/`.

### B. Premature abstraction
- Single-use helpers/protocols/extensions introduced "just in case."
- Single-implementation protocols with no test seam justification.
- Generic types/functions with only one call site.
- Factory/builder/strategy for one product.
- New layer of indirection that doesn't unlock anything.

When you flag this, propose **inlining** the abstraction back into its caller.

### C. Dead code & half-finished work
- Functions/types defined but unused.
- TODO/FIXME left in the diff (call out and ask the user to file a ticket or finish).
- Commented-out code blocks.
- Half-built feature branches landed: variable assigned but never used, parameter that's always `nil` at call sites, enum case never produced.
- "Removed for X" stub comments where the code is actually deleted.

### D. Comments that don't earn their keep
Per the system prompt: comments only when the WHY is non-obvious. Flag:
- Comments that restate WHAT (`// increment i` next to `i += 1`).
- Comments referencing tickets / PRs / "the new flow" (rot fast; belongs in commit/PR body).
- Doc comments on private helpers whose name already says it.
- Multi-line block comments on something a one-liner could cover.

Don't flag: comments explaining a workaround, a non-obvious invariant, a constraint imposed by an external system, or a subtle ordering requirement.

### E. Test quality (when reviewing test files)
Apply the project's banned-test-pattern rules. For Palace iOS, that includes:
- Set-then-assert (`vm.x = 5; XCTAssertEqual(vm.x, 5)`).
- `XCTAssertNotNil(MyClass())` / `XCTAssertNotNil(Singleton.shared)`.
- Enum-raw-value assertions.
- Tautologies (`x == x`, `x is Type`).
- Tests with no Act step.
- Coverage-only tests for fire-and-forget lines.

For non-trivial tests, ask the **mutation question**: if you flipped a conditional, negated a return, or swapped `+=` for `-=` in the prod code this test covers, would the test fail? If no, it's fluff — propose either a real assertion or deletion.

For **state-machine wiring code** (any diff that writes to a state machine via `_setState`, `setState`, reducer action dispatch, or a setter that writes a terminal state), also ask the **round-trip question**: "is there a test that exercises the full lifecycle (write → reset → re-enter) through the production seam, not via direct `_setState` shortcuts?" If the only tests prove individual transitions in isolation, flag the diff for a missing round-trip test — terminals that can be re-entered MUST be proven recoverable via the public driver. When a terminal enum case carries two meanings (e.g. real-failure AND eviction-marker), require an explicit test pinning each meaning and a third test proving consumers disambiguate them. See the project's `CLAUDE.md` for the canonical example (Palace iOS pins this in § "State-machine wiring tests must exercise round-trips").

### F. Forbidden patterns (project-specific)
Pull from `CLAUDE.md` and memory. For Palace iOS, hard-blocks:
- **Force unwraps** (`!` operator on optionals in production code — `as!` and `try!` count too). `!=` and `!boolVar` are fine.
- **GCD where Swift concurrency would do** (e.g. new `DispatchQueue.main.async { … }` in a file that already uses `await`/`@MainActor`).
- **`print()` / `NSLog` in production code** (use the project's logger).
- **`Singleton.shared` access in tests** (must inject via protocol).
- **`final` on new services that need spy subclasses** (the team's explicit preference — see `feedback_dont_make_new_services_final.md`).
- **Safety-net fallbacks in migrations** (strip legacy API first).

### G. Over-engineering / scope drift
Per the system prompt: "Don't add features, refactor, or introduce abstractions beyond what the task requires." Flag:
- Refactors smuggled into bug fixes.
- New error-handling branches for impossible states.
- Backwards-compatibility shims when the code could just be updated.
- Feature flags for hypothetical futures.
- Defensive validation of internally-trusted inputs.

### H. Naming & readability
- Names that lie (a `cache` that doesn't cache, a `validate` that mutates).
- Single-letter or cryptic names outside tight loops.
- Inconsistent terminology with the surrounding module.

### I. Reuse opportunities missed
Before approving a chunk that looks "new," `grep` the codebase for the same concept. If `TPPNetworkExecutor` already does what the new code does, the new code shouldn't exist.

### J. Skeptic-pass greps — MANDATORY (run literally)

These are derived from wall-failure catalogs (`.forgeos/wall-failures/` in projects that have them — Palace iOS does as of PR #1018). Each grep catches a class of "looks correct but isn't" failure that the other categories miss. Run them on every diff. Block on FAIL.

**J1. SUT instantiation in named test files** (catches fake-test-instantiation — when a test class names a service it never constructs)

```bash
git diff --cached --name-only | grep -E "^.*Tests?/.*Tests?\.swift$|.*tests?/.*test.*\.(py|ts|js)$" | while read testfile; do
  testbase=$(basename "$testfile" | sed -E 's/\.[a-z]+$//')
  # Strip common suffixes — extend per project
  sut=$(echo "$testbase" | sed -E 's/(AuthCoordinator|Telemetry|Reauth|Wiring|Registration|Coordinator|Property|Persistence|StateMachine|Lifecycle|Regression|Mutation)Tests?$//' | sed -E 's/Tests?$//' | sed -E 's/^Test//')
  if [ -z "$sut" ]; then continue; fi
  count=$(grep -c "${sut}(" "$testfile" 2>/dev/null || echo 0)
  if [ "$count" -eq 0 ]; then
    echo "FAIL J1: $testfile names $sut but never instantiates it"
  fi
done
```

If FAIL: rewrite the test to instantiate the SUT, OR rename the test file to reflect what it actually tests. Don't ship a test claiming to verify a service it never touches.

**J2. Function-result usage in new production calls** (catches dishonest migrations — when new function is called but its outcome is discarded while legacy code still runs)

For each `+` line in the diff that adds a call to a function added in this PR or contracted as a migration target:
- Bound (`let x = fn(...)`), pattern-matched (`if case .x = fn(...)`), returned, or asserted — OK.
- Discarded (`_ = fn(...)`, `Log.info("\(fn(...))")`) — FAIL unless documented with `// TODO(ticket): result intentionally discarded because <reason>`.

Concrete grep for the most common pattern (PR #1018 arch3):
```bash
git diff --cached -U0 | \
  grep -E "^\+.*let _ = .*\(|^\+.*Log\.(info|debug|trace)\(.*\(.*\)" | \
  grep -v "// TODO" && echo "FAIL J2: discarded call result without rationale"
```

**J3. Multi-step test body proves multi-step name** (catches half-done tests — where the name claims `_across`/`_twice`/`_roundtrip` but the body has the second half in comments)

For every test name in the diff containing `across`, `twice`, `reset`, `retry`, `again`, `roundtrip`, `inProduction`, `viaX`: read the body. It must literally do each step the name claims. ≥2 driver calls. ≥2 assertions on the multi-step path. If half the steps are commented out → FAIL.

```bash
git diff --cached -U500 | \
  awk '/^\+.*func test.*_(across|twice|reset|retry|again|roundtrip|inProduction|via[A-Z])/,/^\+.*\}/' | \
  cat  # human inspection — surface candidates, you confirm honesty
```

**J4. Scope-deferral protocol compliance** (catches silent partial-shipping)

If the diff is partial relative to the user's original task, the commit body MUST include a `**Scope:**` / `**Not done:**` / `**Deferred:**` stanza. The harness pre-commit hook enforces this for ≥50 prod LOC; J4 reinforces for smaller diffs that are still task-partial.

```bash
# For any task-partial diff: check that the commit body has the deferral stanza
git log -1 --format=%B 2>/dev/null | grep -E "\*\*(Scope|Not done|Deferred):\*\*" || \
  echo "WARN J4: no scope-stanza — only acceptable if the diff is the complete task scope"
```

**J5. Mutation evidence for critical-path changes** (catches the half-done test that mutation would have killed if it'd been run)

If the diff touches a critical path (project-specific — Palace iOS examples: `Palace/Audiobooks/`, `Palace/SignInLogic/`, `Palace/MyBooks/Download*`, `Palace/Packages/PalaceAuth/`), the commit body or PR description must paste a mutation kill rate from `palace_mutate.py --diff-only` (or the project's equivalent).

```bash
git diff --cached --name-only | grep -E "<critical-path-pattern>" && \
  git log -1 --format=%B 2>/dev/null | grep -iE "mutation|kill.*rate" || \
  echo "WARN J5: critical-path change without mutation evidence"
```

These greps mirror the swarm Phase 4.5 skeptic pass — they're applied here so single-agent commits get the same protection regardless of whether the work came through /swarm.

### J.5 Universal rigor scripts (M1 floor)

Run before declaring audit complete. These are the universal floor — every diff, regardless of size or path, passes through them. They wrap the wave-1-4 manual-review findings into machine-checkable form so single-agent commits get the same protection /swarm and /rigorous-fix get.

```bash
python3 scripts/check-contract-reconciliation.py --quiet ; CR_EXIT=$?
python3 scripts/check-blast-radius.py --quiet            ; BR_EXIT=$?
python3 scripts/check-adjacency-staleness.py --quiet     ; AS_EXIT=$?
python3 scripts/check-intent-recorded.py --quiet         ; IR_EXIT=$?
```

Block-on-FAIL rules (exit 1 means a real finding):
- `check-contract-reconciliation.py` exit 1 → **BLOCK**. The diff doesn't deliver what the commit/PR body / contract claims.
- `check-blast-radius.py` exit 1 → **BLOCK**. New public API surface, `#if DEBUG` on production paths, test-only AppContainer init params, or discarded function results without `// TODO(ticket):` justification.
- `check-adjacency-staleness.py` exit 1 → **WARN-ONLY**. Adjacent docs/tests stale relative to the change; surface to user but don't block.
- `check-intent-recorded.py` exit 1 → **BLOCK only when added prod-LOC ≥ 10**. Smaller diffs skip the intent requirement.

For diffs ≥10 prod LOC under `Palace/`, also spawn the `forge-blast-radius-reviewer` agent as an advisory pass (no SoD denial — /clean-code is single-author, the reviewer is read-only). Use `Agent` with `subagent_type: "forge-blast-radius-reviewer"` and pass the changeset / branch / worktree inputs from the current session. Read the verdict; if BLOCKED, surface the top finding alongside your own audit summary.

This `J.5` floor was added 2026-05-28 as the universal-rigor remediation derived from waves 1-4 (M1 swarm `swarm_M1_83be56fc`). Without it, every commit went through /clean-code's J1-J5 greps but the 4 wave-derived scripts and the blast-radius reviewer ran only when the author opted into /swarm or /rigorous-fix.

## 4. Report

Output a structured report ≤ 400 words:

```
Clean-code review — <scope summary, e.g. "12 files, 480 LOC staged">

Blockers (must fix before commit):
  - <file:line> — <category> — <one-line description> — <fix recipe>
  ...

Concerns (judgment call; recommend fixing):
  - <file:line> — <category> — <one-line description> — <fix recipe>
  ...

Nits (optional):
  - <file:line> — <one-line>
  ...

Verdict: APPROVED / APPROVED_WITH_CONCERNS / BLOCKED
Next: <concrete action — e.g. "Fix 2 blockers, re-run /clean-code, then re-commit.">
```

**Severity guide:**
- **Blocker** — hard project rule (force unwrap, fluff test in critical-path file, banned pattern), OR duplicated logic where the existing helper is obvious and the duplication will rot.
- **Concern** — judgment call where the user might reasonably disagree (premature abstraction, comment-style, naming). Surface it but don't block.
- **Nit** — style preference with low rot risk.

If the diff is small/clean, say so plainly: "Reviewed 3 files / 47 LOC. Clean — no blockers, no concerns. Approved."

## 5. Fixing

If the user invoked you and the violations are mechanical (force unwrap → guard let, useless comment → delete, fluff test → delete), **offer to fix and apply with Edit** for blockers and clear-cut concerns. For judgment calls (premature abstraction, naming), describe the fix and let the user decide.

Never silently rewrite logic — only mechanical transforms. If you'd need to reshape behavior, propose the change and stop.

## When invoked by the pre-commit hook

The hook calls you with a pre-computed list of static-detector hits in stderr (force unwraps, banned patterns, large duplication blocks). Treat those as **seeds** for your audit, not the final list — the hook can't see premature abstraction or fluff. Read the staged diff, do the full audit above, and report.

If the hook blocked the commit and your audit confirms blockers exist, fix or delegate; then re-run `git commit`. If your audit clears the static-detector hits (false positives — e.g. `!` is in a doc comment), report that to the user and re-attempt the commit explicitly (don't `--no-verify`; the hook will accept once the offending lines are no longer in the diff).

## Anti-patterns (don't do these)

- **Don't rubber-stamp.** If the only thing you can find is a typo, look harder — there are usually 2-3 real findings in any non-trivial diff, and surfacing nothing means you didn't read carefully.
- **Don't invent rules the project doesn't have.** If `CLAUDE.md` is silent on, say, line length, don't enforce a 80-col rule. Apply written rules first, general principles second.
- **Don't block on style preferences.** Severity discipline matters — if everything is a blocker, nothing is.
- **Don't run inside the commit.** The hook gates the commit; you audit. Don't try to bypass the hook with `--no-verify`.
- **Don't drift into design review.** If the diff implements a feature in a working way, audit the code; don't second-guess the feature design unless it's actively broken.

## Example

User: `/clean-code`

You:
1. `git diff --cached --name-only` → 4 staged Swift files in `Palace/MyBooks/`.
2. Read CLAUDE.md (no force unwraps, banned test patterns) + the 4 files.
3. Audit: find 1 force unwrap (blocker), 1 single-call helper `formatBookTitle()` (concern: inline candidate), 1 set-then-assert test (blocker), 1 comment `// fetches the book` above `func fetchBook()` (nit).
4. Report blockers + offer to fix.
5. User approves fixes → apply Edits, re-run `git commit` (the pre-commit hook will pass once the lines are gone).
