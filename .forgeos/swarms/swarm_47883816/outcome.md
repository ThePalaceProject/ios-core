# Swarm swarm_47883816 — Outcome

## Status

**complete** — 2026-06-04

Test-pollution sweep landed. All 6 contracts (A–F) integrated, 3 reviewer
verdicts APPROVED, ForgeOS evidence + ADRs submitted.

## Modules touched

- **A — AppContainerIsolation** — `TestAppContainerFactory` + lint, ~303/636
  sites migrated, 71-file deferred list with shrink-only ratchet.
- **B — AccountsManagerIsolation** — `makeFreshAccountsManager()` promoted
  from convention to lint-enforced seam; 17 sites in 10 files migrated.
- **C — TPPUserAccountIsolation** — `TPPUserAccountTestFactory.makeIsolated`
  with UUID-namespaced libraryUUID + `SingletonResetRegistry` resetter; 31
  `sharedAccount` sites migrated.
- **D — UserDefaultsIsolation** — `XCTestCase.testUserDefaults()` + minimum
  prod DI on `TPPSettings` and `RemoteFeatureFlags` (no fallback,
  default-arg preserves callers).
- **E — MetaTestsLintExpansion** — `MockIsolationLintTests` scope broadened
  to `PalaceTests/**`; `TearDownRequiredLintTests` added with 37-file
  baseline-shrink ratchet.
- **F — FireAndForgetAudit** — pure audit; transcript at
  `.forgeos/swarms/swarm_47883816/transcripts/F-audit.md`. Category-3
  findings filed as follow-up tickets.

## Files changed

71 files, +5438 −488 LOC (vs `origin/develop`).

## Tests added

71 new test cases across 9 new test classes — all PASS:

- `TestAppContainerFactoryTests`
- `AppContainerIsolationLintTests`
- `AccountsManagerIsolationLintTests`
- `TPPUserAccountTestFactoryTests`
- `TPPUserAccountIsolationLintTests`
- `XCTestCase_testUserDefaultsTests`
- `UserDefaultsIsolationLintTests`
- `MockIsolationLintTests` (broadened)
- `TearDownRequiredLintTests`

xcresult bundles: `/tmp/swarm_47883816_integrate/Logs/Test/`.

## Reviewer verdicts

All three SoD reviewers APPROVED (with 2 non-blocking warnings, both
pinned to deferred-list scope):

| Role | Review ID | Verdict |
|---|---|---|
| architect | `rev_3d7c432d` | APPROVED (1 non-blocking warning on A-deferred-list size) |
| qa_test | `rev_5f8e37a9` | APPROVED |
| security / blast-radius | `rev_1dfc9e56` | APPROVED (1 non-blocking note on prod DI default-arg) |

## ADRs submitted

Five ADRs submitted via `forge_submit_evidence` (one per contract A–E;
F is audit-only, no architectural decision). Submitted as `ai_review`
type because the MCP `architecture_decision` type requires structured
metadata fields (`decision`, `context`, `consequences`, `area`) that are
not exposed through the current MCP tool surface — ADR content encoded
inline in the summary instead.

| ADR | Evidence ID | Topic |
|---|---|---|
| A | `ev_ebf0116d` | AppContainerIsolation — TestAppContainerFactory + phased Option (b) |
| B | `ev_1273b472` | AccountsManagerIsolation — lint-enforced seam |
| C | `ev_2439c323` | TPPUserAccountIsolation — UUID-namespaced + resetter |
| D | `ev_92900a2f` | UserDefaultsIsolation — testUserDefaults() + minimum prod DI |
| E | `ev_5539e931` | MetaTestsLintExpansion — baseline-shrink ratchet |

## Other evidence submitted

| Evidence ID | Type | Notes |
|---|---|---|
| `ev_0a601711` | `unit_test` | 71 new test cases PASS across 9 classes |
| `ev_a67807a9` | `lint` | 5 universal-rigor lint scripts exit 0 |

## Lessons learned

- **Intent-file token-match gate UX** — pre-commit M1
  `check-intent-recorded` matches claims against intent claims via
  substring tokens; long structured-list claims got false-negatives until
  the intent was tightened to use the same nouns the orchestrator
  proposed. Worth a token-set vs. token-bag tweak in a follow-up.
- **COMMIT_EDITMSG read order in M1 hook** — when the commit message is
  amended mid-loop, the contract-reconciliation hook reads the staged
  message before the editor commits the new one; surfaced as transient
  "claim missing" failures. Documented in transcript; harness-side fix
  is a stage-after-write reorder.
- **Scope-deferral discipline pays off** — Contract A landed Option (b)
  cleanly with the 71-file deferred list precisely because architect
  declared the budget gap up front. No reviewer block on partial-ship.
  This is the canonical "BLOCKED: scope reduction proposal" pattern
  per CLAUDE.md.
- **MCP `architecture_decision` type unusable from current tool surface** —
  server enforces structured metadata fields the MCP tool doesn't accept.
  Recorded ADRs as `ai_review` with inline structure as a workaround;
  upstream fix tracked as harness follow-up.
- **MCP `forge_promote_gate` enum mismatch with project gates** — schema
  enum is `intent|design|implementation|verification|hardening|release`
  but this project's preset gates are `review|testing|release`. All
  promote calls rejected with "missing required artifact(s): unknown".
  Gates left un-promoted via MCP; gate state is otherwise satisfied
  (all evidence + all reviewer roles present). Promotion path tracked
  as harness follow-up (`forge_promote_gate` should either accept the
  project-template gate IDs or route them through a mapping layer).

## Wall-failure entries created

**NONE** — no reviewer BLOCKs landed during this swarm. All three reviewer
verdicts came back APPROVED. Non-blocking warnings were addressed inline
(comment-marker pattern for C identity test; size cap on deferred list).

## Follow-up scope

Deferred items tracked and ready for follow-up swarms / tickets:

- **A-deferred-files.txt** — 71 files with `AppContainer.production()`
  outside the migrated top-concentration set. Shrink-only ratchet
  enforced by lint. Critical-path files (BookReturnService*,
  AudiobookSessionManager*, TPPSignInOIDCTests, CredentialGuardTests,
  TokenRefreshAndRetryQueueTests) flagged in architect review for
  priority in next swarm.
- **C in-memory backend** — TPPUserAccount in-memory keychain storage
  requires `#if DEBUG` init seam accepting `TPPKeychainStorage` protocol;
  deliberately out of scope per intent anti-claim. Follow-up ticket.
- **D-deferred-production-DI.md** — 87 other `UserDefaults.standard`
  production sites awaiting DI seams. Per-site audit at time of next
  pass.
- **F-audit follow-up tickets** — 5 follow-up tickets filed for
  category-3 (production fire-and-forget reachable from tests) findings.
  Ticket IDs cited in `transcripts/F-audit.md`.
- **MCP promote-gate enum reconciliation** — harness follow-up to make
  `forge_promote_gate` honor project-template gate IDs.
- **MCP architecture_decision metadata path** — harness follow-up to
  expose `metadata` parameter so future ADRs can use the canonical type.

## Reviews directory

`reviews/` contains the three reviewer verdicts:

- `architect.md` → `rev_3d7c432d`
- `qa_test.md` → `rev_5f8e37a9`
- `blast_radius.md` → `rev_1dfc9e56`
