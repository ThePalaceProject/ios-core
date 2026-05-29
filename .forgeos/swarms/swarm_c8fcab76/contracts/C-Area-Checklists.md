# Module C — Per-area Verification Checklists (DOCS ONLY)

**Standard rigor.** This module is documentation-only.

## Goal

Land three per-area verification checklists modeled after the auth area's checklist (`docs/architecture/areas/auth/verification-checklist.md`, landed in PR #1019). Each checklist gives a critical-path area a single, scannable, grep-able document that a reviewer can use to verify "is this PR safe to land in <area>?" without re-walking the entire memory + audit corpus.

## What public types/protocols change

**NONE.** This module is docs-only. **NO `.swift` file may be touched.** No `.pbxproj` edits. No tests.

## What internal seams (DI protocols) need updating

None.

## Test contracts the module must satisfy

No test contracts (docs-only). However, the module MUST:

- Pass `python3 scripts/audit-before-assert.py` (the audit-before-assert hook). For factual claims about Palace code, include the `<!-- audit-verified -->` HTML comment marker on the same paragraph or line block, with the grep that supports the claim immediately after the comment. **If `audit-before-assert.py` does not exist on the current branch (it landed in PR #1019 alongside the auth checklist template), the implementer must:**
  1. Confirm presence with `test -f scripts/audit-before-assert.py`.
  2. If absent: SKIP the audit-before-assert pass and instead manually validate each factual claim with a grep paste in the checklist file's PR description. Flag the absence to the orchestrator.
  3. If present: run it against each of the three new files.

- **Template fidelity.** If `docs/architecture/areas/auth/verification-checklist.md` exists at branch base, the three new checklists MUST mirror its structure section-for-section. Diff the resulting files against the auth checklist; sections should be the same headings + similar ordering, with content swapped to the relevant area. If the auth checklist does NOT exist at branch base (per architect's pre-flight: it doesn't), the implementer must **first port** the auth checklist as the template by reading it from PR #1019's branch (or, if unreachable, derive a minimal template from `docs/architecture/README.md` + the existing audit/memory corpus and document the deviation in the swarm transcript).

## Files scoped to THIS implementer (exclusive write)

New files:
- `docs/architecture/areas/mybooks/verification-checklist.md`
- `docs/architecture/areas/audiobook/verification-checklist.md`
- `docs/architecture/areas/accounts/verification-checklist.md`

MAY ALSO touch (read-only or directory-creation):
- `docs/architecture/areas/mybooks/` (NEW directory)
- `docs/architecture/areas/audiobook/` (NEW directory)
- `docs/architecture/areas/accounts/` (NEW directory)

MAY read (read-only) for source material:
- `docs/architecture/areas/auth/verification-checklist.md` (template — DO NOT MODIFY)
- `docs/architecture/audiobook-systemic-overhaul.md`
- `docs/architecture/account-state-machine.md`
- `docs/architecture/critical-path-mutation-coverage.md`
- `docs/architecture/README.md`
- `.forgeos/contracts/Audiobooks.json`, `MyBooks.json`, `Accounts.json` (the per-module contract snapshots)
- `~/.claude/projects/-Users-mauricework-PalaceProject-ios-core/memory/` — all `reference_*` and `feedback_*` pins relevant to each area
- All `Palace/Audiobooks/*.swift`, `Palace/MyBooks/*.swift`, `Palace/Accounts/*.swift` for grep-source fact-checking. **Read-only — must not modify.**

## Files explicitly OFF-LIMITS

**ABSOLUTE — Module C is docs-only:**

- ALL `.swift` files in the repo (read-only for grep-source only — never modified, including for typo fixes; flag those to the orchestrator).
- ALL `Palace.xcodeproj/*` files.
- ALL `PalaceTests/**/*`.
- `scripts/**/*` (read-only; don't modify even the audit-before-assert.py hook).
- `docs/architecture/areas/auth/verification-checklist.md` (template — read-only).
- `Palace/SignInLogic/`, `Palace/Packages/PalaceAuth/`, `Palace/Accounts/Library/AccountsManager.swift`, `Palace/Accounts/Account+State.swift`, `Palace/Accounts/AccountStateStore.swift` (anti-scope — even though the **accounts** checklist describes them, this module MUST NOT modify them).

**Off-limits per swarm overlap resolution:**
- All Module A scope (Palace/Audiobooks, PalaceTests/Audiobooks).
- All Module B scope (BookButtonMapper, Download tests).
- All Module D scope (PalaceTests/<area> matchers).

## Verification criteria (MANDATORY — grep-able assertions)

1. **All three checklist files exist:**
   ```bash
   test -f docs/architecture/areas/mybooks/verification-checklist.md && \
   test -f docs/architecture/areas/audiobook/verification-checklist.md && \
   test -f docs/architecture/areas/accounts/verification-checklist.md && echo OK
   ```
   MUST print `OK`.

2. **NO Swift files modified (docs-only invariant):**
   ```bash
   git diff --name-only origin/develop | grep -E '\.swift$|\.pbxproj$|\.m$|\.h$|\.py$|\.sh$|\.rb$'
   ```
   MUST be empty.

3. **All three files end in `.md` and live under `docs/architecture/areas/`:**
   ```bash
   git diff --name-only origin/develop -- 'docs/**' | grep -vE '^docs/architecture/areas/(mybooks|audiobook|accounts)/verification-checklist\.md$'
   ```
   MUST be empty (no out-of-scope doc edits).

4. **`<!-- audit-verified -->` markers present on factual claims (if audit-before-assert exists):**
   ```bash
   grep -c "audit-verified" docs/architecture/areas/mybooks/verification-checklist.md
   grep -c "audit-verified" docs/architecture/areas/audiobook/verification-checklist.md
   grep -c "audit-verified" docs/architecture/areas/accounts/verification-checklist.md
   ```
   Each MUST return ≥3 (the checklists are facts-heavy — minimum three audit-verified blocks per area).

5. **audit-before-assert hook (if present) passes:**
   ```bash
   test -f scripts/audit-before-assert.py && \
     python3 scripts/audit-before-assert.py docs/architecture/areas/mybooks/verification-checklist.md && \
     python3 scripts/audit-before-assert.py docs/architecture/areas/audiobook/verification-checklist.md && \
     python3 scripts/audit-before-assert.py docs/architecture/areas/accounts/verification-checklist.md
   ```
   Each invocation MUST exit 0. If the hook does not exist on this branch, the implementer pastes a manual-grep-verification block in the transcript as fallback.

6. **Anti-scope claim — no edits to deferred-to-wave-2 files (even though they're discussed):**
   ```bash
   git diff --name-only origin/develop -- Palace/SignInLogic/ Palace/Packages/PalaceAuth/ Palace/Accounts/Library/AccountsManager.swift Palace/Accounts/Account+State.swift Palace/Accounts/AccountStateStore.swift
   ```
   MUST be empty.

7. **Cross-reference grep — checklists reference the relevant audits, memory pins, and prior swarm artifacts** (each checklist should cite at least 3 source documents to be load-bearing):
   ```bash
   grep -E '\.forgeos/|reference_|feedback_|docs/architecture/' docs/architecture/areas/mybooks/verification-checklist.md | wc -l
   grep -E '\.forgeos/|reference_|feedback_|docs/architecture/' docs/architecture/areas/audiobook/verification-checklist.md | wc -l
   grep -E '\.forgeos/|reference_|feedback_|docs/architecture/' docs/architecture/areas/accounts/verification-checklist.md | wc -l
   ```
   Each MUST return ≥3.

8. **Template-fidelity check — sections mirror auth checklist:** if `docs/architecture/areas/auth/verification-checklist.md` exists at branch base, the implementer pastes side-by-side `grep -E '^##? ' <auth>` vs `grep -E '^##? ' <new>` output for each area, confirming heading parity. If auth checklist does NOT exist, the implementer notes this in the transcript and uses the template they derived.

## Definition of Done evidence the implementer must paste

1. **All three files exist + line counts >50 each (not stubs):**
   ```bash
   wc -l docs/architecture/areas/{mybooks,audiobook,accounts}/verification-checklist.md
   ```

2. **No Swift / project / script edits** (Verification #2).

3. **audit-before-assert.py clean** (Verification #5) OR manual fallback transcript.

4. **At least 3 audit-verified markers per file** (Verification #4).

5. **At least 3 cross-references per file** (Verification #7).

6. **Template-fidelity grep paste** (Verification #8).

## Mutation kill-rate

N/A — docs-only.

## Implementer prompt (one paragraph)

You are Module C implementer for `swarm_c8fcab76`. Run `~/harness/bin/harness subagent-prelude --domain general` (or `--domain accounts`/`audiobook` for the relevant pass). Your job is to write three verification checklists — one each for MyBooks, Audiobook, and Accounts — modeled after `docs/architecture/areas/auth/verification-checklist.md` (template; landed in PR #1019). Each checklist must (a) cover the area's critical-path invariants, (b) cite at least 3 source documents (audits/memory pins/architectural docs), (c) include grep-able verification commands a reviewer can run against any PR that touches the area, and (d) include `<!-- audit-verified -->` markers on factual claims (the `audit-before-assert.py` hook enforces this; if absent, use manual grep fallback in the transcript). DOCS-ONLY: zero `.swift`/`.pbxproj`/`.py`/`.sh`/`.rb`/`.m`/`.h` files may be modified. If you find a typo in a Swift file while grep-source-checking, flag it to the orchestrator instead of fixing it. DO NOT modify `Palace/SignInLogic/`, `Palace/Packages/PalaceAuth/`, `AccountsManager.swift`, `Account+State.swift`, or `AccountStateStore.swift` — those are anti-scope-deferred even though the **accounts** checklist DOES DESCRIBE them. If the auth template does not exist at branch base, derive a minimal template from `docs/architecture/README.md` + the area's existing memory corpus and document the deviation in your transcript.
