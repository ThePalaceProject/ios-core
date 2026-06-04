---
name: swarm
description: Triage→dispatch→integrate→promote loop for multi-module Palace iOS work. Architect agent identifies touched modules, writes contract deltas, then parallel module-implementer subagents land changes against those contracts. forge-review and verify-pr.sh gate the integration. Use when a feature, refactor, or extraction touches ≥2 top-level Palace modules; for single-module work, do it directly. Invoke via "/swarm <task>" or when the user says "swarm this", "extract X via swarm", "run swarm for...", or asks to coordinate multi-module changes.
tools: Agent, Bash, Read, Write, Edit, mcp__forgeos__forge_propose_changeset, mcp__forgeos__forge_submit_evidence, mcp__forgeos__forge_check_gates, mcp__forgeos__forge_promote_gate, mcp__forgeos__forge_get_context
# doc-lifecycle metadata (added by Module B sweep)
type: evolving
status: active
created: 2026-05-28
last_refresh: 2026-06-03
freshness_window: 365d
owners: [general]
---

# /swarm — multi-module orchestration loop

You orchestrate a triage→dispatch→integrate→promote loop for multi-module Palace iOS changes. The architect agent triages and writes contracts; parallel implementer agents do the work; you (the main agent) integrate and gate.

## When to use

**Use /swarm when**: the task touches ≥2 top-level Palace modules (e.g. `Palace/Audiobooks/` + `Palace/MyBooks/`, or extracting `Palace/SignInLogic/` into a new SPM package which touches SignInLogic + main target callsites + tests).

**Don't use /swarm when**:
- Task touches 1 module — just do it directly. Triage overhead is pure cost.
- Bug fix <50 LOC across files — single-agent is faster.
- The user already wrote a plan; you're executing it.

If unsure: ask the user. Don't swarm a one-line fix.

**Risk-driven bar (overrides the size bar):** any change touching a critical path — `Palace/SignInLogic/`, `Palace/Audiobooks/`, `Palace/MyBooks/Download*`, anything related to auth/borrow/return/DRM/credential storage — gets architect-then-SoD-review rigor regardless of LOC count. For 1-module critical-path work, use the lighter `/rigorous-fix` skill (or `/swarm --solo`) which runs architect + SoD review without parallel implementers. Don't ship a 30-LOC `BookReturnService` change with bare `/clean-code` review.

## Wall-failure catalog integration

When a reviewer BLOCKS during this loop (Phase 5), the finding is a **system bug**, not just an implementer bug. Per `.forgeos/wall-failures/README.md`:

1. Inside 24h of the block, create a wall-failure entry using `.forgeos/wall-failures/TEMPLATE.md`. Name: `YYYY-MM-DD-pr<NNNN>-<short-id>.md`.
2. Classify which wall(s) should have caught it (contract / implementer / TDD / mutation / verify-pr / orchestrator / reviewer / hook).
3. Propose a permanent fix — a contract clause, orchestrator check, implementer constraint, hook addition — that would make the finding **structurally impossible to land**, not "more likely to be noticed."
4. Within 1 week, apply the proposed fix and link the commit/PR back from the entry.

Add a one-line summary to `.forgeos/wall-failures/INDEX.md` for navigability. The cluster pattern in INDEX.md is the input to monthly system-level improvements (see `derived-improvements.md`).

**Why this matters:** without this, the system stays exactly as leaky as it was. The reviewer caught the same finding once; next swarm it could happen again. With it, every block becomes a permanent wall improvement.

## Inputs to gather first

1. **Task description** — from the user's prompt or, if vague, ask once.
2. **Swarm ID** — generate `swarm_<8-char-hex>` (e.g. `swarm_a1b2c3d4`). Use `openssl rand -hex 4`.
3. **Project ID** — from `~/harness/projects/palace-ios.yml` or session-start context (`proj_87884c17`).
4. **Base ref** — default `origin/develop` unless user specifies.

## Artifact tree

Every swarm writes to `.forgeos/swarms/<swarm_id>/`:

```
.forgeos/swarms/swarm_a1b2c3d4/
├── manifest.yaml              # machine-readable state — STATUS FIELD IS A CROSS-SESSION LOCK
├── plan.md                    # human-readable triage output
├── contracts/                 # per-module contract deltas (markdown)
│   ├── SignInLogic.md
│   └── Packages-PalaceAuth.md
├── transcripts/               # per-implementer summaries
│   ├── implementer-1.md
│   └── implementer-2.md
└── outcome.md                 # final integration report
```

These are committed (not gitignored) — they are the audit trail for the changeset. The `status` field in manifest.yaml progresses `triaged → in-flight → bundled → complete`; while it is not `complete`, the pre-destructive-check hook will refuse `git checkout`/`reset --hard`/`clean -fd` that would clobber the orchestrator's branch (see "Cross-session safety" below).

## The loop

### Phase 0: Orchestrator worktree (ALWAYS — do this before anything else)

**Why:** other claude sessions on this same repo can branch-switch, `git clean`, or `reset --hard` in the shared main checkout at any time. Any swarm artifacts you write as untracked files in main are one stray destructive command from being lost (lesson from 2026-05-19). The fix is to NEVER work from main during a swarm — give the orchestrator its own worktree.

