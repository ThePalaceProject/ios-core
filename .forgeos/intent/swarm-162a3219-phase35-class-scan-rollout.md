---
name: swarm-162a3219-phase35-class-scan-rollout
created: 2026-06-05
author: claude-opus-4-7
swarm_id: swarm_162a3219
forgeos_changeset: cs_bc307eaf
forgeos_initiative: init_4a2ed3c9
tracking: PP-4436 (3.2.0 regression pass)
related_prs: ["#1044 (parent — fix/icarus-cross-host-logout)"]
---

## Summary

Multi-module swarm following PR #1044 retrospective. Three asks:

1. **Phase 3.5 class-scan rollout** — new phase in `/rigorous-fix` between Phase 3 (skeptic-pass) and Phase 4 (forge-review). When a new bug class is identified, scan codebase for other instances, wipe survivors in same PR, and codify a detector script that runs in verify-pr.sh + pre-commit. Tiered mechanism: grep → Explore subagent → dedicated detector script. The detector script is the load-bearing artifact, not the one-time wipe.

2. **First detector — `check-foreign-host-401-scoping.py`** — codifies PR #1044's class (auth misattribution → repeated logout). Predicate flags any 401 dispatch site missing current-account host scoping. Architect-revised to also catch `nsError.code == 401` / `error.code == 401` shapes. Surfaced 1 survivor at `Palace/Network/TPPNetworkExecutor.swift:582` (wiped via annotation per architect guidance — `capturedAccountId` is closure-bound, structurally scoped).

3. **Bug B — audiobook playtimes lifecycle** — completes PR #1044's deferred work. Cross-account scope guard on `AudiobookDataManager.syncValues()`; account-switch observer; queue preservation (no destructive clear); background-task counting fix so `endBackgroundTask` fires when every entry is cross-account.

4. **30-day Jira resolved-bug class audit** — Architect ran `mcp__jira__jira_search` on the last 30 days. iOS-relevant subset: 11 bugs. 5 class-detectable bugs surfaced 5 detectors (D1-D5); 3 class-semantic bugs went to a D-scan (D6) with follow-up tickets queued.

## Claims

### Module A — Phase 3.5 META-TOOLING

- Inserts Phase 3.5 — Class scan section into `.claude/skills/rigorous-fix/SKILL.md` between Phase 3 and Phase 4.
- Adds Phase 4.0a class-scan reconciliation paragraph + Phase 4.5 check 6.4 to `.claude/skills/swarm/SKILL.md`.
- Updates `.forgeos/wall-failures/README.md` with new "Detector requirement" subsection — every wall-failure entry MUST include either a `detector_script:` reference OR explicit `no-detector — <reason>` justification.
- Updates `.forgeos/wall-failures/TEMPLATE.md` — frontmatter `detector_script` / `detector_status` / `no-detector` fields + new `## Detector script` body section.
- Adds row to `.forgeos/wall-failures/derived-improvements.md` cluster-fix table.
- Adds new `docs/architecture/phase-3.5-class-scan.md` — rationale + 5-step loop + 3-tier mechanism + 6-detector table.
- 2-line cross-reference paragraph in main repo `CLAUDE.md` under "Wall-failure catalog" section.

### Module B — Foreign-host 401 detector

- Adds `scripts/check-foreign-host-401-scoping.py` (~290 LOC). Phase-1a-revised predicate matches `statusCode == 401` / `nsError.code == 401` / `error.code == 401` / `(error as NSError).code == 401`.
- Adds `scripts/tests/test_check_foreign_host_401_scoping.py` — 6 pytest cases.
- Adds 4 fixtures under `scripts/tests/fixtures/foreign_host_401/`.
- Wipes survivor at `Palace/Network/TPPNetworkExecutor.swift:582` via `// no-host-scoping:` annotation (closure-bound `capturedAccountId` is structurally scoped).
- Updates `.forgeos/wall-failures/2026-06-05-pr1018-icarus-cross-host-logout.md` with `detector_script:` frontmatter + Detector script body section.

### Module C — Audiobook playtimes lifecycle (Bug B)

- Adds `currentAccountIdProvider: () -> String?` init parameter on `AudiobookDataManager` (default closure reads `AppContainer.production().accountsManager.currentAccountId`). No PUBLIC_INTENT annotation needed per Phase-1a review (internal class, not Container file → BR-4 does not fire).
- Adds `subscribeToAccountChanges()` observer on `.TPPCurrentAccountDidChange` — log-only, no destructive queue clear.
- Adds cross-account scope guard in `syncValues()` inner loop — skip POST when `libraryBook.libraryId != currentAccountIdProvider()`, preserve entries for later flush.
- Adds background-task counting fix so `endBackgroundTask` still fires when every entry is cross-account.
- Adds comment block at `Palace/Audiobooks/AudiobookSessionManager.swift` documenting the contract.
- Adds 6 new tests in `PalaceTests/Audiobooks/AudiobookPlaytimesLifecycleTests.swift` (NEW). Cross-vendor smoke covered by vendor-agnostic upload endpoint (documented in test header).
- Adds `PalaceTests/Mocks/SpyAudiobookNetworkExecutor.swift` (NEW).
- Updates `.forgeos/handoffs/2026-06-05-icarus-cross-host-logout-regression.md` with Bug B resolution log.

### Module D1 — LCP acquisition recursive detector (PP-4407 + PP-4454)

