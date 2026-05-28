---
name: audit-phase7-synthesis-2026-05-26
type: ephemeral
status: active
created: 2026-05-26
last_refresh: 2026-05-26
freshness_window: 180d
owners: [mybooks]
description: Phase 7 siblings audit — synthesis (2026-05-26)
---

# Phase 7 siblings audit — synthesis (2026-05-26)

Three parallel subagents audited `DownloadStartDispatcher`, `DownloadAuthRetryHandler`, and `BookButtonMapper` for F-011 / F-014 / F-017-class regressions following the patterns documented in `phase7_borrow_path_regressions_2026_05_14.md`.

## Verdict

**No live defects. 12 test gaps. 1 build-system fix needed.**

| File | BUG | NEEDS-TEST | CLEAN |
|---|---:|---:|---:|
| `DownloadStartDispatcher` | 0 | 6 | 1 |
| `DownloadAuthRetryHandler` | 0 | 3 | 4 |
| `BookButtonMapper` | 0 | 3 | 1 |
| **Total** | **0** | **12** | **6** |

All three files match the 3.0.2 inline equivalents byte-for-byte on the relevant control-flow surfaces (verified via `git show 3.0.2:Palace/MyBooks/MyBooksDownloadCenter.swift` comparisons in each subagent's report). The Phase 7 decomposition did NOT introduce silent F-011/F-014/F-017 siblings in these classes.

The risk surface that remains is test coverage, not production code: 12 mutants would survive across the three test suites. Until those tests are tightened, a future PR touching these files could regress them without CI noticing.

## Highest-priority findings

### 1. `BookButtonMapper` not on the strict mutation-gate critical path (build system bug)

`scripts/verify-pr.sh:73` regex: `^Palace/(Audiobooks|SignInLogic|MyBooks/Download)`. `Palace/Book/UI/BookDetail/BookButtonMapper.swift` does not match. Memory pin `phase7_borrow_path_regressions_2026_05_14` explicitly flags this file as belonging to the strict list. **Fix is one regex update.**

### 2. `BookButtonMapper.SAMLStarted` falls through to `.unsupported` silently (F-011 shape, latent)

`BookButtonMapper.swift:53-57` — the if-cascade has no explicit `.SAMLStarted` branch. The state reaches the mapper (verified via grep against current `TPPBookState`) and produces `.unsupported`. Zero tests pin this. **Same risk class as the original F-011** (silent fall-through on a real enum case). Any new `TPPBookState` case added later inherits the same trap.

**Fix shape:** convert the if-cascade to an exhaustive `switch state` (no `default:`) + add `for state in TPPBookState.allCases` parameterized test that asserts each case produces a defined non-`.unsupported` mapping or explicitly documents `.unsupported` as intentional. This is the safety net the prelude recommends.

### 3. `DownloadAuthRetryHandler:229` `attemptDownload: true` parameter is unpinned (F-014 shape)

The handler passes `attemptDownload: true` to `startBorrow` on the auto-borrow path — but `SpyDelegate.startBorrow` in `DownloadAuthRetryHandlerTests.swift` drops the parameter entirely. Flipping `true → false` survives every test. **Same surface where F-014 originally lived** in `BorrowOperation`.

**Fix shape:** spy delegate captures `attemptDownload`; tests assert `spy.startBorrowCalls.first?.attemptDownload == true`.

### 4. `DownloadAuthRetryHandler:235` post-borrow state predicate uncovered

`newState != .downloading && newState != .downloadSuccessful` runs only when `borrowCompletion` is invoked — and the audit subagent found a comment in the test admitting `borrowCompletion` is never invoked under test. Three mutants survive on that line. F-014 shape.

### 5. `DownloadStartDispatcher` borrow-routing branch covers only 2 of 10 `TPPBookState` cases (NEEDS-TEST-4)

The dispatcher's `processDownloadWithCredentials:121` checks `state == .unregistered || state == .holding` to route to borrow. The test suite pins only those two cases. A regression that ALSO routed (say) `.downloadNeeded` to borrow would not fail any test. **Highest-leverage gap of the six in this file.**

**Fix shape:** parameterized test over `TPPBookState.allCases.subtract([.unregistered, .holding])` asserting `spy.startBorrowCalls` stays empty.

## Other findings (summarized)

| ID | File | Pattern | Severity |
|---|---|---|---|
| NT-1 | `DownloadStartDispatcher:152` | Expired re-borrow branch — no test exercises `isExpired == true` | Medium |
| NT-2 | `DownloadStartDispatcher:166` | Auto-borrow completion guard — closure never invoked under test | Medium |
| NT-3 | `DownloadStartDispatcher:61` | `isWifiOnlyEnforced` — only 1 of 4 boolean combinations tested | Low |
| NT-5 | `DownloadStartDispatcher:161` | `setState(.unregistered, ...)` registry reset not asserted | Low |
| NT-6 | `DownloadStartDispatcher:200` | SAML branch — no test for `.SAMLStarted` without cookies, etc. | Medium |
| NT-7 | `DownloadAuthRetryHandler:.credentialPrompt` strategy | No direct test (compile-time exhaustivity is primary defense) | Low |
| NT-8 | `BookButtonMapper:22` `.returning + isProcessingDownload` priority | Boundary unpinned — refactor mutant survives | Medium |

## Suggested follow-up PRs

1. **`fix(verify-pr): add BookButtonMapper to strict mutation-gate regex`** (1-line change, finding #1)
2. **`test(BookButtonMapper): exhaustive switch + .allCases parameterized test`** (finding #2; closes F-011 sibling window permanently)
3. **`test(DownloadAuthRetryHandler): capture attemptDownload in SpyDelegate + assert on auto-borrow path`** (findings #3, #4)
4. **`test(DownloadStartDispatcher): parameterize borrow-routing branch over TPPBookState.allCases`** (finding #5; closes the highest-leverage F-011 sibling)
5. (Lower priority) round out the remaining NT-1 through NT-8 gaps in follow-up commits.

## Methodology evaluation — did the subagent-prelude shift reasoning?

This audit doubled as a real-world test of the `harness subagent-prelude --domain mybooks` capability landed earlier today. Honest assessment:

**The prelude was load-bearing in three observable ways:**

1. **Pattern definitions made findings precise.** All three subagents used the F-011 / F-014 / F-017 vocabulary verbatim in their reports — "F-014 shape," "F-011 latent" — anchoring each finding to a specific failure mode rather than vague "this could break." Without the prelude, a generic audit subagent would describe these as "missing test for branch X" without the framing.

2. **The prelude's "for state-machine switches, the exhaustive-switch + `.allCases` parameterized test is the safety net" sentence appears in TWO of the three subagent reports as the recommended fix shape.** The BookButtonMapper subagent in particular proposed the exact `for state in TPPBookState.allCases` test pattern that memory pin documents — that's the prelude propagating into design decisions, not just framing.

3. **Cross-reference to other memory ("`Reachability subscriptions come in pairs`", "isProcessingDownload short-circuits before `.downloadNeeded`") was used as a search heuristic.** The BookButtonMapper subagent specifically tested the "what if `.returning` leaked into the short-circuit predicate?" hypothesis — a question only the prelude content would prompt.

**Caveats:**

- The audit found ZERO live bugs, so I can't conclusively prove the prelude prevented a wrong diagnosis. The counter-test (run the same audit cold) would burn parallel-agent budget unnecessarily for a session that already produced its result.
- The 12 NEEDS-TEST findings are real but lower-stakes than a live bug would be. The prelude's real ROI shows up on bug fixes / refactors, not read-only audits.
- The prelude IS 193 lines of context per subagent dispatch. For tasks where domain knowledge isn't load-bearing, that's overhead. The branch-aware SessionStart hints + per-task discretion remain the right model — don't blindly include the prelude.

**Net:** the capability worked as designed. The artifacts (`.forgeos/audits/phase7-*.md`) are concrete proof. Recommend continuing to use it for multi-agent investigations in well-covered SharedMind domains (audiobook, accounts, mybooks).

## Sources

- Per-file audits: `.forgeos/audits/phase7-{DownloadStartDispatcher,DownloadAuthRetryHandler,BookButtonMapper}.md`
- Subagent prelude generated: `harness subagent-prelude --domain mybooks` (193 lines)
- Memory pin: `phase7_borrow_path_regressions_2026_05_14.md`
- Test patterns reference: `feedback_test_patterns_phase7.md`
- Verify-pr.sh: `scripts/verify-pr.sh:73` (the regex that needs `BookButtonMapper` added)