```bash
SWARM_ID="swarm_$(openssl rand -hex 4)"
ORCH_WT=".claude/worktrees/${SWARM_ID}-orchestrator"
BASE_REF="${BASE_REF:-origin/develop}"

# Fetch + create worktree on a fresh branch off the base
git fetch origin
git worktree add -b "swarm/${SWARM_ID}-scaffold" "$ORCH_WT" "$BASE_REF"
cd "$ORCH_WT"

# Set up Carthage + submodules per feedback_worktree_palace_setup.md.
#
# CRITICAL: not all submodules can be symlinked.
#   - `ios-audiobooktoolkit` MUST be a real clone (`git submodule update --init`).
#     Its own pbxproj references `../Carthage/Build` — a symlink resolves to
#     MAIN's Carthage path and produces duplicate "ProcessXCFramework" build
#     commands → "Multiple commands produce '.../AudioEngine.framework/...'"
#     errors that surface only on a fresh DerivedData.
#   - `Carthage/Build` is `cp -RL` (NOT a symlink) for the same reason.
#   - Other 7 submodules are safe to symlink.
#   - `adobe-rmsdk` symlinks to the sibling private DRM repo.
#
# Also: submodule `.git` is a FILE (gitdir pointer), not a directory — so
# the existence check is `-e`, not `-d`.
MAIN=$(git -C .. rev-parse --show-toplevel)

# Carthage/Build — copy, do not symlink (~37 MB, ~1s)
mkdir -p Carthage/Build
[ -d "$MAIN/Carthage/Build" ] && cp -RL "$MAIN/Carthage/Build/." Carthage/Build/

# ios-audiobooktoolkit — REAL submodule clone
git submodule update --init -- ios-audiobooktoolkit 2>/dev/null || true

# Other 7 submodules — symlinks are safe
for sub in adept-ios adobe-content-filter ios-audiobook-overdrive \
           ios-tenprintcover mobile-bookmark-spec readium-sdk readium-shared-js; do
  if [ ! -L "$sub" ]; then
    [ -d "$sub" ] && [ -z "$(ls -A "$sub" 2>/dev/null)" ] && rmdir "$sub"
    [ ! -e "$sub" ] && [ -e "$MAIN/$sub/.git" ] && ln -s "$MAIN/$sub" "$sub"
  fi
done

# adobe-rmsdk — external private repo
[ ! -e adobe-rmsdk ] && [ -d /Users/mauricework/PalaceProject/ios-drm-adeptconnector/connector ] && \
  ln -s /Users/mauricework/PalaceProject/ios-drm-adeptconnector/connector adobe-rmsdk

# Gitignored secrets
for f in Palace/AppInfrastructure/APIKeys.swift \
         Palace/TPPSecrets.swift \
         PalaceConfig/GoogleService-Info.plist \
         PalaceConfig/ReaderClientCert.sig; do
  [ -e "$MAIN/$f" ] && [ ! -e "$f" ] && cp "$MAIN/$f" "$f"
done
```

**Naming convention:**
- Worktree path: `.claude/worktrees/<swarm_id>-orchestrator`
- Branch name: `swarm/<swarm_id>-scaffold` (this same branch becomes the bundled-PR branch at the end — no rename needed)

**All subsequent skill operations happen inside this worktree.** The architect agent's artifact writes, your `forge_propose_changeset`, every implementer dispatch, the final commit — all from `$ORCH_WT`. Pass `$ORCH_WT` as the cwd in any Bash that needs it.

**Cleanup:** the worktree stays in place until the PR merges. After merge, `git worktree remove .claude/worktrees/<swarm_id>-orchestrator` and `git branch -D swarm/<swarm_id>-scaffold` (or let the harness auto-clean — `harness session release` includes worktree pruning).

### Phase 1: Triage (architect)

Spawn ONE Agent with `subagent_type: "Plan"` (architect-style). Prompt template:

```
You are the architect for Palace iOS swarm <swarm_id>.

Task from user:
<user task verbatim>

Your job:
1. Read .forgeos/contracts/*.json to understand current module surfaces.
2. Identify which top-level modules under Palace/ this task touches.
   List them. If only 1 module: STOP and report "single-module — swarm not needed".
3. For each touched module, write a contract delta to
   .forgeos/swarms/<swarm_id>/contracts/<Module>.md describing:
   - What public types/protocols change (added, removed, modified)
   - What internal seams (DI protocols) need updating
   - What test contracts the module must satisfy
   - What files are scoped to THIS implementer (paths)
   - What files are explicitly OFF-LIMITS (other modules' work)
   - **Verification criteria (MANDATORY)** — a section listing grep-able
     assertions per acceptance criterion. Examples:
       * "For every test file matching `<SUT>Tests.swift`:
         `grep -c '<SUT>(' <test-file>` must be ≥ 1 — fake-test-instantiation
         (PR #1018 qa2/qa3) is structurally impossible if you write
         this grep BEFORE the implementer starts."
       * "For migration contracts: `grep -rn '<old-function-name>'
         <modified-paths>` must return zero hits post-migration — catches
         dishonest migrations (PR #1018 arch3)."
       * "For tests whose name contains 'across', 'twice', 'reset',
         'retry', 'again': test body must call the production driver
         ≥2 times. Grep evidence required (PR #1018 qa1)."
       * For every new try await / await boundary added in production code, the contract must include a grep showing a test that drives that exact line via the public entry point. If no such grep is possible (entry point requires unmockable dependencies), the implementer must STOP with BLOCKED + scope-deferral; the partial test does NOT satisfy the contract. (Catches swarm_c8fcab76 arch1 — `PlaybackReadinessGate.awaitReadinessAndPlay` called from `AudiobookSessionManager.swift:684-710` but tests drove the static method directly because `openAudiobook(...)`'s mock book failed in the loader before `bind()` ran.)
     Architects write these greps because the spec is fresh; orchestrator
     runs them at Phase 4.5; implementers paste evidence at completion.
4. Write .forgeos/swarms/<swarm_id>/plan.md — human-readable summary:
   the goal, the modules, the parallelism plan, the risks, the
   acceptance criteria.
5. Write .forgeos/swarms/<swarm_id>/manifest.yaml with:
   swarm_id, task, modules: [{name, files_scope, contract_path,
   implementer_prompt}], created_at, status: triaged.

Constraints:
- Contracts must be small, specific, and overlap-free.
- If two modules genuinely need to change together, that's ONE
  contract assigned to ONE implementer, not two contracts.
- Pure-Swift modules can include "use scripts/pbxproj_add_swift.rb
  for any new files added to Palace.xcodeproj"
- Reference existing patterns in PalaceCatalog (Palace/Packages/PalaceCatalog/)
  for SPM extractions.

Report when done: list of modules, contract paths, ready-to-dispatch.
```

