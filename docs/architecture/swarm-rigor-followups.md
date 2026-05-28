---
name: swarm-rigor-followups
type: evolving
status: active
created: 2026-05-28
last_refresh: 2026-05-28
freshness_window: 365d
owners: [general]
description: "Swarm rigor — follow-up backlog"
---

<!-- audit-verified: PR #1018 is real; I orchestrated swarm_66819d80 today; the items below are derived from the wall-failure entries at .forgeos/wall-failures/2026-05-27-pr1018-*.md and the gaps explicitly named in this PR's commits. -->

# Swarm rigor — follow-up backlog

Items derived from PR #1018 wall-failures but NOT applied in the rigor-improvement PR. Listed with priority, effort, and the wall-failure entry that motivated it.

---

## Tier A — apply within 2 weeks (high leverage, contained scope)

### A1. Per-area verification checklists for the other 7 critical-path areas

**Motivated by:** `.forgeos/wall-failures/2026-05-27-pr1018-arch3.md` (architect re-discovery cost) + the meta thesis (architect's recon should be reusable across swarms).

**Areas needing checklists** (`docs/architecture/areas/<area>/verification-checklist.md`):
- `audiobook/` — call-site map for AudiobookSessionManager, Vendors/, AudiobookLoader, NowPlayingCoordinator + the toolkit-fragility traps
- `mybooks/` — Download*, Borrow*, BookReturn*, registry interactions
- `reader/` — Reader2 (Readium 3.x WKWebView) + Reader3 (PDFKit) + the EditingActions / copy-paste gating
- `network/` — TPPNetworkExecutor, TPPNetworkResponder, TPPNetworkQueue, stubbing patterns
- `accounts/` — AccountsManager state machine, library swap, .accountNotFound enum conflation
- `signin-modal/` — SignInModalView + SignInWebSheet + SwiftUI refactor pending
- `holds/` — HoldsReducer, notification ↔ list-state coherence (per HelpSpot 17960/17971 triage)

**Effort:** ~2-3 hours per area. Each can be lifted from existing memory (`saml_refactor_handoff.md`, `audiobook_first_open_hang_3_2_0.md`, etc.) + a fresh call-site grep. Parallelizable across sessions; do one per maintenance pass rather than all at once.

**Recommended sequence:** mybooks (most coupled to PR #1018 work) → audiobook (toolkit fragility, frequent regressions) → network → accounts → reader → holds → signin-modal.

---

### A2. Public-surface drift detection in pre-commit

**Motivated by:** Implicit in PR #1018 — architect's contract covers what public surface changes; commits that change public surface without contract update should be blocked at commit time, not caught at integration.

**Implementation:**
- Pre-commit hook calls `python3 scripts/export-module-contracts.py --check` on staged files
- If public surface (any `public func`, `public class`, `public protocol`, `public extension`) changes in a tracked module's source dir and the changeset description / commit body doesn't reference the module's contract update → BLOCK

**Effort:** ~3-4 hours. `export-module-contracts.py --check` already exists per CLAUDE.md "Multi-module orchestration"; the hook integration is new. Test against PR #1018 retroactively — should NOT block (the swarm did update PalaceAuth's surface and the contract).

**Risk:** false positives on `internal` → `public` typo-fixes that aren't real surface changes. Mitigation: hook diff-greps the actual `public` keyword change, not generic module-content change.

---

### A3. Pre-commit critical-path mutation hook

**Motivated by:** `.forgeos/wall-failures/2026-05-27-pr1018-qa1.md` (half-done test) — mutation would have caught it but mutation was deferred. The Definition-of-Done check is paste-evidence based; a hook that REQUIRES mutation evidence in the commit body for critical-path changes is the next layer.

**Implementation:**
- Pre-commit hook: if `git diff --cached --name-only | grep -E "^Palace/(Audiobooks|SignInLogic|MyBooks/Download|Packages/PalaceAuth)"`, then require commit body to contain "mutation" + a kill rate
- Hook offers to run `palace_mutate.py --diff-only` itself and prepend the result to the commit body (`-c` editor-flow, similar to commit-template injection)

**Effort:** ~4-6 hours including the auto-run helper. Without auto-run: ~2 hours for the check-only version.

**Decision:** start with check-only; add auto-run if devs find it annoying to paste manually.

---

### A4. Architect post-review enforcement (currently skill-documented, hook-uncovered)

**Motivated by:** PR #1018's architect under-estimated test surface 7x (48 → 385+). The swarm SKILL.md now describes a Phase 1a architect-post-review step — but it's not enforced. An implementer can proceed without it.

**Implementation:**
- The `.forgeos/swarms/<id>/manifest.yaml` schema gains a required `architect_review` field: `architect_review: { reviewer_agent_id: ..., verdict: APPROVED, at: <timestamp> }`
- Phase 4.5 skeptic pass checks that this field is populated and `verdict == APPROVED` before allowing dispatch verification

**Effort:** ~1-2 hours (schema addition + Phase 4.5 check). Per-area checklists (A1) make architect-post-review cheaper since the architect mostly delta-verifies the checklist.

---

### A5. Helper scripts for swarm SKILL.md skeptic pass

**Motivated by:** Swarm SKILL.md Phase 4.5 references `python3 ~/harness/core/lib/run-contract-verification.py` and `migration-completeness-check.py` — both currently STUBBED-as-references. Without them, orchestrators run greps manually, which works but isn't bulletproof.

**Implementation:**
- `~/harness/core/lib/run-contract-verification.py` — parses contract `## Verification criteria` section, executes the greps, returns exit code 0/1 + structured output
- `~/harness/core/lib/migration-completeness-check.py` — reads transcripts for "migrate/migrated/replaced" claims, greps modified production files for the legacy function names, returns 0/1

**Effort:** ~6-8 hours total. Lives in the harness repo, not Palace iOS — separate commit/PR for ~/harness.

---

## Tier B — apply within 1-2 months (lower frequency, larger scope)

### B1. /rigorous-fix first real-world exercise

The skill is stubbed (`.claude/skills/rigorous-fix/SKILL.md` status: STUB). First use should be on a known-good prior single-module critical-path PR — e.g., PR #988 LCP audiobook downgrade fix — to validate the architect-light flow works at single-module scale. Update the skill's status line with first-use lessons.

**Effort:** ~3-4 hours (retroactive walk-through, capturing lessons).

### B2. Wall-failure catalog monthly review process

The `derived-improvements.md` file expects monthly aggregation. The first month after PR #1018 = late June 2026. Block out a 1-hour session: read INDEX.md end-to-end, identify clusters, promote cluster-level fixes if N >= 3 entries share a cause.

**Effort:** ~1 hour/month standing. Add to harness's launchd weekly-report cycle.

### B3. Backtest reviewer agents against prior shipped bugs

Per `~/Desktop/palace-ai-demo/03-improvements-roadmap.md` recommendation #4 (now updated to reference PR #1018 as live evidence). The next step: replay the last 10 prod-shipped bugs through the architect + qa_test reviewers as if they were new PRs. Measure catch rate. Use catch rate to identify reviewer-prompt gaps.

**Effort:** ~4-6 hours (build the replay harness + run on 10 prior PRs). Output is calibration data + reviewer-prompt updates.

### B4. Adversarial swarm agent

Spawn a "red-team implementer" subagent whose explicit job is to find the laziest way to satisfy a contract literally while violating its intent. If they can do it, the contract has loopholes that need closing.

**Effort:** ~6-8 hours (design the adversarial prompt + run against current swarm SKILL.md contracts + identify loopholes). Quarterly cadence after first run.

### B5. Lower /forge-review trigger bar (policy)

Currently /forge-review is mostly invoked via /swarm. Policy: any PR touching a critical path automatically invokes /forge-review pre-merge, regardless of how the code was authored. Requires:
- Pre-push hook integration: detect critical-path file changes, require recent /forge-review verdicts in the changeset
- OR: GitHub Action that runs /forge-review-equivalent in CI on PR open

**Effort:** ~4-8 hours depending on path. The hook path is local-only; the GitHub Action path is more portable but needs Claude Code SDK in CI.

---

## Tier C — bigger ideas, scope as needed

### C1. Treat the harness as a product

Versioning, release notes, deprecation policy. Per demo doc #10. The harness is currently changes-accrete; without versioning, every swarm rigor improvement risks colliding with the next one.

**Effort:** Multi-day. First step is just `~/harness/VERSION` + a changelog.

### C2. Production observability → AI session context

When the AI starts a session and the last commit lit up Crashlytics, auto-inline that into context. Per demo doc #12.

**Effort:** ~1-2 days. Extends SessionStart hook to query Firebase Crashlytics MCP for recent events on files this session might touch.

### C3. Contract-validator subagent (a second pair of eyes on the architect's output)

Per demo doc #11. The architect-post-review (A4 above) is the lighter version. C3 is the full version — a separate agent type with its own prompt, dedicated to contract-validation only. Worth doing once A4 is in place and we have N rounds of data on architect quality.

**Effort:** ~6-8 hours (agent definition + first run).

---

## How to use this backlog

1. Pick from Tier A first (highest leverage, contained scope).
2. For each item picked, create a ForgeOS changeset and link this doc.
3. When applied, move the item out of this doc and add a row to `.forgeos/wall-failures/derived-improvements.md`.
4. Tier B/C items get re-evaluated quarterly — some will be obsolete by then (e.g., if Claude Code adds first-class skill versioning, C1 changes shape).

This backlog is intentionally non-empty. The system should always have known improvements pending; the question is which leverage-per-hour ones to pick this cycle. If this doc ever shrinks to zero items, that means new wall-failure entries aren't being generated — which is either good (system is closing all gaps faster than they open) or bad (we stopped catching things). Re-evaluate.
