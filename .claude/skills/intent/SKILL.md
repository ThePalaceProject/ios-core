---
name: intent
description: Record a structured intent file (`.forgeos/intent/<name>.md`) BEFORE writing code for any change that adds ≥10 prod LOC under `Palace/`, touches a critical-path file (sign-in/auth/borrow/return/download/DRM/audiobooks/migrations/TPPNetworkExecutor/TPPNetworkResponder), or kicks off a `/swarm` or `/rigorous-fix` run. The intent file pins your Claims, Anti-claims, and Files-in-scope so the M1 contract-reconciliation gate (`scripts/check-contract-reconciliation.py`), the M1 intent-recorded gate (`scripts/check-intent-recorded.py`), and the universal pre-commit hook can verify the diff matches what you said you'd do. Invoke via "/intent <slug>" or whenever the user says "let's plan this first", "record the intent", "draft an intent file", "before we change code, write the plan", or whenever you (the agent) are about to start a ≥10 prod-LOC change.
tools: Bash, Read, Write, Edit
---

# /intent — record what you're about to do, BEFORE you do it

You write a `.forgeos/intent/<name>.md` file that pins the user-visible contract of a change BEFORE any code lands. The intent file is then:

1. Reconciled against the staged diff by `scripts/check-contract-reconciliation.py` at pre-commit time + in `scripts/verify-pr.sh`.
2. Required by `scripts/check-intent-recorded.py` for any diff adding ≥10 prod LOC under `Palace/`.
3. Cited by the M1 floor block in `scripts/git-hooks/pre-commit`, which always-blocks on critical-path files when the intent is missing/invalid.

Without an intent file, the universal-rigor floor refuses to let the commit land for any non-trivial work.

## When to invoke

Mandatory:
- Any change adding ≥10 prod-LOC under `Palace/` (the threshold in `check-intent-recorded.py`).
- Any change touching a critical-path file regardless of LOC count — sign-in, auth, borrow, return, download, DRM, audiobooks, migrations, TPPNetworkExecutor, TPPNetworkResponder.
- Any `/swarm` or `/rigorous-fix` dispatch — the intent file is the architect's hand-off to implementers.

Recommended:
- Any refactor that renames or removes a public type (so the adjacency-staleness scan can reconcile your intent against any stale comments it finds).
- Any change you'd describe in commit body language using "removes X" / "deletes X" / "migrates Y to Z" / "renames X to Y" / "adds field A to type B" — those are the exact claim grammars the reconciler keys on.

Skip:
- <10 prod-LOC, non-critical-path bugfixes (the M1 floor degrades to warn-only).
- Pure docs / README / `*.md` edits (no behavioral risk).
- pbxproj / Carthage / SPM lock changes (mechanical, not behavioral).

## Process

### 0. Check for existing ADRs in the touched areas (MANDATORY since 2026-06-03 v3 ADR ledger)

Before drafting the intent, query the ForgeOS ADR ledger for each module the change will touch. Even an approximate module list is fine — refine after step 1 if needed.

```bash
# For each module the change will touch:
python3 -c "
import sys, subprocess, json
# Use the MCP via the agent, or hit the engine HTTP API directly
"
```

In practice: call `mcp__forgeos__forge_list_adrs(project_id=proj_87884c17, area=<module>)` for each likely area. For Palace iOS the common area names are: `architecture`, `audiobooks`, `accounts`, `release`, `governance`, `testing`.

For every ADR returned, read its `decision`, `context`, and `consequences`. Decide which of three categories your change falls into:

1. **Extends an existing ADR.** The change implements or refines a prior decision. Note the relevant `adr_id`(s) in your intent file under a new `**ADR refs:**` line at the top of the body.
2. **Narrows or scope-shifts an existing ADR.** The change deliberately reduces or shifts an ADR's scope without invalidating it (e.g., the ADR said "do this everywhere"; you're doing it in 5 of 7 sites and deferring the rest). Document the deferral in Anti-claims AND under a `**ADR refs:**` line.
3. **Contradicts or supersedes an existing ADR.** The change reverses or replaces a prior decision. This is a hard stop:
   - You MUST add a new `## Decision reversal` section to the intent file that explicitly names the ADR being superseded and explains why the prior reasoning no longer holds.
   - You MUST commit to submitting a new ADR via `forge_submit_evidence(type="architecture_decision", metadata.supersedes=<old_adr_id>)` as part of the change — record this as a Claim in the intent.
   - The architect-reviewer will block the PR if you contradict an ADR without superseding it explicitly.

If `forge_list_adrs` returns zero results for every queried area, note it under `**ADR refs:**` as `none — no prior decisions recorded for the touched areas`. That's a valid outcome; just don't skip the check.

### 1. Resolve the intent file path

Pick a slug describing the change:
- `<feature>-<verb>` — `signin-modal-extraction`, `book-return-retry-fix`
- `<area>-<scope>` — `audiobooks-loader-cleanup`
- For swarm work, mirror the swarm id: `swarm-<id>-<short-name>`

Write to `.forgeos/intent/<slug>.md`. The directory exists; create it if not.

### 2. Required frontmatter

```yaml
---
name: <slug>           # MUST match commit subject (the reconciler matches against this)
created: YYYY-MM-DD    # today's date
author: <agent-id>     # e.g. claude-opus-4-7, or a human handle
---
```

The `name:` field is matched against the commit-message subject line by `check-intent-recorded.py`. Pick a slug you can use verbatim in the commit subject.

### 3. Required body sections