Read the architect's manifest.yaml and plan.md. Show plan.md to the user before dispatching. **Pause for user confirmation** unless they explicitly said "go ahead and execute" or are in auto-mode with this skill.

### Phase 1a: Architect post-review (lighter SoD on the architect's output)

The architect can be wrong. PR #1018's architect estimated 48 tests in the auth area; reality was 385+ — a 7x miss in a load-bearing input. Reviewers review the implementers; nobody reviews the architect. Close the gap with a lighter pass:

Spawn ONE more Agent (subagent_type `general-purpose`) — the architect-reviewer. Prompt template:

```
You are the architect-reviewer for swarm <swarm_id>. Read:
  - .forgeos/swarms/<swarm_id>/plan.md
  - .forgeos/swarms/<swarm_id>/contracts/*.md
  - .forgeos/swarms/<swarm_id>/manifest.yaml
  - Any recon docs the architect wrote under docs/

Verify:
1. Contract scope counts (call sites, files, tests) actually match what's
   in the codebase. Run the greps the contracts cite. Are they correct?
2. Off-limits lists are complete. Grep for sibling patterns the architect
   might have missed.
3. Verification-criteria greps are syntactically valid and would actually
   catch the failure modes they claim to.
4. Cross-module dependencies in `depends_on` are accurate (e.g., if C
   depends on A, does C's contract actually need A's seam?)
5. **Call-graph completeness for new content-type behavior** (added 2026-06-03
   per PP-4161 wall-failure). For any swarm that introduces a new value to
   an enum that drives user-visible buttons or content-type routing
   (`BookButtonType`, `TPPBookContentType`, `BookButtonState`, similar)
   AND specifies new behavior gated by that value (e.g. "for `.streamingHTML`
   books, the button is `.readStreaming`"), verify the FULL call graph from
   `userAction → buttonMapping → action handler → service call → registry
   state change → buttonMapping re-evaluation` is traced AND every transition
   in that graph has either (a) an existing handler that does the right
   thing for the new value or (b) is in scope to be patched. Grep evidence
   required for each link in the chain. **This is the check that PP-4161
   needed and didn't have: Module C contract pinned the post-borrow display
   rule (BookButtonState.downloadNeeded → [.readStreaming, .return] for
   streamingHTML) but didn't verify any production path could transition
   the registry from `.unregistered` → `.downloadNeeded` for the new content
   type. Module D simdrive dogfood caught it via two layered escalations
   (v2.2 hotfix attempt + Wave 4 Path X final fix) instead of catching it
   here in Phase 1a.**

Submit a BLOCKED/APPROVED verdict via Write to
.forgeos/swarms/<swarm_id>/architect-review.md. If BLOCKED, the architect
re-runs with the findings. If APPROVED, proceed to Phase 1b.
```

Cost: 1 extra agent invocation, ~10 minutes. Catches scope-misestimation before it propagates to all N implementers' contracts.

**Phase 1a is NON-SKIPPABLE for any module marked `risk: critical_path` or `risk: critical_path_meta` in `manifest.yaml`.** Skipping is permitted ONLY for all-standard swarms (every module is `risk: standard`) AND every touched area has a current `docs/architecture/areas/<area>/verification-checklist.md`. Even one critical-path module in the swarm forces Phase 1a. This rule was added 2026-05-28 as part of swarm `swarm_M1_83be56fc` — waves 1-4 surfaced critical-path-meta findings where Phase 1a would have caught contract scope-misestimation before any implementer ran. For non-critical-path domains where we've swarmed before AND the area-checklist is authoritative, the checklist already encodes the architect's truth-table and the post-review is redundant — record `architect_review.skipped.reason` in manifest.yaml per `.forgeos/schemas/swarm-manifest-v2.md`.

### Phase 1b: Commit scaffolding IMMEDIATELY (do not defer)

As soon as the architect's artifacts (`contracts/`, `plan.md`, `manifest.yaml`) exist on disk, commit them on the orchestrator branch BEFORE dispatching implementers:

```bash
# Inside $ORCH_WT, on swarm/<swarm_id>-scaffold:
git add .forgeos/swarms/<swarm_id>/
git commit -m "[<swarm_id>] swarm scaffold: contracts + plan + manifest

**Scope:** swarm scaffolding only (architect triage output); implementer
diffs and integration commits land in subsequent commits on this branch.
"
```

**Why this matters more than it sounds:**
- Untracked files survive your own next move, but they do NOT survive another claude session's `git clean -fd` in main. Committed files are git-tracked and only `reset --hard <older>` can lose them.
- The scaffolding commit also makes the implementer worktrees reproducible: when they branch from this commit, they all see the same contracts.
- The bundled PR ends up with a clean history (scaffolding → module fixes → integration) instead of one giant squash with implicit context.

This commit is the SECOND defense against artifact loss; Phase 0's worktree isolation is the first.

### Phase 2: Create ForgeOS changeset

