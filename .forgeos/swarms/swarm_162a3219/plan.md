# Swarm swarm_162a3219 — Phase 3.5 rollout + foreign-host-401 detector + Bug B + 30-day class-detectable audit

**Created:** 2026-06-05
**Architect:** Plan-subagent for Maurice (this transcript)
**Base ref:** `origin/develop` (post-PR #1044 merge target)
**Working branch:** `swarm/swarm_162a3219-scaffold`
**Worktree:** `.claude/worktrees/swarm_162a3219-orchestrator`

## Goal (one paragraph)

Following PR #1044's Icarus cross-host-logout fix, productize the "class-scan" reflex into the rigorous-fix and swarm skills as Phase 3.5 (META), build the first detector that codifies the PR #1044 wall (foreign-host 401 scoping), fix Bug B (audiobook playtimes tracker uploads cross-account requests after a library switch), and audit the last 30 days of resolved Palace iOS bugs to land up to 6 detectors for classes that recur. Each detector becomes a permanent wall — the one-time wipe catches current instances; the script catches future ones.

## Modules

| Module | Risk | Files | Est LOC | Implementer count | Depends on |
|---|---|---|---|---|---|
| A — Phase35-Meta | critical_path_meta | rigorous-fix/SKILL.md, swarm/SKILL.md, wall-failures/README.md + TEMPLATE.md, derived-improvements.md, docs/architecture/phase-3.5-class-scan.md | ~250 | 1 | — |
| B — ForeignHost401Detector | critical_path | scripts/check-foreign-host-401-scoping.py + tests + fixtures, verify-pr.sh wire-in, .claude/settings.json hook | ~250 | 1 | A (TEMPLATE convention) |
| C — AudiobookPlaytimesLifecycle | critical_path | Palace/Audiobooks/Tracker/AudiobookDataManager.swift, AudiobookSessionManager.swift (comment only), PalaceTests/Audiobooks/AudiobookPlaytimesLifecycleTests.swift, handoff doc | ~400 | 1 | — |
| D1 — LCPAcquisitionChainRecursiveDetector | critical_path | scripts/check-lcp-acquisition-recursive.py + tests + fixtures + wire-in + wall-failure entry | ~250 | 1 | A |
| D2 — SwiftUIPlaceholderA11yDetector | standard | scripts/check-swiftui-placeholder-a11y.py + tests + fixtures + wire-in | ~180 | 1 | A |
| D3 — CompletionNilErrorSuppressionDetector | critical_path | scripts/check-completion-nil-error-suppression.py + tests + fixtures + wire-in | ~220 | 1 | A |
| D4 — NSErrorProblemDocPreservationDetector | critical_path | scripts/check-nserror-problemdoc-preservation.py + tests + fixtures + wire-in | ~200 | 1 | A |
| D5 — NotificationCenterObserverStorageDetector | standard | scripts/check-notification-observer-storage.py + tests + fixtures + wire-in | ~200 | 1 | A |
| D6 — D-scan semantic | standard | docs only — .forgeos/swarms/swarm_162a3219/d-scan/*.md + .forgeos/followups/swarm_162a3219.md | ~60 | 1 | — |

**Total:** 9 implementers, ~2,010 LOC. Sizing well within swarm conventions.

## Module D audit findings (30-day Jira)

- **N tickets reviewed:** 50 (capped, JQL ran `project = PP AND issuetype = Bug AND status changed to (Done, Closed) AFTER -30d`)
- **iOS-relevant:** 11; non-iOS skipped (Android/CPW/CM/ANR Crashlytics)
- **Instance-only:** 1 (PP-3783 closed retroactively)
- **Class-semantic (D6 scan):** 3 — HelpSpot 17865 (NowPlaying BG freeze), PP-4420 (lock-screen freeze), PP-4326 (VoiceOver row activation)
- **Class-detectable:** 5 detectors built in D1-D5
- **Already covered:** PP-4537 = Module B (this same swarm)
- **Cap budget:** 6 detector slots; 5 used; 1 slot reserved for future re-prioritization
- **No follow-ups queued for ROAD ticket creation in this swarm** beyond the D6 outcomes (3 tickets filed at the end of D6)

## Parallelism plan

- **Wave 1 (parallel):** A, C, D6.
  - A is the docs convention (needed by B and the Dn series).
  - C is independent of A (it's production code).
  - D6 is observation-only and independent.
- **Wave 2 (parallel, after A merges):** B, D1, D2, D3, D4, D5.
  - All depend on Module A's TEMPLATE/README conventions for wall-failure entries.
  - All are detector + wire-in only; no cross-detector interaction.

In practice all 9 can run in parallel if implementers are willing to use the contract-documented Phase 3.5 convention even before Module A lands the docs (the spec in this plan + Module A's contract is sufficient). Recommend launching all 9 in one parallel dispatch.

## Risks

1. **Detector false-positive storm.** Static Python heuristics on Swift can over-flag. Each detector contract specifies an annotation escape (`// no-<wall-id>:`) and the implementer is required to wipe survivors. Risk: if predicted-0-survivors is wrong, the wipe scope grows. Mitigation: scope-deferral protocol applies per Phase 3.5 — implementer STOPs with BLOCKED + proposal if survivor wipe exceeds 50 LOC.

2. **Bug B (Module C) involves AppContainer wiring.** If `AudiobookDataManager` isn't currently DI'd through `AppContainer`, the closure-injection adds composition-root churn (BR-4 finding from `check-blast-radius.py`). Mitigation: the contract specifies grep-first ("`grep -n 'AudiobookDataManager(' Palace/`") to decide whether to wire through container.

3. **scripts/tests/ path divergence from existing scripts/test_*.py convention.** Task brief said `scripts/tests/test_check_foreign_host_401_scoping.py`; existing project convention is `scripts/test_check_*.py`. Contract resolves: tests at `scripts/test_check_foreign_host_401_scoping.py` (existing convention); fixtures at `scripts/tests/fixtures/foreign_host_401/` (new dir is fine — fixtures, not test runners). Flag at Phase 1a if Maurice wants the test runner location moved.

4. **Module C cross-vendor smoke rationale.** The contract explicitly binds the round-trip wiring test to ONE library-switch scenario (vendor-agnostic at the upload layer) rather than 4-vendor permutations, with rationale documented in the test file header. Risk: qa reviewer might insist on 4-vendor smoke per the `reference_audiobook_toolkit_risk_profile.md` framing. Mitigation: rationale is pre-justified in the contract; if qa blocks, the rationale lives in the test header for argument.

5. **PR #1044 still on `fix/icarus-cross-host-logout` branch — not yet merged into `origin/develop`.** Module B's scan target (`grep --scan Palace/`) needs to verify against the post-#1044 tree. The orchestrator worktree branches from `swarm/swarm_162a3219-scaffold` off `fix/icarus-cross-host-logout`, so `git diff origin/develop...HEAD` includes BOTH #1044's changes AND the swarm's. Verify-pr.sh, mutation, and detector greps all operate on the post-#1044 state correctly. Risk: if #1044 lands as a different SHA via squash-merge, the scaffold branch may need a rebase. Mitigation: document the rebase recipe in `.forgeos/swarms/swarm_162a3219/notes/post-1044-merge.md` if needed; not blocking dispatch.

6. **Module A's CLAUDE.md edit is minimal but in a section every reviewer reads.** Risk of bikeshedding. Mitigation: contract limits CLAUDE.md edit to a single 2-line cross-reference; the substantive Phase 3.5 content lives in the rigorous-fix/SKILL.md.

## Acceptance criteria (whole swarm)

- 7 contracts in `.forgeos/swarms/swarm_162a3219/contracts/` + plan.md + manifest.yaml committed on the scaffold branch (Phase 1b)
- Architect-review verdict APPROVED in `.forgeos/swarms/swarm_162a3219/architect-review.md` (Phase 1a non-skippable per swarm-manifest-v2 — multiple modules are `critical_path` and `critical_path_meta`)
- All 9 implementers complete with transcripts at `.forgeos/swarms/swarm_162a3219/transcripts/<MOD>.md`
- Phase 4.5 skeptic-pass checks 0-8 all PASS
- 3 SoD reviewer verdicts (architect, qa_test, blast_radius) APPROVED
- ForgeOS gates promoted; ADR submitted per contract
- `scripts/verify-pr.sh --quick` PASS
- Phase 5 wall-failure entry NOT required UNLESS a SoD review blocks (then per CLAUDE.md "Wall-failure catalog" 24h SLA)
- PR opened against `origin/develop` with `gh pr create`
- Bug B section of `.forgeos/handoffs/2026-06-05-icarus-cross-host-logout-regression.md` marked Resolved

## Phase 1a (architect post-review) — REQUIRED

Per swarm-manifest-v2 schema, architect post-review is non-skippable when ANY module is `risk: critical_path` or `critical_path_meta`. This swarm has 6 such modules (A, B, C, D1, D3, D4). Spawn `forge-architect-reviewer` before Phase 2 (changeset creation).
