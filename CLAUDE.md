# Palace iOS Core

Library reading app supporting EPUB, PDF, and audiobooks with multiple DRM systems.

## Contributing & Development Workflow

**Outside contributors:** standard GitHub flow — fork the repo, branch from `develop` (never `main`), open a PR back to `develop` when ready. Tests are mandatory for production changes (see [TDD & Test Quality](#tdd--test-quality--mandatory) below).

**Maintainers** additionally run through ForgeOS governance gates (changeset → evidence → review → promote). That tooling is in `scripts/forgeos-*.sh` and is exercised via the local-only `.claude/settings.json` PreToolUse hooks. Outside contributors can ignore those scripts; they no-op gracefully without an API key.

**Pre-PR self-check (anyone):** `scripts/verify-pr.sh --quick` runs the full battery — build, tests, lint, coverage, accessibility — against the iPhone 16 Pro simulator. JSON report optional: `--report /tmp/v.json`.

**Architecture decisions:** see [`docs/architecture/`](./docs/architecture/) for the rationale behind major refactors (the post-modernization triad work, the parallel-agent rebase pattern, post-PR retros).

## Release & hotfix merge policy

**Merges into `main` use regular merge commits (`--no-ff`), never squash.** Applies to:
- `release/X.Y.Z` → `main` (full release cycle)
- `hotfix/X.Y.Z-*` → `main` (point hotfix)
- Forward-port merges of those hotfix branches into `develop` (so the next release branch absorbs them with original SHAs)

`gh pr merge <num> --merge` — NOT `--squash`.

**Why:** squash-merge replaces a branch's commits with a single new commit that has no SHA-level relationship to the original work. When the next release branch tries to merge into main, git treats the squashed commits as different history from the original commits the release branch absorbed via forward-port — even though the content is logically identical. The result is a conflict storm that's pure squash-merge identity loss, not real divergence.

This is what happened to 3.1.0: PR #953 (3.0.2 hotfix) and PR #972 (3.0.3 hotfix) were squash-merged into main, then `release/3.1.0 → main` produced **296 conflicts** that all had to be resolved manually before the release could ship. PR #998 ultimately landed via a custom merge commit built with `git commit-tree`. See [`docs/architecture/release-merge-policy.md`](./docs/architecture/release-merge-policy.md) for the full forensic + the recovery recipe.

**Squash-merge is fine for feature PRs into `develop`** (or any branch that doesn't feed back into main). The damage is specifically squash on commits that later need to be reconciled by another branch — that's a release-branch-to-main scenario, not a feature-to-develop one.

**Branch protection:** `main` should be configured to allow only "Create a merge commit" — disable both "Squash and merge" and "Rebase and merge" in repo settings → branch protection rules. UI change; verify periodically.

## Build & Test

```bash
# Build (use xcodeproj, NOT workspace — workspace hits Firebase SPM issues).
# Replace SIM_ID with your iPhone simulator UDID:
#   xcrun simctl list devices iPhone | grep Booted
xcodebuild -project Palace.xcodeproj -scheme Palace \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build

# Run all tests
xcodebuild -project Palace.xcodeproj -scheme Palace \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test

# Run a single test class
xcodebuild -project Palace.xcodeproj -scheme Palace \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:PalaceTests/MyTestClass test
```

- Xcode 26, iOS 16.0+ deployment target (CI release path: `macos-26` + `xcode-version: '26'`)
- Two targets: `Palace` (full DRM) and `Palace-noDRM` (open-source)
- DRM builds run natively on Apple Silicon — Rosetta is no longer required

## Project Structure

```
Palace/
  AppInfrastructure/   # App launch, Firebase, navigation, AppContainer DI root
  Accounts/            # Library account management
  Book/                # Book models and detail views
  MyBooks/             # Downloaded books management
  Catalog/             # Catalog UI and data (legacy)
  CatalogDomain/       # Catalog API, repositories, parsing
  CatalogUI/           # Catalog SwiftUI views
  Audiobooks/          # Audiobook playback management
  Reader2/             # EPUB reader (Readium 3.x, SwiftUI)
  Reader3/             # PDF reader
  OPDS/                # OPDS 1.x parsing (Objective-C)
  OPDS2/               # OPDS 2.0 parsing and services
  SignInLogic/         # Authentication flows (OAuth, SAML, basic, OIDC)
  Network/             # HTTP networking layer
  Keychain/            # Secure credential storage
  Holds/               # Reservations / holds flows + HoldsReducer
  Utilities/           # Extensions, helpers, concurrency
  Migrations/          # App upgrade migrations

PalaceTests/
  Mocks/               # 21 shared mock implementations
  ViewModels/          # ViewModel + reducer unit tests
  Network/             # Network layer tests
  Snapshots/           # UI snapshot tests
  (organized by feature area)

PalaceConfig/          # Assets, certs, plists
scripts/               # Build, test, release automation
docs/                  # Architecture decisions + testing posture
```

## Architecture

- **MVVM + Services + Reducers** — ViewModels are `@MainActor ObservableObject` with `@Published` properties; critical-path state machines extracted into pure `Reducer.reduce(state, action) -> Effect` functions
- **`AppContainer`** — single composition root in `Palace/AppInfrastructure/AppContainer.swift`. Use `AppContainer.production()` for the live graph; pass an explicit `AppContainer` for tests/previews. Avoid `.shared` reads in new code.
- **`Store<State, Action, Environment>`** — closure-based reducer + Effect type (~70 LOC) in `Palace/AppInfrastructure/Store.swift`. Not TCA — minimal ceremony.
- **SwiftUI** for new UI, **UIKit** for legacy screens
- **Combine** for reactive state management
- **Manual DI** via protocols — no framework, inject through constructors
- Mixed **Swift/Objective-C** (legacy OPDS parsing)

See [`docs/architecture/architectural-triad.md`](./docs/architecture/architectural-triad.md) for the design rationale and decision log.

## Dependencies

- **Readium 3.x** (swift-toolkit) — EPUB/PDF rendering via SPM
- **Firebase** — remote config, crash reporting
- **Adobe RMSDK / LCP** — DRM (private repos)
- **PalaceAudiobookToolkit** — audiobook playback (git submodule)
- **Carthage** — some binary framework management

## Key Patterns

- Network: `TPPNetworkExecutor` → `TPPNetworkResponder` → domain models
- Offline queue: `TPPNetworkQueue` retries failed requests
- Book state: `TPPBookRegistry` is the single source of truth
- Test mocks: centralized in `PalaceTests/Mocks/`, use `TPPBookMocker` for book factories
- Test HTTP stubbing: `HTTPStubURLProtocol` + `URLSession.stubbedSession()`

## TDD & Test Quality — MANDATORY

**All production code changes require tests written FIRST (TDD):**
1. Write a failing test that describes the desired behavior
2. Write the minimum production code to make it pass
3. Refactor both test and production code
4. Never commit production code without a corresponding test

**Test quality rules — every test must:**
- **Test behavior, not implementation.** Assert what the code DOES, not how it's structured. `XCTAssertEqual(cart.total, 15.99)` is good. `XCTAssertTrue(viewModel.showSearchSheet)` after just setting it is fluff.
- **Have meaningful setup.** If the test body is just `let x = Foo(); XCTAssertNotNil(x)`, it's not a test. Tests need Arrange → Act → Assert with a real Act step.
- **Use mocks/stubs for dependencies.** Never hit real singletons (`.shared`), network, keychain, or `UserDefaults`. Inject via protocol.
- **Test edge cases, not happy paths only.** Empty arrays, nil values, concurrent access, error responses, expired tokens, malformed data.
- **Name tests as behavior specs.** `testBorrow_WhenNotSignedIn_ShowsAuthPrompt` not `testBorrowButton`.

**Banned test patterns (these are fluff):**
- Setting a property then asserting it was set (`vm.x = 5; XCTAssertEqual(vm.x, 5)`)
- Asserting enum raw values (`XCTAssertEqual(Facet.title.rawValue, "title")`)
- Asserting a constructor returns non-nil (`XCTAssertNotNil(MyClass())`)
- Toggling a bool and checking it toggled
- Asserting default/initial state with no action taken

**When replacing fluff tests:** Replace 1:1 with a test that exercises real logic in the same class. The new test should use mocks, test an edge case, or verify a state transition — something that could actually fail if the code regresses.

**Mutation verification — every test must survive this question:**
> "If I flip a conditional, negate a return value, or change `+=` to `-=` in the production code this test covers, does the test fail?"

If the answer is no, the test is fluff regardless of assertion count. Run mutation testing on changed files:
```bash
# Discover mutation surface (no test runs):
python3 scripts/palace_mutate.py \
  --file Palace/Path/ChangedFile.swift \
  --tests PalaceTests/ChangedFileTests \
  --dry-run

# Verify tests catch the mutants:
python3 scripts/palace_mutate.py \
  --file Palace/Path/ChangedFile.swift \
  --tests PalaceTests/ChangedFileTests

# Diff-scoped: only mutate lines this PR changes vs origin/develop.
# Useful when a file has pre-existing low-coverage areas you don't want
# to be punished for — kill rate reflects YOUR PR's coverage, not the
# whole file's history. Cache-keyed independently from whole-file runs.
python3 scripts/palace_mutate.py \
  --file Palace/Path/ChangedFile.swift \
  --tests PalaceTests/ChangedFileTests \
  --diff-only [--diff-base origin/develop]
```

The `--tests` arg is an XCTest **class** name (not a directory) — `-only-testing` matches `<TestBundle>/<XCTestCase subclass>`. A run that says "0 tests executed" is a misconfiguration, not a clean pass.

A test that doesn't kill any mutants should be rewritten to test the actual behavior path, not just surface properties.

**Tautology tests are forbidden:**
- `XCTAssertTrue(x == true || x == false)` — always passes, tests nothing
- `XCTAssertNotNil(Singleton.shared)` — tests Swift's static let, not your code
- `XCTAssertTrue(x is SomeType)` — tests the compiler's type system
- `XCTAssertEqual(x, x)` — self-referential, always passes
- Any test where the assertion is mathematically guaranteed to pass

**Coverage-only tests are banned.** Do not write tests whose sole purpose is to execute a line of code for coverage numbers. If a line of code has no testable behavior (e.g., a fire-and-forget analytics call, an empty delegate method), leave it uncovered. Honest 35% coverage with tests that catch bugs is better than 50% coverage with tautologies that catch nothing.

**Critical path tests must be air-tight.** For sign-in, borrow, download, DRM fulfillment, and payment flows: every branch must have a test, every error path must be exercised, and every test must kill at least one mutant. These paths handle user money and access — fluff is not acceptable here.

## Definition of Done — paste evidence before declaring work complete

<!-- audit-verified -->
Per `.forgeos/wall-failures/` (lessons from PR #1018 reviewer-blocked findings + the swarm_c8fcab76 arch1 fake-wiring-test finding), every non-trivial work item — solo-agent or swarm — must pass these 11 self-checks BEFORE declaring READY or opening a PR. Paste the evidence in the commit body, the swarm transcript, or the user-facing summary. **Without evidence, the work is not done; it is "implemented but unverified."**

1. **SUT instantiation check** — for every test file you added or modified named `<SUT>Tests.swift` (e.g. `BookReturnServiceTests.swift`, `TPPNetworkResponderAuthCoordinatorTests.swift`), run `grep -c "<SUT>(" <test-file>`. The count must be ≥ 1. If you wrote a `BookReturnServiceAuthCoordinatorTests` that never constructs a `BookReturnService`, the test is theater — rewrite or rename. Catches PR #1018 qa2/qa3 (fake-test-instantiation).

   **Method-level extension (added wave 4 / cs_9a267b63 escalation):** For each test METHOD whose name embeds a PascalCase production-class noun (e.g. `testX_TPPReauthenticatorPath_invokesY` embeds `TPPReauthenticator` and `Y`), the same test method's body must call `TPPReauthenticator(...)` (instantiation) or `TPPReauthenticator.method(...)` (static call) or have an explicit type annotation `: TPPReauthenticator`. Verify mechanically with:

   ```bash
   python3 scripts/check-test-name-vs-body.py PalaceTests/<your-modified-file>.swift
   ```

   A non-zero exit means the test name embeds a noun the body doesn't reference. Fake-wiring tests of this shape have escaped into the codebase twice (cs_847892e8 arch1 + cs_9a267b63 arch1) and the runnable script is the structural fix that makes the pattern impossible to land. The same script is wired into `.claude/skills/swarm/SKILL.md` Phase 4.5 check 5b so the orchestrator gates all diffed test files automatically.

2. **Function-result usage check** — for every new production-code call to a function added or contracted-in, paste evidence the result is used (bound via `let outcome = ...`, pattern-matched, returned, or has a `// TODO(ticket): result intentionally discarded because <reason>` comment). `grep -E "= <fnName>\(|let _ = <fnName>" <prod-file>`. Catches PR #1018 arch3 (dishonest migration — classifier called but outcome only logged).

3. **Multi-step test body check** — for every test name containing `across`, `twice`, `reset`, `retry`, `again`, `roundtrip`, `inProduction`, `viaX`: confirm the body literally does each step the name claims. A test named `testCoordinator_perBookCircuitBreaker_isStillHonored_acrossTwoSeparateAttempts` MUST drive two attempts; if the second-attempt half is in comments, the test is fluff. Catches PR #1018 qa1 (half-done test) and arch2 (fake wiring test).

4. **Scope coverage audit** — for every item in the original task (or contract, in swarm mode), confirm it's in your diff OR explicitly listed as a deferred scope item via the scope-deferral protocol below. Don't bury reductions in a gaps section while claiming done. Catches PR #1018 Module C scope-reduction.

5. **Mutation pass (MANDATORY for critical paths)** — run `python3 scripts/palace_mutate.py --file <modified-file> --tests <test-class> --diff-only` for every modified production file in a critical path (`Palace/Audiobooks/`, `Palace/SignInLogic/`, `Palace/MyBooks/Download*`, `Palace/Packages/PalaceAuth/`, anything touching auth/borrow/return/DRM/credentials). Paste the kill rate. Must be ≥ 50% diff-scoped, ideally 100% on the touched lines. Catches PR #1018 qa1 (mutation deferred to integrator → half-done test shipped).

6. **Build + verify-pr** — `xcodebuild ... build` clean and `scripts/verify-pr.sh --quick` PASS. Paste the tails.

7. **Multi-step / wiring-claim check (v2):** for every test name claiming to exercise a multi-step path through production code, line-coverage report must show non-zero hits on the cited lines from that test. Catches `.forgeos/wall-failures/2026-05-28-cs847892e8-arch1.md` — the "fake wiring test" pattern where `openAudiobook(...)` mock-books fail in the loader before `bind() → startPlaybackAndSyncPosition()` ever runs, so the cited production lines (e.g. `AudiobookSessionManager.swift:684-710`) get zero coverage from the test claiming to exercise them. Without coverage evidence on the cited lines, the "multi-step production-seam test" claim is unverified — treat it as a check #3 failure.

8. **Contract reconciliation** — for non-trivial work (≥10 prod LOC), every "removes X" / "deletes X" / "migrates Y to Z" / "renames X to Y" / "adds field A to type B" claim in your commit body, PR body, or `.forgeos/intent/<name>.md` must reconcile against the staged diff. Run `python3 scripts/check-contract-reconciliation.py --commit-msg <file>` — exit 0 means all claims supported. Catches cluster pattern from waves 1-4. Paste exit code.

9. **Blast-radius check** — for ANY commit, run `python3 scripts/check-blast-radius.py --quiet`. Exit 0 means no new public API surface, no `#if DEBUG` on production paths, no test-only AppContainer init params, no discarded function results without `// TODO(ticket):` justification. High-severity findings block. Paste exit code.

10. **Adjacency staleness check** — for ANY commit removing/renaming a production type, run `python3 scripts/check-adjacency-staleness.py --quiet`. Warn-only. Paste output.

11. **Test-pairing check (superpartner spectrum)** — for ANY commit, run `python3 scripts/check-superpartner-spectrum.py --quiet`. Flags new functions, enum cases, and state changes that have no matching test in the diff. Add a test that references the item, or mark it intentional with `// no-superpartner: <reason>`. Warn-only for now (promotion path in `docs/architecture/superpartner-spectrum.md`); high-severity findings are on critical paths and should be cleared, not ignored. This is the fast "is there a test at all?" floor — mutation testing (`palace_mutate.py`, check #5) remains the proof that the test catches bugs. Paste exit code.

If you cannot produce evidence for all 11 checks applicable to your change, do NOT report READY. Either complete the missing check OR explicitly STOP with a scope-deferral proposal (below) so the user can decide.

## Scope-deferral protocol — STOP, do not partial-ship

If you discover you cannot complete the original scope within your time/context budget, **STOP and propose scope reduction explicitly** — do not silently ship partial work. The right response is:

```
BLOCKED: scope reduction proposal.

Original scope: <N> sites / files / tests.
I can land cleanly: <M>.
Remaining <N - M> have <specific reason — entangled state-machine cleanup,
unrecoverable test-fixture dependency, time budget exhausted>.

Options for the user/orchestrator:
  (a) extend my pass with more budget
  (b) accept the reduction; track remaining as next-sprint scope
  (c) split into <K> smaller passes

I will not ship partial as READY without explicit direction.
```

Burying scope reductions in a "gaps" / "deferred" / "follow-up" section while claiming READY is the failure mode this protocol prevents. The decision point is the user's, not yours. This applies to single-agent work AND swarm implementers.

Canonical bad pattern (PR #1018 Module C): "Migrated 2 of 7 contracted sites. READY FOR INTEGRATION (partial). Remaining 5 have entangled cleanup — see gaps." → forced an unplanned continuation pass. Correct response would have been BLOCKED with the 3-option proposal up front.

## Risk-driven rigor bar

The "swarm vs single-agent" decision is based on module count (≥2 modules = swarm). The "how much rigor" decision is **risk-based, not size-based**. A 30-LOC change to `BookReturnService` (critical-path return flow) gets the same rigor as a 500-LOC multi-module refactor — because the consequences of a bug are the same regardless of LOC.

**Critical paths requiring architect + SoD review regardless of LOC count:**
- `Palace/SignInLogic/`, `Palace/Packages/PalaceAuth/` — auth, sign-in, credential storage
- `Palace/MyBooks/Borrow*`, `Palace/MyBooks/BookReturn*`, `Palace/MyBooks/Download*` — borrow / return / download / DRM fulfillment
- `Palace/Audiobooks/` — audiobook playback (toolkit fragile per memory)
- `Palace/Migrations/` — anything touching persistence schema
- `Palace/Network/TPPNetworkResponder.swift`, `Palace/Network/TPPNetworkExecutor.swift` — the auth-error decision point

For single-module work in a critical path, use the `/rigorous-fix` skill (or `/swarm --solo`) — runs architect + SoD review without parallel implementers. For 1-LOC trivial fixes in a critical path, still run `/forge-review` after coding. The bar is: *if a regression here would hit users, the review must happen.*

For non-critical paths under 50 LOC, single-agent + `/clean-code` (which now includes the skeptic-pass greps) is sufficient.

## Architect reviewer canon

For structural review — new abstractions, type-hierarchy changes, protocol surfaces, concurrency model shifts — consult [`.forgeos/reviewer-refs/architect-swift-canon.md`](./.forgeos/reviewer-refs/architect-swift-canon.md) as a **lens, not a checklist**. It covers Swift-native architecture defaults (POP, value semantics, structured concurrency), SOLID translated to Swift mechanisms, a GoF → Swift-idiom translation table (with anti-translations called out), and a smell vocabulary the architect can cite in findings.

The canon and the [wall-failures catalog](./.forgeos/wall-failures/) are complements: the canon is *what good Swift architecture looks like*; the wall-failures are *what we've actually shipped that broke*. When they agree, the finding is strong. When they disagree, **trust the wall-failures** — they're real incidents from this codebase.

Skip the canon for mechanical changes (renames, formatting, dependency bumps) where structure isn't the question. Do not pattern-match findings to canon entries to seem rigorous — approval still requires a real reason; rejection still requires a concrete failure mode.

## Wall-failure catalog — every reviewer block becomes a permanent improvement

When a reviewer BLOCKS a PR (whether via `/forge-review` or external code review), the finding is a **system bug**, not just an implementer bug. The system let it through; the wall has a hole. Per `.forgeos/wall-failures/README.md`:

1. Within 24h of the block, create an entry at `.forgeos/wall-failures/YYYY-MM-DD-pr<NNNN>-<short-id>.md` using `TEMPLATE.md`.
2. Classify which wall(s) should have caught it (contract / implementer / TDD / mutation / verify-pr / orchestrator / reviewer / hook).
3. Propose a permanent fix — a contract clause, orchestrator check, implementer constraint, hook addition, CLAUDE.md edit — that makes the finding **structurally impossible to land**, not "more likely to be noticed."
4. Within 1 week, apply the fix; link the commit back from the entry; update `INDEX.md` and `derived-improvements.md`.

This is how the system gets less leaky over time. Without it, the same finding class can recur next swarm.

**State-machine wiring tests must exercise round-trips, not just transitions.** Any code that drives a state machine (e.g. `_setState`, `setState`, reducer-action dispatches, accessor setters that write a terminal state) gets a test class that proves the **full lifecycle**, not just individual transitions. Required cycles:

- **Write → reset → re-enter.** If a write can be undone (manually, via re-entry, or by a later setter call), a single test must drive the value through the cycle via the **production seam** (the public setter / driver function), not via direct `_setState` shortcuts. Direct shortcut writes prove the storage works; they don't prove the wiring works.
- **Enum cases reused with two meanings get an explicit semantics test.** When a terminal case (e.g. `.detailsFailed(.accountNotFound)`) is written for both "real failure" and "eviction marker," there must be a test that pins each meaning and a third test that proves they're correctly disambiguated by downstream consumers. If you can't pin them separately, the enum needs to split.
- **Consumer-side smoke test.** For every readiness gate (`awaitReady()`-style) that has ≥2 production consumers, write one test that drives the gate through a real consumer call site (audiobook open, token refresh, bookmark sync, CarPlay auth) after a non-trivial scenario (cold launch, library swap, sign-out/back-in). Unit-level transition tests are necessary but not sufficient — they prove the gate moves; the consumer test proves the gate is *useful*.
- **User-action → registry-state cycle for new content types (added 2026-06-03 per PP-4161 wall-failure).** For every new `TPPBookContentType` case, add an integration-style test that drives `BookDetailViewModel.handleAction(for: .get)` (or the cell-side equivalent `BookCellModel.callDelegate(for: .get)`) AND asserts the book reaches the expected `BookButtonState` for that content type via the production seam — NOT via `bookRegistry.setState(...)` direct shortcuts. Direct shortcut writes prove the storage works; they don't prove the user-action → display wiring works. **PP-4161 took two layered escalations (v2.2 hotfix attempt + Wave 4 Path X) to catch this because Module C unit tests pinned `BookButtonState.downloadNeeded + .streamingHTML → [.readStreaming, .return]` without proving any production path could transition the registry to `.downloadNeeded` for streaming-HTML books.** The architect Phase 1a SKILL.md check #5 (call-graph completeness) is the upstream gate; this rule is the downstream test requirement.

Reviewer checklist: when a PR adds a `case .Foo:` to a state-machine switch, ask "where's the test that proves we can recover from being IN `.Foo`?" When a PR adds a setter that writes a terminal state, ask "where's the test that proves the round-trip A→B→A works through this setter, not through `_setState` directly?" When a PR adds a new `TPPBookContentType` case, ask "where's the test that drives `handleAction(.get)` for that content type and asserts the book ends up in the right `BookButtonState` via the production path?"

Canonical reference for the round-trip pattern: `PalaceTests/Accounts/AccountsManagerStateMachineWiringTests.swift`, Test 7 (`testDriveCurrentAccountAuthDoc_staleAccountNotFoundMarker_redrives`).

## pbxproj

Two build phases (two targets) — new source files need entries in both Sources sections.

**Don't hand-edit `Palace.xcodeproj/project.pbxproj`.** Use the helper:

```bash
ruby scripts/pbxproj_add_swift.rb [--targets Palace,Palace-noDRM] [--group <path>] FILE [FILE ...]
```

It's idempotent, auto-routes test files (`PalaceTests/...`) to the `PalaceTests` target, and adds all 6 entries (PBXBuildFile×N, PBXFileReference, PBXGroup membership, PBXSourcesBuildPhase×N) cleanly via the `xcodeproj` Ruby gem.

## Multi-module orchestration — /swarm

For changes that touch ≥2 top-level modules (e.g. SPM extractions, cross-module features, refactors with cross-target API changes), use the `/swarm` skill (`.claude/skills/swarm/SKILL.md`). It runs a triage→dispatch→integrate→promote loop: an architect agent identifies modules and writes contract deltas to `.forgeos/swarms/<id>/`; parallel module-implementer subagents land changes against those contracts; `verify-pr.sh` + `forge-review` gate integration. Single-module work and bugfixes <50 LOC stay single-agent — triage overhead exceeds parallelism gain. See [`docs/architecture/swarm-workflow.md`](./docs/architecture/swarm-workflow.md) for rationale and decision log.

Module contracts under `.forgeos/contracts/<module>.json` are emitted by `scripts/export-module-contracts.py` and consumed by the architect; `verify-pr.sh` calls `--check` to flag PRs that change a module's public surface without contract update.

## Mutation testing

**Local-only as of 2026-05-15** — mutation runs are part of the **regression workflow** (`/regression` skill) and the pre-release self-check, not CI. macOS GitHub-hosted runners bill at $0.08/min; on a cold first-touch PR with 16+ changed production files, mutation walltime is 90–120 min ≈ $7–10 per push. We pay that once locally, before tag-cut, instead of every push to every PR. The mutation-on-pr.yml + mutation-gate.yml workflows were removed for this reason (commit history preserved if you need to revive them).

```bash
# Default — full battery sans mutation, fast (~5 min):
scripts/verify-pr.sh --quick

# Pre-release: add mutation gate (cache reuses across runs):
scripts/verify-pr.sh --quick --enforce-mutations

# Mutation-only for a single file (used by /regression skill):
python3 scripts/palace_mutate.py \
  --file Palace/Path/ChangedFile.swift \
  --tests PalaceTests/ChangedFileTests
```

Mutation results cache to `.forgeos/mutation-cache/` keyed by file SHA + test selection. Repeat runs on unchanged files are near-instant (<1s vs minutes). `verify-pr.sh --enforce-mutations` makes the 50% kill-rate threshold strict for ALL changed files. Default mode keeps strict-only on critical paths: `Palace/Audiobooks/`, `Palace/SignInLogic/`, `Palace/MyBooks/Download*`.

The mutation engine itself (`scripts/palace_mutate.py`) skips mutation points inside `Log.{trace,debug,info,warn,error}` / `print` / `NSLog` / `os_log` / `Logger` call lines — those flip a string interpolation but don't change observable behavior, so they were silently deflating every file's kill rate. AudiobookLoader.swift went from 9 discovered mutants (7 log-noise, 2 real, 0% kill rate) to 6 real mutants (6/6 = 100% kill rate) after the skip rule landed.

Test-class resolution for changed production files goes through `scripts/resolve-tests-for.py` — it maps `Palace/Foo/Bar.swift` → `PalaceTests/<XCTestCaseClass>` selectors by scanning `PalaceTests/**/*Tests*.swift` filenames and extracting class declarations (an optional `TPP` prefix is stripped so `TPPLCPClient.swift` resolves to `LCPClientTests`). If a production file has no resolvable tests it is skipped with a logged warning — that warning is a signal the file is uncovered and should get tests.

## Contract-snapshot tests

Some critical-path classes are easier to pin behaviorally than to mutation-test: state machines that emit ordered sequences of dependency calls (BorrowOperation → fetchBook then startDownload; BookReturnService → setProcessing → setState → removeBook → announce.returnSucceeded). For these we lock the *call order + argument shape* as a JSON snapshot — refactors that change the contract drift the snapshot and fail the test loudly.

**Where:** `PalaceTests/Contract/`. The framework lives in `CallLog.swift` (thread-safe recorder) + `ContractSnapshot.swift` (assert / record / diff). First-run records a baseline at `__Snapshots__/<TestClass>/<name>.json` and fails with "snapshot recorded — re-run to verify"; subsequent runs assert equality. Set `CONTRACT_SNAPSHOT_RECORD=1` to deliberately re-record (review the diff in `git diff` before committing).

**When to write a contract test:**
- The class under test calls 2+ dependencies in a known order and a swap would silently break callers (e.g. removing `registry.setProcessing(false)` mid-cleanup would leak forever).
- The behavior is too coarse to mutation-test usefully (string-keyed dispatch, ordered side effects, decision trees over enum cases).
- A regression in the class is high-cost: `Borrow`, `BookReturn`, `DownloadStart`, `BorrowReducer` already have contracts; `SignIn`/`OIDC` callbacks and `BookRegistry` mutation paths are good candidates.

**When NOT:**
- Pure transformations (use unit tests with explicit assertions).
- Single-call methods (snapshot adds noise vs. a direct assertion).
- Anything that hits a real network/keychain/UserDefaults (mock the dependency, snapshot the calls — but the dependency layer is the contract, not the integration).

**Pattern:** instantiate the class under test with spy dependencies that record into a `CallLog`, drive the scenario, call `ContractSnapshot.assert(log, named: "scenarioName")`. Production-code seams that block deterministic exercise (static singletons inside the SUT) get documented as inline comments rather than worked around — the inability to write the test IS the test feedback.

## Secrets

Never commit: `APIKeys.swift`, `GoogleService-Info.plist`, `TPPSecrets.swift`, `.env` files.

## E2E / UI sim driving — simdrive

**simdrive is the canonical iOS sim driver.** SpecterQA is **deprecated** as of 2026-04-29 (cutover) and **fully migrated** as of 2026-04-30 (everything moved under `.simdrive/`). The old SpecterQA corpus lives under `.simdrive/_archive/` (do **not** extend). Active flows live under `.simdrive/fixtures/flows/` (declarative, with `expects:` blocks) and `.simdrive/journeys/` (recording-aligned, paired with `~/.simdrive/recordings/`). Per-version visual baselines live under `.simdrive/fixtures/baselines/<version>/<flow>/<step>.{json,png}`.

**Why:** simdrive uses real CoreSimulator HID input + a vision-first OCR loop; it sees pixels, not the XCTest accessibility tree. This unblocks Reader2 (Readium 3.x WKWebView is invisible to XCTest), iOS-26 UITextField focus, OAuth/SAML out-of-process Safari sheets, and OS-level alerts — all places SpecterQA failed silently or required workarounds.

**MCP server:** `simdrive` (Python pkg). Surface: `session_start`, `session_end`, `session_status`, `observe`, `tap`, `swipe`, `type_text`, `press_key`, `record_start`, `record_stop`, `replay`, `logs`.

### Tool rules — MANDATORY

**Always `observe` with `annotate=true` before a `tap text=...` or `tap mark=...`.** Text/mark resolution caches against the **last** observe. An `annotate=false` observe returns no marks and the next text/mark tap will fail. If you've already seen the screen and know the coords, `tap x= y=` skips the cache concern entirely.

**Re-observe after every navigation.** Coordinates change with transitions, sheets, and orientation. Don't reuse marks across screens.

**Pre-grant permissions BEFORE `session_start`.** Memory: ~1/4 SpringBoard alert taps race the alert's PIDChange; the tap "succeeds" but the app drops to home. Use `xcrun simctl privacy <UDID> grant ...` before starting the session.

**`session_start` is sim-aware.** If a sim is already booted and you pass `udid=`, simdrive reuses it. With `app_bundle_id=` it launches the app. No xctest runner is involved.

**Recordings start at `record_start`, not `session_start`.** Wrap a tight flow; `record_stop` writes `recording.yaml` and clears the buffer. Replay with `replay name=<n> on_drift=halt drift_threshold=0.85` for SSIM-gated visual regression.

**Don't tap Safari/system-Chrome links from a sim screenshot when the link could be malicious.** Same OPSEC as desktop computer-use — verify URLs first.

**Reader2 nav (back, settings, TOC) IS reachable via simdrive** — that's the whole point. It's NOT reachable via XCTest. Prefer simdrive for any Reader2 regression.

### Simulator Setup

```bash
# Kill any stale xctest runners left over from the SpecterQA era:
pgrep -f "xcodebuild test-without-building" | xargs -r kill -9
SIM_UDID=$(xcrun simctl list devices iPhone | awk '/Booted/ {print $NF; exit}' | tr -d '()')

# Pre-grant permissions to avoid the SpringBoard alert race:
xcrun simctl privacy "$SIM_UDID" grant notifications org.thepalaceproject.palace
xcrun simctl privacy "$SIM_UDID" grant location  org.thepalaceproject.palace

# Palace-specific debug toggles (unchanged from before):
xcrun simctl spawn "$SIM_UDID" defaults write org.thepalaceproject.palace showDeveloperSettings -bool true
xcrun simctl spawn "$SIM_UDID" defaults write org.thepalaceproject.palace NYPLUseBetaLibrariesKey -bool true
```

Test library credentials live in your local environment (e.g. `~/.simdrive/credentials/` or whatever the agent has configured) and are never committed to the repo.

### Where things live

- `.simdrive/journeys/*.yaml` — canonical user journeys (new work goes here)
- `.simdrive/replays/*.yaml` — recorded sessions for SSIM regression
- `.simdrive/journeys/` — recording-aligned project-tracked journeys (active, our 8 from the cutover)
- `.simdrive/fixtures/flows/` — declarative flow specs with `expects:` blocks (active)
- `.simdrive/fixtures/baselines/<version>/` — per-version visual snapshots (active)
- `.simdrive/replays/chaos/` — curated mutation-killing replay corpus (active, gates `chaos-replay-on-pr.yml`)
- `.simdrive/_archive/journeys/`, `.simdrive/_archive/replays/`, `.simdrive/_archive/{personas,products,evidence}/`, `.simdrive/_archive/REGRESSION_PLAN.md` — old SpecterQA corpus (do not extend)
- `~/.simdrive/sessions/<id>/observations/` — per-session screenshots + SoM annotations
- `scripts/fix-replay-assertions.py`, `scripts/fix-replay-timing.py` — legacy replay-fixup tooling kept for archive-replay; do not author new SpecterQA scripts

When in doubt, run `~/harness/bin/harness simdrive status` to confirm version + active sessions.