Once user (or auto-mode) approves the plan:

```
mcp__forgeos__forge_propose_changeset
  project_id: <pid>
  title: "[swarm <swarm_id>] <task summary>"
  description: <plan.md content, condensed>
  ...
```

Record `changeset_id` in manifest.yaml. Update status: `dispatched`.

### Phase 3: Dispatch implementers (parallel)

For each module in manifest.modules, spawn an Agent **in parallel** (single message, multiple Agent tool calls). Subagent type: `general-purpose`.

**Before building the prompt for each implementer**, infer the domain from the module name and capture the subagent-prelude output:

```bash
# Map module → domain (extend as new modules show up):
#   Audiobooks*           → audiobook
#   Accounts*/SignIn*     → accounts
#   MyBooks*              → mybooks
#   Reader2/Reader3/PDF   → reader
#   release/hotfix work   → release
#   anything else         → general
~/harness/bin/harness subagent-prelude --domain <domain> > /tmp/swarm-<swarm_id>-<module>-prelude.md
```

This emits ~150-300 lines of memory pins relevant to the module — the parent session has these auto-loaded via MEMORY.md but **subagents do not**. Without the prelude, a subagent doing audiobook work won't know about the toolkit's 25+-revision regression history or the LCP MIME-nesting pattern; with it, the relevant references are in the prompt.

Then the implementer prompt template becomes:

```
You are implementer for module <module-name> in Palace iOS swarm <swarm_id>.

Read FIRST: .forgeos/swarms/<swarm_id>/contracts/<Module>.md
Read SECOND: .forgeos/swarms/<swarm_id>/plan.md (for shared context)
Read THIRD: /Users/mauricework/PalaceProject/ios-core/CLAUDE.md (project conventions)

<paste contents of /tmp/swarm-<swarm_id>-<module>-prelude.md verbatim here>

Your job:
1. Implement ONLY what the contract says is in your scope.
2. Files OUTSIDE your scope are read-only. If you need to change one,
   STOP and report — do not edit. The integrator handles cross-module.
3. Use scripts/pbxproj_add_swift.rb to add any new Swift files to
   Palace.xcodeproj. Do not hand-edit pbxproj.
4. Tests are mandatory (TDD). Use mocks from PalaceTests/Mocks/.
5. When done, write .forgeos/swarms/<swarm_id>/transcripts/<module>.md
   with: files added/modified/deleted, tests added, key decisions, any
   gaps or things the integrator must handle.
6. Do NOT commit. Do NOT push. Leave the changes staged for the integrator.

Constraints:
- TDD per CLAUDE.md TDD rules: write tests first, no fluff, no tautologies.
- AppContainer injection over .shared singletons.
- @MainActor ObservableObject for ViewModels.
- No force unwraps (per memory).
- Run xcodebuild to validate compilation before reporting done.

## Scope-deferral protocol (MANDATORY)

If you discover you cannot complete the contract's full scope within
your pass, DO NOT silently ship partial as READY FOR INTEGRATION. The
correct response is STOP and report BLOCKED with a scope-reduction
proposal:

```
BLOCKED: scope reduction proposal.

Contract says <N> sites/files/tests. I can land <M> cleanly. The
remaining <N-M> have <specific reason: entangled state-machine cleanup,
unrecoverable test-fixture dependency, etc>. Options for the orchestrator:
  (a) extend my pass with more time budget
  (b) re-architect with <N-M> deferred as next-sprint scope
  (c) split into <K> swarms

I will not ship partial as READY without explicit direction.
```

Burying scope reductions in a `gaps` section while claiming READY
(as in PR #1018 Module C) is the failure mode this protocol prevents.
The decision point is the orchestrator's, not yours.

## Definition of Done — paste evidence for each before reporting READY

Per `.forgeos/wall-failures/` (PR #1018 lessons), every implementer must
self-verify and PASTE evidence in the transcript before declaring done:

1. **SUT instantiation check** — for every test file you added or
   modified named `<SUT>Tests.swift` or `<SUT><Aspect>Tests.swift`,
   run `grep -c "<SUT>(" <test-file>` — must be ≥1. Paste the count.
   (Catches fake-test-instantiation per arch2/qa2/qa3.)

2. **Function-result usage check** — for every new production-code call
   to a contracted-in function, paste evidence the result is used (bound
   via `let outcome = ...`, pattern-matched, returned, or has a
   `// TODO(ticket): result intentionally discarded because <reason>`
   comment). `grep -E "= <fnName>\(|let _ = <fnName>" <prod-file>`.
   (Catches dishonest migrations per arch3.)

3. **Multi-step test body check** — for every test name containing
   `across`, `twice`, `reset`, `retry`, `again`, `roundtrip`,
   `inProduction`, `viaX`: confirm the body literally does each step
   the name claims. Paste the relevant grep or line range.
   (Catches half-done tests per qa1, fake wiring per arch2.)

4. **Scope coverage audit** — for every item in the contract's scope
   list, confirm it's either in your diff OR explicitly in a STOP
   block / BLOCKED scope-reduction proposal. Paste the audit table.

5. **Mutation pass (MANDATORY — not deferred to integrator)** — run
   `python3 scripts/palace_mutate.py --file <modified-file> --tests <test-class> --diff-only`
   for every modified production file. Paste the kill rate. Must meet
   contract threshold (default ≥50% diff-scoped; 100% on critical paths
   per CLAUDE.md `Palace/Audiobooks/`, `Palace/SignInLogic/`,
   `Palace/MyBooks/Download*`). If you don't run this, you CANNOT
   report READY.

6. **Build verification** — `xcodebuild ... build` clean. Paste the
   tail.

