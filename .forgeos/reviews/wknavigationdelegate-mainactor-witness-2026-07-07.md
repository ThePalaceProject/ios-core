<!-- audit-verified -->
# WKNavigationDelegate @MainActor witness fix — SoD review record (2026-07-07)

Local in-session Separation-of-Duties review (ForgeOS OFF). Critical-path (sign-in / web
navigation). Two independent reviewers, both APPROVE.

## rev_a70be5c0 — SoD-A (soundness / concurrency) — APPROVE
All 6 points CONFIRMED-SOUND: (1) `@MainActor` class → methods legitimately `@MainActor`,
exactly matching the `WK_SWIFT_UI_ACTOR` SDK witness; (2) synchronous `decisionHandler`
on the main actor is correct + single-invocation per path; (3) cancel-before-await
ordering + `self`/`viewModel` capture into the `@MainActor` cookie Task is sound; (4)
`DecisionHandlerBox` fully removed, zero dangling refs, no unsafe `@Sendable` capture; (5)
compiles under both develop (5.0/targeted) and Phase C (6.0/complete) — `@escaping
@MainActor` is Swift-5.5+ valid and the SDK protocol is `@MainActor` regardless of app
Swift version; (6) Bundled/Remote nested-delegate witnesses aligned. Scope-complete: all
3 `decidePolicyFor` sites migrated, no 4th. The pre-existing integration test genuinely
guards the fix path.

## rev_a42075fe — SoD-B (behavior-preservation) — APPROVE
All 5 points PRESERVED/IMPROVED: (1) `decideAction` decision + `recordLoginCompletion`
cookie logic unchanged; (2) `navigationResponse` `.bookFound`/`.problemFound` paths
preserved (problemFound kept synchronous); (3) IMPROVED — synchronous dispatch removes the
old decision-timeout race; (4) Bundled/Remote external-link `.linkActivated` logic
byte-identical; (5) no regression from restoring the delegate — the broken allow-all state
was wrongly navigating external links in-app; the fix restores correct OS-open behavior and
does not over-cancel (non-linkActivated navs still `.allow`).

VERDICT (both): APPROVE. No blocking items.

## Mutation note
No diff-scoped mutation evidence: this is a delegate signature/isolation fix with NO
branch-logic change — the `decideAction`/`decideResponse` switch cases are unchanged
(only relocated from a `Task` to a synchronous call), so the diff-scoped mutation surface
is ~0. Behavior is covered by `SignInWebSheetIntegrationTests` (34 tests, 0 failures; the
universal-links test flips from a reliable 30s hang to a 0.76s pass — it exercises the
restored delegate path end-to-end via a real WKWebView).