- Adds `scripts/check-lcp-acquisition-recursive.py` (~250 LOC). Predicate flags `defaultAcquisition + LCP-MIME` without recursive walk.
- Adds 6 pytest cases + 5 fixtures.
- Wipes survivor at `Palace/Audiobooks/LCP/LCPAudiobooks.swift:200-202` (delegates to canonical `hasLCPAcquisition`).
- Adds `.forgeos/wall-failures/2026-06-05-pp4407-lcp-acquisition-recursive.md`.

### Module D2 — SwiftUI placeholder a11y detector (PP-4421)

- Adds `scripts/check-swiftui-placeholder-a11y.py` (~300 LOC). D2-1 (TextField/SecureField) + D2-2 (Button label-closure) predicates. NavigationLink/Link/Menu false-positive exclusion.
- Adds 4 pytest cases + 4 fixtures.
- Wipes 3 survivors: `MyBooksView.swift:161`, `TPPPDFSearchView.swift:40`, `EPUBSearchView.swift:51` (canonical `prompt: Text(label).foregroundColor(.secondary)` pattern).
- Adds `.forgeos/wall-failures/2026-06-05-pp4421-swiftui-placeholder-a11y.md`.

### Module D3 — completion-nil-error suppression detector (PP-4419)

- Adds `scripts/check-completion-nil-error-suppression.py` (~510 LOC with docstring). Phase-1a-revised predicate requires top-level String-typed args 2-N; explicitly excludes `completion?(nil, nil, nil)` OAuth success path.
- Adds 8 pytest cases (including anti-regression test against live OAuth file) + 7 fixtures.
- No production wipes (PR547e185aa already addressed the known cases).
- Adds `.forgeos/wall-failures/2026-06-05-pp4419-completion-nil-error.md`.

### Module D4 — NSError problemDocument preservation detector (PP-3956)

- Adds `scripts/check-nserror-problemdoc-preservation.py` (~370 LOC). Predicate matches function-scope NSError construction discarding in-scope `TPPProblemDocument` context.
- Adds 5 pytest cases + 5 fixtures.
- 0 production survivors (PR #935 already preserved problemDoc at the only function with TPPProblemDocument in scope).
- Adds `.forgeos/wall-failures/2026-06-05-pp3956-nserror-problemdoc.md`.

### Module D5 — NotificationCenter observer storage detector (PP-4329)

- Adds `scripts/check-notification-center-observer-storage.py` (~360 LOC). Supports multi-line `addObserver(forName:object:queue:using:)` call shape (per PP-4329's canonical fix at TPPAppDelegate.swift:473).
- Adds 6 pytest cases + 5 fixtures.
- Annotates 2 NotificationService.shared observers (app-lifetime singleton; deinit on `static let` never fires).
- Adds `.forgeos/wall-failures/2026-06-05-pp4329-notification-observer-leak.md`.

### Module D6 — D-scan semantic class report

- Pure scan report at `.forgeos/swarms/swarm_162a3219/transcripts/D6.md`.
- Class 1 (Timer-during-background): 1 true positive at `PlaybackReadinessGate.swift:334-359` — proposed as follow-up ticket.
- Class 2 (Missing VoiceOver action): 4 instances in `AudiobookMiniPlayerView`, `AccountDetailView.ageCheckCell`, `TypographySettingsView.fontFamilySection`, `BadgesView.badgeSection` — proposed as 4 follow-up tickets.
- Total ~25 LOC effort across 5 proposed follow-up tickets.

### Integrator (orchestrator) wire-ins

- Wires 6 detectors into `scripts/verify-pr.sh` (block + warn modes per detector class).
- Adds `scripts/pre-commit-phase35-detectors.sh` — consolidated pre-commit hook running all 6 detectors against the staged diff; per-detector bypass envvars.
- Wires the consolidated hook into `.claude/settings.json` PreToolUse Bash matcher block.

## Anti-claims (out of scope)

- Does NOT modify `Palace/Network/TPPNetworkExecutor.swift` HTTP/3 disable / offline retry queue.
- Does NOT modify `URLResponse+TPPAuthentication.isSameDomain` — base-domain helper stays for biblioboard CDN guard.
- Does NOT modify `AuthCoordinator.swift` recovery strategy / dispatch matrix.
- Does NOT forward-port any fix into `release/*` / `hotfix/*` branches.
- Does NOT modify `PalaceAudiobookToolkit` Carthage release flow.
- Does NOT rewrite the playtimes tracker broadly — Module C is strictly cross-account scope guard.
- Does NOT touch `Palace/PDF/LCP/LCPPDFs.swift` (same legacy pattern exists at line 35-38; out of Module D1 scope; flagged as follow-up).
- Does NOT touch the 3 D6 semantic classes — Explore-only scan with 5 follow-up tickets queued.
- Does NOT consolidate the 6 detectors into a single mega-detector — each is independently testable and bypass-able.

## Files in scope

Listed under per-module Claims sections above. Total: 6 detector scripts + 6 pytest harnesses + ~25 fixtures + 6 wall-failure entries + Phase 3.5 docs + Bug B production+tests + 6 production wipes + 4 governance docs (`SKILL.md` ×2, `README.md`, `TEMPLATE.md`) + integrator wire-ins (`verify-pr.sh`, `pre-commit-phase35-detectors.sh`, `settings.json`).