7. **Test-run verification with xcresult evidence (MANDATORY — wall-failure
   2026-06-01 Option A)** — for every test claim in your transcript,
   run the EXACT `-only-testing:` selectors that match your DoD #1 SUT
   instantiation claims and PASTE the xcresult bundle absolute path:

   ```bash
   DD=/tmp/dd-${MOD}-${RANDOM}
   xcodebuild -project Palace.xcodeproj -scheme Palace \
     -destination "platform=iOS Simulator,id=141BD227-6E9A-4409-8D99-2D4FE818238D" \
     -derivedDataPath "$DD" \
     -only-testing:PalaceTests/<YourTestClass1> \
     -only-testing:PalaceTests/<YourTestClass2> \
     test 2>&1 | tee /tmp/test-${MOD}.log
   ```

   In your transcript, paste:
   - The xcresult bundle absolute path (find via `ls "$DD/Logs/Test/"*.xcresult`).
     The orchestrator MUST be able to `xcrun xcresulttool get test-results tests
     --path <bundle>` on this path and find your claimed tests.
   - The exact `Executed N tests, with 0 failures` line.
   - Per-method test names list (use
     `xcrun xcresulttool get test-results tests --path <bundle> | jq '.testNodes[] | .. | objects | select(.nodeType=="Test Case") | .name'`).

   Narrative claims like "16/16 pass" without a verifiable xcresult bundle
   are NOT acceptable. The wall-failure entry
   `.forgeos/wall-failures/2026-06-01-cs_c96660a2-implementer-A-false-pass.md`
   documents the canonical false-PASS pattern (Module A reported PASS while
   ordering test actually failed; caught at Phase 4.5 only because the
   integrator re-ran tests). Option A makes the implementer claim
   falsifiable by the orchestrator.

Report:
- summary: 3-5 bullets on what you did
- files: list of modified/added paths
- tests: list of test files + key test names
- gaps: anything the integrator needs to know
- definition-of-done evidence: paste the 7 checks above with output

If you cannot produce evidence for all 7 checks, report BLOCKED with
which check failed and why. Do NOT report READY without the evidence.

**Transcript MUST be at the contract-specified path** so the integrator
finds it without manual copying. Write to:
  `.forgeos/swarms/<swarm_id>/transcripts/<MOD>.md`
where `<MOD>` is your module letter (A/B/C/D/...). The integrator stages
all transcripts (commits them on the orchestrator branch) at Phase 4.
DO NOT write transcripts to any other path; DO NOT leave them outside
the `.forgeos/swarms/<swarm_id>/` tree — they will be lost when the
integrator copies from your worktree.
```

Use `run_in_background: false` (foreground) for the parallel dispatch — you need the results before integrating. Multiple Agent calls in a single message run concurrently.

### Phase 4: Integrate

After all implementers return:

1. **Read all transcripts** under `.forgeos/swarms/<swarm_id>/transcripts/`. Look for `gaps:` flags AND verify each transcript pasted Definition-of-Done evidence for all 6 checks. If any implementer skipped the evidence, send them back BEFORE proceeding — that's a Definition-of-Done violation, not an integrator-handleable gap.
2. **Run module contract check**: `python3 scripts/export-module-contracts.py --check`. If any module's public surface changed without a contract update, flag it (the architect's contract is supposed to capture all public changes).
3. **Resolve gaps**: integrator (you) handles cross-module wiring, AppContainer composition, anything implementers flagged. Make these changes directly — don't re-spawn.

### Phase 4.5: Orchestrator skeptic pass (MANDATORY before Phase 5)

The reviewers will catch what's left after this pass — but the cheaper it is to catch upstream, the faster the loop. PR #1018 reviewers caught 4 of 6 issues that this skeptic pass would have caught at integration time, saving a full reviewer round-trip.

Run these literal commands. Block before review if any fail:

```bash
ORCH_WT="$(pwd)"  # already in orchestrator worktree
SWARM_ID="<swarm_id>"

# Check 0: Architect post-review present + APPROVED (per .forgeos/schemas/swarm-manifest-v2.md)
ARCH_REVIEW=$(yq -r '.architect_review.verdict' .forgeos/swarms/$SWARM_ID/manifest.yaml 2>/dev/null)
ARCH_SKIPPED=$(yq -r '.architect_review.skipped.reason' .forgeos/swarms/$SWARM_ID/manifest.yaml 2>/dev/null)
if [ "$ARCH_REVIEW" = "BLOCKED" ]; then
  echo "BLOCK: architect_review.verdict == BLOCKED. Address findings + re-run architect-reviewer agent."
  exit 1
fi
if [ "$ARCH_REVIEW" != "APPROVED" ] && { [ -z "$ARCH_SKIPPED" ] || [ "$ARCH_SKIPPED" = "null" ]; }; then
  echo "BLOCK: architect_review missing. Per Phase 1a, run architect-reviewer subagent before dispatching implementers."
  echo "If skip is intentional (area-checklist-authoritative + delta-verified), populate architect_review.skipped.reason with justification per schemas/swarm-manifest-v2.md."
  exit 1
fi

# Check 1: Submodule typechanges accidentally staged (PR #1018 arch1)
if git diff --cached --name-only | grep -E "^(adept-ios|adobe-content-filter|ios-audiobook-overdrive|ios-tenprintcover|mobile-bookmark-spec|readium-sdk|readium-shared-js|adobe-rmsdk)$"; then
  echo "BLOCK: submodule typechanges staged — git restore --staged them"
  exit 1
fi

