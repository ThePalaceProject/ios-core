## Plan summary (for plan.md)

```markdown
# Swarm 18b0d071 — 3.2.0 close-out wave 3

**Base branch:** `swarm/swarm_51f248d5-scaffold` (PR #1022, stacked on PR #1020).
**Risk bar:** Module A CRITICAL-PATH (architect + SoD). Module B CRITICAL-PATH (architect + SoD; SAML has 25+ historical regressions). Module C bundled into Module B (1-3 lines comment).

## Scope

**Module A — SignInModal SwiftUI presenter foundation (wave 3 / part 1 of 2).**
Introduces a `@MainActor ObservableObject SignInModalSheetPresenter` that wraps the existing `SignInModalPresenter` static API and exposes a SwiftUI-observable `presentationState` published property. The presenter internally still routes through `TPPPresentationUtils.safelyPresent` to preserve HelpSpot 17716's presenter-chain safety net (decision: Blocker 2 Option c). Migrates exactly ONE caller (`TPPReauthenticator.swift`) to the new presenter to prove the pattern; the other 9 callers stay on the legacy static API. `SignInModalHostingController` STAYS in wave 3 (deletion deferred to wave 4 once all callers are migrated). 3 new SwiftUI-lifecycle tests; 4 existing `SignInModalPredicateTests` stay green unchanged.

**Module B — SAML hardening + AccountsManager:967 comment expansion.**
SAML refactor's Phases 1-3 + most of 4-5 already landed via swarm_ea663ab6. Wave 3 Module B is a hardening pass: audit `LegacySAMLAuthAdapter.swift` for any `DispatchQueue.main.asyncAfter` workarounds (none expected; verifying), add 2 cookie-expiration edge-case tests to TPPSAMLFlowTests.swift (mixed expired + valid; all-expired), add explicit forward-compat comment at AccountsManager.swift:967-981 documenting the `AccountEvictionReason` switch-arm decision (re-drive vs not-re-drive). Module C is bundled here.

## Self-applied rigor (CLAUDE.md DoD check #7 + try-await/await contract clause from PR #1022)

Both contracts include:
- For every `try await` / `await` boundary introduced in production code: a grep showing a test drives that exact line via the public entry point.
- For every multi-step test name (`across`, `viaX`, `roundtrip`, `presentedThenBackgrounded`, etc.): line-coverage evidence on the cited production lines.
- For every new test file `<SUT>Tests.swift`: a `grep -c "<SUT>("` check ≥1.

## Deferred to wave 4 (NOT this swarm — explicit per Blocker 3 Option b)

- Migrate the 9 remaining `SignInModalPresenter.presentSignInModal` call sites to the new `SignInModalSheetPresenter`.
- Remove `SignInModalHostingController` from `SignInModalView.swift`.
- Remove the legacy `TPPPresentationUtils.safelyPresent` direct call from `SignInModalPresenter.presentSignInModal`.
- Replace the `cookies` duplication between `TPPSignInBusinessLogic` and `TPPSAMLHelper` (the line 189-192 TODO).

## Sequence

1. Module A and Module B can run in parallel (file-disjoint).
2. Orchestrator integrates both, runs `scripts/verify-pr.sh --quick`.
3. `/forge-review` for SoD: architect (this) + qa_test + clean_code reviewers.
4. PR stacked on #1022 → develop.

## Anti-scope

- `Palace/Audiobooks/` (PR #1020 collision).
- `.claude/skills/swarm/SKILL.md`, `.claude/skills/rigorous-fix/SKILL.md`, `CLAUDE.md` rigor sections (already shipped in PR #1022).
- `worktree-refactor-saml-auth` branch contents.
- `ios-audiobooktoolkit/`.
- Migrating the 9 remaining SignInModal callers (wave 4).
- Removing `SignInModalHostingController` (wave 4).
```

---

