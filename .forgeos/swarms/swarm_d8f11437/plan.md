## Plan summary (for plan.md)

```markdown
# Swarm d8f11437 — 3.2.0 close-out wave 4

**Base branch:** `swarm/swarm_18b0d071-scaffold` (rebased PR #1023, which is stacked on rebased PR #1022).
**Risk bar:** Module A CRITICAL-PATH (architect + SoD). Module B CRITICAL-PATH (composition root — AppContainer). Module C STANDARD (script + skill + DoD doc edits).

## Scope

**Module A — SignInModal migration pass 2 of 2.** Migrates the remaining 11 call sites across 9 files from `SignInModalPresenter.presentSignInModal*` static API to AppContainer-injected `SignInModalSheetPresenter`. Removes `SignInModalHostingController` from `SignInModalView.swift` (the wave-3 no-op tomb). Deletes 4 obsolete `testShouldFireDismissCallback_*` predicate tests. Adds 3 NEW presenter state-transition tests (replacing what the deleted tests covered) AND 1 NEW true production-seam wiring test that drives `TPPReauthenticator().authenticateIfNeeded(...)` with a SPY presenter injected through `AppContainer.withSignInModalSheetPresenter(_:)` — closes wall-failure cs_9a267b63 (architect rev_bc20951b finding).

**Module B — AppContainer testability seam.** Adds `withSignInModalSheetPresenter(_:)` modifier on the `AppContainer` struct that returns a copy with an instance-local override field, falling through to the static cache when nil. Resolves the wall-failure entry's question: "AppContainer.production() is the static factory; test-time override requires…" — answer **Option (c) modifier** for SwiftUI idiom + struct composition + zero bloat of the existing 18-param init. ~25 net LOC.

**Module C — Runnable-grep rigor escalation (cs_9a267b63 permanent fixes 1, 2, 3).** Adds `scripts/check-test-name-vs-body.py` (NEW, ~150 LOC) that parses test method names embedding multi-step verbs (`Path`, `via`, `through`, `invokes`, `roundtrip`, `across`, `inProduction`, `viaX`), extracts the PascalCase production-class noun, greps the test body for instantiation or static call. Wires it into `.claude/skills/swarm/SKILL.md` Phase 4.5 check 5b as a real `python3` invocation that exits non-zero on failure. Extends `CLAUDE.md` DoD check #1 from file-level to method-level using the new script.

## Self-applied rigor (canonical: wall caught itself)

Module C's `check-test-name-vs-body.py` validates Module A's new tests during Phase 4.5. The script gates Module A's wiring test by name pattern: `testReauth_TPPReauthenticatorAuthenticateIfNeeded_drivesSpyPresenterViaAppContainerSeam` embeds `TPPReauthenticator` and `AppContainer`, so the body must call `TPPReauthenticator(` AND `AppContainer.production()` (the seam being used). If Module A ships a test that names the production class but never instantiates it (the cs_9a267b63 shape), Module C's script BLOCKS at Phase 4.5. The wall heals.

## Sequence

1. **Module C lands its script first** (so Phase 4.5 has it available). Module B's AppContainer seam lands in parallel.
2. **Module A** depends on Module B (Module A's wiring test calls `withSignInModalSheetPresenter`). Module A can begin parallel to B if the implementer agrees on the signature in advance; otherwise serialize A after B.
3. **Phase 4.5 orchestrator** runs `python3 scripts/check-test-name-vs-body.py PalaceTests/SignInLogic/SignInModalLifecycleTests.swift` AND `PalaceTests/SignInLogic/SignInModalPredicateTests.swift` (and every other modified PalaceTests/**.swift file). Block on non-zero exit.
4. **`/forge-review`** for SoD: architect + qa_test + clean_code reviewers for Modules A + B (critical-path). Module C gets clean_code only.
5. **PR stacked on #1023** → develop.

## Deferred to wave 5 (NOT this swarm)

- Remove the legacy `TPPPresentationUtils.safelyPresent` direct call from `SignInModalPresenter.presentSignInModal` (the static API still exists for backward-compat under wave 4; full removal would require deleting the static class). Tracked by a TODO comment in `SignInModalView.swift` after Module A's migration.
- Async variant of the sheet presenter (`func presentSignInModalForCurrentAccount() async -> Bool`) if any caller needs it — the existing `CoordinatorSignInModalPresenter` wraps `withCheckedContinuation` and stays as-is.

## Anti-scope (universal)

- `Palace/Audiobooks/` (PR stack collision).
- `Palace/Accounts/Library/AccountsManager.swift`, `Account+State.swift`, `AccountStateStore.swift` (wave 2 territory).
- `Palace/SignInLogic/TPPSAMLHelper.swift`, `TPPSignInBusinessLogic.swift` + category files (wave 3 Module B audit territory).
- `worktree-refactor-saml-auth` branch contents.
- `ios-audiobooktoolkit/`.
- The async-presenter variant (deferred to wave 5).
- Removing the static `SignInModalPresenter` class itself (wave 5; wave 4 just stops _calling_ it from production paths other than the production driver internal to `SignInModalSheetPresenter`).
```

---