# Check 2: For every contract's Verification criteria block, run its greps
# (architect wrote these in Phase 1; orchestrator executes them here)
python3 ~/harness/core/lib/run-contract-verification.py \
  --swarm ".forgeos/swarms/$SWARM_ID" || {
    echo "BLOCK: contract verification criteria failed — see output"
    exit 1
  }

# Check 3: SUT-instantiation grep for every <SUT>Tests.swift in the diff (PR #1018 qa2/qa3)
git diff --cached --name-only | grep -E "PalaceTests/.*Tests\.swift$" | while read testfile; do
  # Extract probable SUT name from test class name
  testbase=$(basename "$testfile" .swift)
  sut=$(echo "$testbase" | sed -E 's/(AuthCoordinator|Telemetry|Reauth|Wiring|Registration|Coordinator)Tests$//' | sed -E 's/Tests$//')
  if [ -n "$sut" ] && ! grep -q "${sut}(" "$testfile"; then
    echo "BLOCK: $testfile claims to test $sut but never instantiates it"
    exit 1
  fi
done

# Check 4: Function-result usage in claimed migrations (PR #1018 arch3)
# For every claimed migration in transcripts, grep the modified file for the legacy function
grep -h "migration\|migrate\|replaced" .forgeos/swarms/$SWARM_ID/transcripts/*.md | \
  python3 ~/harness/core/lib/migration-completeness-check.py \
  --swarm ".forgeos/swarms/$SWARM_ID" || {
    echo "BLOCK: claimed migration still calls legacy function — see output"
    exit 1
  }

# Check 5: Verify implementer pasted Definition-of-Done evidence
for transcript in .forgeos/swarms/$SWARM_ID/transcripts/*.md; do
  if ! grep -q "definition-of-done evidence" "$transcript"; then
    echo "BLOCK: $transcript missing Definition-of-Done evidence section"
    exit 1
  fi
done

# Check 5b: runnable test-name-vs-body audit. For every multi-step-named
# test in the diff, the body must reference the embedded PascalCase
# production-class noun (instantiation, static call, or type annotation).
# Catches the fake-wiring-test pattern documented in:
#   - .forgeos/wall-failures/2026-05-28-cs847892e8-arch1.md (AudiobookSessionManager)
#   - .forgeos/wall-failures/2026-05-28-cs9a267b63-arch1.md (TPPReauthenticator)
# Both are the same shape: name promises wiring through class X; body never
# touches X. Documentation-only fixes (CLAUDE.md DoD check #7) didn't prevent
# recurrence — this is the runnable-grep escalation.
DIFF_TESTS=$(git diff --cached --name-only | grep -E "PalaceTests/.*Tests\.swift$" || true)
if [ -n "$DIFF_TESTS" ]; then
  python3 scripts/check-test-name-vs-body.py $DIFF_TESTS || {
    echo "BLOCK: scripts/check-test-name-vs-body.py reported fake-wiring test(s)"
    echo "  Wall-failure shape: .forgeos/wall-failures/2026-05-28-cs9a267b63-arch1.md"
    echo "  Action: either instantiate the embedded production-class noun in the test body,"
    echo "          or rename the test to not embed it (only the name promises the wiring)."
    exit 1
  }
fi

# Check 6: Universal rigor scripts (M1 floor — swarm_M1_83be56fc, 2026-05-28)
# Wraps wave-1-4 manual-review findings into machine-checkable form.
# Contract reconciliation + blast-radius + intent-recorded BLOCK on exit 1.
# Adjacency-staleness is WARN-only (always exit 0, count warnings).
python3 scripts/check-contract-reconciliation.py --quiet ; CR_EXIT=$?
python3 scripts/check-blast-radius.py --quiet            ; BR_EXIT=$?
python3 scripts/check-adjacency-staleness.py --quiet     ; AS_EXIT=$?  # warn-only
python3 scripts/check-intent-recorded.py --quiet         ; IR_EXIT=$?
if [ "${CR_EXIT:-0}" -ne 0 ]; then
  echo "BLOCK: check-contract-reconciliation.py exit $CR_EXIT — diff doesn't deliver contract/commit claims"
  exit 1
fi
if [ "${BR_EXIT:-0}" -ne 0 ]; then
  echo "BLOCK: check-blast-radius.py exit $BR_EXIT — new public API surface / #if DEBUG leak / test-seam bypass"
  exit 1
fi
if [ "${IR_EXIT:-0}" -ne 0 ]; then
  echo "BLOCK: check-intent-recorded.py exit $IR_EXIT — ≥10 prod-LOC change without .forgeos/intent/<name>.md"
  exit 1
fi
if [ "${AS_EXIT:-0}" -ne 0 ]; then
  echo "WARN: check-adjacency-staleness.py exit $AS_EXIT — adjacent docs/tests stale (advisory only)"
fi

# Check 6.5: Borrow→display invariant for new TPPBookContentType cases
# (PP-4161 wall-failure 2026-06-03). For any swarm that adds a new
# TPPBookContentType case, the test set must include at least one
# integration-style test that drives the full user-action → registry-state
# → button-mapping cycle from `.unregistered` for the new case. Without
# this, unit tests can pin the post-state display rule without proving
# any production path actually reaches it (the v2.2 → Wave 4 escalation
# pattern). Grep heuristic: for every `+case <newCase>:` added to a
# TPPBookContentType switch (across files), require at least one staged
# test method that contains BOTH `handleAction(for: .get)` (or the
# cell-side `callDelegate(for: .get)`) AND the new content-type literal
# in the same method body.
if git diff --cached -- 'Palace/Book/Models/TPPContentType.swift' 'Palace/Book/Models/TPP*.swift' 2>/dev/null | grep -qE "^\+\s*case\s+\w+"; then
  # New TPPBookContentType case added — find it and verify integration test exists.
  NEW_CT_CASES=$(git diff --cached -- 'Palace/Book/Models/TPPContentType.swift' 2>/dev/null | grep -oE "^\+\s*case\s+\w+" | sed -E 's/^\+\s*case\s+//' | sort -u)
  for case_name in $NEW_CT_CASES; do
    # Look for staged test files referencing both .get handleAction AND the new case literal.
    if ! git diff --cached --name-only | grep "PalaceTests/.*Tests\.swift$" | xargs grep -l "handleAction(for: \.get)\|callDelegate(for: \.get)" 2>/dev/null | xargs grep -l "\.${case_name}\b" 2>/dev/null >/dev/null; then
      echo "BLOCK: TPPBookContentType.${case_name} added but no integration-style test drives"
      echo "       handleAction(for: .get) / callDelegate(for: .get) for that content type."
      echo "  Wall-failure: PP-4161 (.forgeos/wall-failures/2026-06-03-cs_e0f586cc-modC-get-routing.md)"
      echo "  Pattern: tests pin destination state without proving production path reaches it."
      echo "  Action: add a test that drives the borrow → display cycle from .unregistered"
      echo "          for .${case_name}, e.g. testBookDetailViewModel_handleAction_getFor${case_name^}Book_*"
      exit 1
    fi
  done
fi

# Check 7: Verify-pr.sh --quick with diff-baseline (auto-flake comparison)
scripts/verify-pr.sh --quick --diff-baseline || {
  # Distinguish new failures from pre-existing flakes (--diff-baseline reruns failing classes against base SHA)
  echo "BLOCK: verify-pr.sh failed AND failures are NOT pre-existing flakes — see output"
  exit 1
}

# Check 8: Re-run each implementer's claimed test selectors on the merged
# state (wall-failure 2026-06-01 Option B — orchestrator side of the
# false-PASS-report fix). The Phase 3 implementer prompt's DoD #7 now
# requires them to paste an xcresult bundle path; this check confirms
# the SAME selectors pass on the integrated branch.
#
# Why: Module A on swarm_0b7616e7 reported "16/16 pass" while the
# RecentlyReadingService ordering test actually failed on identical
# code. The implementer wall leaked; this check catches it before the
# reviewer wall has to.
SIM_ID="${SIM_ID:-141BD227-6E9A-4409-8D99-2D4FE818238D}"
for transcript in .forgeos/swarms/$SWARM_ID/transcripts/*.md; do
  # Extract -only-testing: selectors from the transcript (implementers
  # paste them inline as part of DoD #6/#7).
  SELECTORS=$(grep -oE -- '-only-testing:[^ ]+' "$transcript" | sort -u | head -20)
  if [ -z "$SELECTORS" ]; then
    echo "WARN: no -only-testing selectors found in $transcript (Phase 3 DoD #7 violation — implementer didn't paste runnable evidence)"
    continue
  fi
  DD=/tmp/dd-orch-recheck-$RANDOM
  if ! xcodebuild -project Palace.xcodeproj -scheme Palace \
        -destination "platform=iOS Simulator,id=$SIM_ID" \
        -derivedDataPath "$DD" \
        $SELECTORS test 2>&1 | tee /tmp/orch-recheck.log | \
        grep -qE "Executed [0-9]+ tests, with 0 failures"; then
    echo "BLOCK: implementer claimed tests pass but they FAIL on the merged orchestrator state."
    echo "  Transcript: $transcript"
    echo "  Selectors:  $SELECTORS"
    echo "  Log:        /tmp/orch-recheck.log"
    echo "  Canonical wall-failure: .forgeos/wall-failures/2026-06-01-cs_c96660a2-implementer-A-false-pass.md"
    exit 1
  fi
done
```

The two `python3 ~/harness/core/lib/*` scripts are stubs to be implemented (see `docs/architecture/swarm-rigor-followups.md` for spec). Until they exist, run the underlying greps manually using the contract's Verification criteria block.

4. **Resolve any skeptic-pass blocks**: send the relevant implementer back with the specific finding. Do NOT proceed to Phase 5 until all 7 checks pass (Check 6 added for M1 universal rigor floor; Check 7 is the renamed verify-pr.sh step).
5. **Run verify-pr.sh again** after gap resolution.

If verify-pr.sh fails after Phase 4.5: small failures fix directly; large failures (whole module broken) re-spawn that one implementer with the failure log + the successful sibling work as context.

### Phase 5: Submit evidence + run forge-review

```
mcp__forgeos__forge_submit_evidence  (unit_test, lint, build evidence per gate)
```

Then invoke `/forge-review` (the existing skill) — it spawns **3 reviewer subagents**: `forge-architect-reviewer`, `forge-qa-reviewer`, and `forge-blast-radius-reviewer` (universal floor — runs on every PR regardless of gate template per swarm `swarm_M1_83be56fc`, 2026-05-28). Read all three verdicts. Any BLOCKED verdict — including blast_radius even if no gate formally required it — blocks promotion of every gate until addressed.

If reviewers reject:
1. Read the rejection findings.
2. **Create wall-failure entry for EACH finding** at `.forgeos/wall-failures/YYYY-MM-DD-pr<NNNN>-<short-id>.md`. Each entry must classify the wall that should have caught it and propose a permanent fix per `.forgeos/wall-failures/README.md`. Add to `INDEX.md`.
3. Send a fixup subagent to address each finding (same dispatch pattern as Phase 3).
4. Re-run Phase 4.5 skeptic pass on the fixup output (catches partial fixes).
5. Re-spawn the reviewers (they're stateless — fresh agents with prior findings as input).
6. If approved on re-review, apply the permanent fixes from the wall-failure entries to the swarm SKILL / CLAUDE.md / hooks / per-area checklists. Update entry status to `applied`. Update `derived-improvements.md`.

If approved on first review: proceed. (Note: this should become less common over time as wall-failure-derived improvements catch failures earlier. If reviewers consistently approve first-round across many swarms, that's evidence the upstream walls are working — celebrate, don't loosen.)

### Phase 6: Promote + commit + open PR

Promote ForgeOS gates: `mcp__forgeos__forge_promote_gate` for each.

Write `.forgeos/swarms/<swarm_id>/outcome.md` with: status, modules touched, files changed, tests added, reviewer verdicts (both rounds if any), total agent count, lessons learned, **list of wall-failure entries created and their `applied_in` status**.

Update manifest.yaml status: `complete`.

Stage commit. Use commit message format:

```
[swarm <swarm_id>] <task summary>

Modules: <list>
Implementers: <count>

<details>

ForgeOS changeset: <cs_id>

**Scope:** <what's in>
**Not done:** <what's deferred, if anything>
```

The pre-commit hook will validate the changeset reference and stanzas (commits ≥50 prod LOC need stanzas per `~/harness/`).

Open PR with `gh pr create`. Body should reference the swarm_id and link to the manifest.yaml in the PR description.

## Failure modes & recovery

**Architect produces overlapping contracts**: the implementers will collide. Mitigation: read the contracts before dispatching; if two contracts touch the same files, push back to architect (or fix yourself) — they should be merged into ONE contract.

**Implementer reports it needs to edit a file outside its scope**: this means the architect missed a coupling. Decide: either expand that implementer's scope (re-spawn with updated contract), or you (integrator) make the cross-module change directly.

**One implementer succeeds, others fail**: stage what succeeded if it compiles standalone. Re-spawn the failed ones with updated context (include the successful work). Do NOT proceed to verify-pr.sh until all are integrated.

**verify-pr.sh fails after integration**: small failures fix directly; large failures (whole module broken) re-spawn that one implementer with the failure log + the successful sibling work as context.

**ForgeOS reviewer rejects**: read rejection. If it's a real architectural issue, that's a triage failure — discuss with user before re-dispatching. If it's a small ask (rename, add doc, missing test), fix directly.

**Swarm artifacts disappear mid-flight**: this happens when a concurrent claude session in the same repo does `git clean -fd` or `git checkout -f` while your scaffolding is untracked. Phase 0 + Phase 1b should prevent it — verify you actually did them (the orchestrator should be in `.claude/worktrees/<swarm_id>-orchestrator`, and `git log --oneline` on `swarm/<swarm_id>-scaffold` should show the scaffold commit). If you skipped Phase 0 and lost files, you have two options: re-run the architect from session context (cheap, transcripts persist), or reconstruct from the implementer worktrees (each one read the contracts into its session context so the agent's transcript usually quotes the relevant scope). Then commit immediately — don't repeat the loss.

## Cross-session safety

The harness ships two protections that work together with Phase 0 + 1b:

1. **`pre-destructive-check.sh`** — a PreToolUse hook that blocks `git checkout`/`reset --hard`/`clean -fd` when the destination would clobber a branch tracked in `.forgeos/swarms/*/manifest.yaml` with `status != complete`. If you see this hook fire, another swarm is in-flight on the branch you're trying to act on — don't `--force`-bypass; either coordinate with that session or work on a different branch.

2. **`session-start.sh`** — surfaces an `active_swarms` block in session-start context listing any swarm with `status != complete`. Read it. If you start a new session and another swarm is in flight, your default cwd should NOT be the orchestrator's worktree, and your first instinct on any destructive op should be "is this someone else's working branch?"

3. **`harness session list`** — `~/harness/bin/harness session list` prints all in-flight swarms across registered projects. Run before any branch hygiene operation.

If you must bypass the destructive-check hook (you really do want to wipe a stale worktree from a swarm that crashed), set `HARNESS_SWARM_BYPASS=1` for that single command. Don't put it in your shell profile.

## Heuristics for the architect agent

When deciding "is this 1 module or N":
- A module = a top-level subdirectory of `Palace/`. So `Palace/Audiobooks/` is one module; `Palace/MyBooks/Download*` is part of MyBooks, same module.
- New SPM package = a separate "module" (`Palace/Packages/PalaceAuth/`).
- The `Palace.xcodeproj` itself is a "module" if pbxproj edits cross many groups — but usually pbxproj edits flow naturally with file additions and don't need their own implementer.

When sizing implementer scopes:
- Aim for each implementer to handle 200-600 LOC of changes (the right size for one focused agent).
- If a module is >800 LOC of changes, consider splitting into two contracts within the same module (e.g., "Auth - core" and "Auth - tests").
- If a module is <100 LOC, consider folding it into a sibling implementer's scope.

## Examples of good /swarm tasks

- **Extract `Palace/SignInLogic/` into `Palace/Packages/PalaceAuth/` SPM package** — modules: SignInLogic, Palace (callsites), Palace.xcodeproj. 3 implementers.
- **Add a new feature flag system across Audiobooks + Reader2 + Settings** — 3 implementers, one each module, shared FeatureFlags contract is part of the Settings implementer's scope.
- **Migrate `MyBooksDownloadCenter` to async/await** — 1 module (MyBooks). NOT a swarm task. Do directly.

## Examples of bad /swarm tasks

- "Fix this typo in 3 files" — single-agent, no triage needed.
- "Add a button to this screen" — single-module.
- "Refactor this entire module" — depends. If it's all internal to one module, single-agent. If it requires changing the public API and updating callers across other modules, swarm.