The reconciler keys on three section headings — these are non-negotiable:

```markdown
## Claims

- adds field `<file or symbol>`
- removes `<file or symbol>`
- migrates `<old API>` to `<new API>`
- renames `<old name>` to `<new name>`
- adds public function `<signature>` on `<type>`

## Anti-claims

- does NOT touch `<area you're explicitly preserving>`
- does NOT modify `<file you're not changing>`
- does NOT change public surface of `<type whose API stays fixed>`

## Files in scope

- Palace/Foo/Bar.swift
- PalaceTests/Foo/BarTests.swift
- (etc — one path per line, ungrouped)
```

The **Claims** section is the primary reconciler input. Each bullet should use one of the recognized verbs (`adds`, `removes`, `deletes`, `migrates`, `renames`) so the reconciler can parse it into a check against the diff. Free-form prose is fine as long as the verb is present.

The **Anti-claims** section is your guard against scope creep. The blast-radius scanner and the architect reviewer will flag a diff that touches anti-claimed areas. Use it to make load-bearing promises about what you're NOT changing.

The **Files in scope** section is the explicit allow-list. The intent-recorded gate parses this and warns if the staged diff touches files outside the list (unless you update the intent first).

### 4. Write the intent BEFORE coding

The whole point is that the intent constrains the implementation. If you write the intent after the code, you'll just describe the code you already wrote — that's a retro, not an intent. Write the intent, get the human's nod, then implement against it.

If the implementation forces a change to the intent (you discover a hidden dependency, a contract gap, etc.), STOP and update the intent file with a brief commit before continuing. The diff will then reconcile cleanly.

### 5. Validate before staging

Run the reconciler against your in-flight diff to confirm:

```bash
git diff > /tmp/diff.txt
python3 scripts/check-contract-reconciliation.py \
  --intent .forgeos/intent/<slug>.md \
  --diff /tmp/diff.txt
echo "exit=$?"
```

Exit 0 means every claim in your intent is supported by a corresponding change in the diff. Non-zero means either:
- A claim is missing from the diff (you said "removes X" but the diff still has X), or
- A claim is malformed (the verb didn't parse — rewrite using a recognized grammar).

The intent-recorded gate runs separately:

```bash
python3 scripts/check-intent-recorded.py --diff /tmp/diff.txt
echo "exit=$?"
```

Exit 0 means an intent file exists at `.forgeos/intent/<slug>.md`, has the required frontmatter, and has the three required body sections. Non-zero means it's missing or invalid.

## Examples

### Minimal — single-file bugfix

```markdown
---
name: oauth-callback-retry-timeout
created: 2026-05-28
author: claude-opus-4-7
---

## Claims

- adds field `retryTimeoutSeconds` to `OAuthCallbackHandler` (default 30)
- changes `OAuthCallbackHandler.handle(_:)` to honor the new timeout

## Anti-claims

- does NOT change `OAuthCallbackHandler`'s public init signature
- does NOT touch SAML or basic-auth callback paths

## Files in scope

- Palace/SignInLogic/OAuthCallbackHandler.swift
- PalaceTests/SignInLogic/OAuthCallbackHandlerTests.swift
```

### Swarm — multi-module refactor

```markdown
---
name: swarm-abc12345-extract-borrow-reducer
created: 2026-05-28
author: forge-architect
---

## Claims

- adds field `BorrowReducer` as new pure reducer in `Palace/MyBooks/Borrow/`
- migrates `BorrowOperation.run()` to delegate state transitions to `BorrowReducer`
- removes inline `if`-branch state machine from `BookButtonMapper.swift`
- renames `BorrowOperation.startDownload(book:)` to `BorrowOperation.dispatch(action:)`

## Anti-claims

- does NOT change `TPPBookRegistry` public surface
- does NOT modify download or return flows
- does NOT add any new public init params on `AppContainer`

## Files in scope

- Palace/MyBooks/Borrow/BorrowOperation.swift
- Palace/MyBooks/Borrow/BorrowReducer.swift
- Palace/Book/UI/BookDetail/BookButtonMapper.swift
- PalaceTests/MyBooks/Borrow/BorrowReducerTests.swift
- PalaceTests/MyBooks/Borrow/BorrowOperationContractTests.swift
```

## Interaction with the M1 universal-rigor floor

| Surface | What it checks |
|---|---|
| `scripts/check-intent-recorded.py` | Intent file exists + frontmatter + sections + name matches commit |
| `scripts/check-contract-reconciliation.py` | Every claim is supported by the diff |
| `scripts/check-blast-radius.py` | Diff doesn't violate anti-claims (new public surface, `#if DEBUG` prod-reach, etc.) |
| `scripts/check-adjacency-staleness.py` | Comments don't drift from rename/remove claims |
| `scripts/git-hooks/pre-commit` (M1 block) | Runs the 4 scripts above and escalates by risk |
| `scripts/verify-pr.sh` (4 gates) | Same 4 scripts in the pre-PR battery |

If your intent file passes all four scripts AND the diff matches the intent, the universal-rigor floor will let the commit land without further intervention. If anything fails, fix the cause — do not `--no-verify` unless it's a real emergency with a rationale in the commit body.

## See also

- `.forgeos/intent/` — existing intent files (browse for examples)
- `CLAUDE.md` "Definition of Done" #8 / #9 / #10 — the cited DoD checks
- `.forgeos/swarms/swarm_M1_83be56fc/` — the swarm that introduced this skill
- `.forgeos/wall-failures/` — the cluster of findings that drove this work
