# Palace iOS Core

Library reading app supporting EPUB, PDF, and audiobooks with multiple DRM systems.

## Contributing & Development Workflow

**Outside contributors:** standard GitHub flow — fork the repo, branch from `develop` (never `main`), open a PR back to `develop` when ready. Tests are mandatory for production changes (see [TDD & Test Quality](#tdd--test-quality--mandatory) below).

**Maintainers** run additional local review/governance tooling wired through git hooks and Claude Code settings. It is **opt-in and self-disabling** — the hooks no-op cleanly for anyone who doesn't have that tooling installed, so outside contributors can ignore it entirely: nothing extra is required to build, test, or open a PR.

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

# Run a single test class — SPOT CHECK ONLY, never "validation" (see rule below)
xcodebuild -project Palace.xcodeproj -scheme Palace \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:PalaceTests/MyTestClass test
```

**Local validation MUST run the same full suite CI runs — never a `-only-testing`
subset.** CI executes the whole `Palace` scheme across ALL test targets
(`PalaceTests` + `TenPrintCoverTests`) with `-test-iterations 3
-retry-tests-on-failure` via `scripts/xcode-test-optimized.sh` (~7k executions).
Before claiming a change is verified / green:
- Run `scripts/xcode-test-optimized.sh` (CI parity) **or** `scripts/verify-pr.sh
  --quick` (full-scheme single pass). A `-only-testing:<Class>` run is a scoped
  spot-check for fast iteration/mutation/debugging — it is NEVER "the suite" and
  must never be reported as a full or green pass.
- Confirm the run ended `** TEST SUCCEEDED **` with **no** `exceeded execution
  time allowance` or `Restarting after … test timeout` lines. A timeout/restart
  is a FAILURE even if the final assertion tally reads "0 failures."
- Read the top-level `Test Suite 'All tests'/'Selected tests'` rollup for the
  count; never sum per-suite `Executed N` lines (they double/triple-count).

Incident (PP-4542, 2026-06-09): a `-only-testing:PalaceTests` run was reported as
"full local suite 2359 / 0 failures, PRs verifiably correct." It was one bundle
(CI runs 7121) AND had actually hung + `** TEST FAILED **`. A subset run, itself
failed, cited as whole-suite green. Don't repeat it.

- Xcode 26, iOS 16.0+ deployment target (CI release path: `macos-26` + `xcode-version: '26'`)
- Two targets: `Palace` (full DRM) and `Palace-noDRM` (open-source)
- DRM builds run natively on Apple Silicon — Rosetta is no longer required

**`nearly matches optional requirement` on an `@objc` delegate is NEVER benign.**
It means your method is silently NOT registered as the protocol witness, so the
callback (WebKit/UIKit/CarPlay delegate) is skipped at runtime — no error, no
crash. This is exactly how Xcode 26.2 broke web-sheet sign-in: `WKNavigationDelegate`
became `@MainActor` (`WK_SWIFT_UI_ACTOR`) and a `nonisolated`/non-`@MainActor`
`decisionHandler` stopped matching (#1205). Match the SDK requirement's isolation
exactly — `@MainActor` method + `@escaping @MainActor` handler for `WK_SWIFT_UI_ACTOR`
protocols. When a delegate callback "isn't firing," read this warning FIRST before
theorizing about timing. Gated in CI by `scripts/check-objc-witness-nearly-matches.sh`
(fires only on same-name drift; benign different-name matches like CarPlay are ignored).

## CI/CD reliability — the green-board contract

A CI board that is usually-red-from-flakes provides **no signal** — it trains
everyone to ignore CI and admin-merge, and a real failure then hides in the
noise. (That is exactly how PR #1045 shipped a `verify-pr.sh` that didn't pass
`bash -n` and a pre-commit hook that would have blocked every commit: the board
was already red from pollution, so nobody trusted it.) The contract below keeps
the board trustworthy.

**1. Flakes don't redden the board; real failures do.** `scripts/xcode-test-optimized.sh`
runs with `-retry-tests-on-failure -test-iterations 3`. A test that passes on
any of 3 attempts counts as a pass; a real failure fails all 3 and stays red.
Retry is a safety net, **not** a substitute for fixing pollution — see #2.

**2. Fix test pollution at the root; do not just document flake #N.** The
recurring red is shared mutable state bleeding across tests (`.shared`
singletons, `AccountsManager()` background `loadCatalogs` outliving the test,
layout-engine-off-main, keychain/UserDefaults bleed). When a flake appears: run
the polluter-diagnosis (`scripts/find-test-polluter.sh`) to find the test that
leaves state dirty, then fix the leak (tear down the singleton, await the
background task, force main-thread layout). Adding a sixth "known flake" memo is
not a fix.

**3. The tooling is under CI too.** `verify-pr.sh`, the detectors, and the
pre-commit hooks gate everything else, so they get their own gate:
`.github/workflows/tooling-checks.yml` runs `bash -n` on every committed shell
script, the detector pytests (`scripts/tests/`), and the hook fixture test on
every PR (~1 min, ubuntu). A broken gate script is a CI failure, not a
ship-green surprise.

**4. Don't land a gate faster than you can verify it.** A new detector / hook /
verify-pr gate does not merge until: (a) it has a pytest in `scripts/tests/`;
(b) its **wiring** is end-to-end tested — the hook fixture test
(`test_pre_commit_phase35_detectors.sh`) must exercise the new detector,
including a **clean-diff pass** assertion (a detector invoked with an interface
it rejects must not block); (c) it's been dry-run on the current tree for zero
false positives. Wiring bugs (a scan-only detector called with `--diff`) are
invisible to a fixture that only ever stages a violation — always assert the
clean path passes too.

**5. Retire the admin-merge reflex.** Once the board is trustworthy (1–4), red
means **stop**. `--admin` over a red check is allowed ONLY when the failure is a
specific, named, already-tracked flake that passes in isolation — and that flake
must have a de-flake item per #2. Never `--admin` over a red board whose failure
you have not individually identified; that is how real breakage lands.

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

## pbxproj

Two build phases (two targets) — new source files need entries in both Sources sections.

**Don't hand-edit `Palace.xcodeproj/project.pbxproj`.** Use the helper:

```bash
ruby scripts/pbxproj_add_swift.rb [--targets Palace,Palace-noDRM] [--group <path>] FILE [FILE ...]
```

It's idempotent, auto-routes test files (`PalaceTests/...`) to the `PalaceTests` target, and adds all 6 entries (PBXBuildFile×N, PBXFileReference, PBXGroup membership, PBXSourcesBuildPhase×N) cleanly via the `xcodeproj` Ruby gem.

## Secrets

Never commit: `APIKeys.swift`, `GoogleService-Info.plist`, `TPPSecrets.swift`, `.env` files.

**Code signing must be Manual, and signing info must NOT be committed.**
`CODE_SIGN_STYLE = Manual` on every config (Automatic lets Xcode rewrite the team
ID / provisioning profile into the pbxproj on each dev's machine, causing churn +
leaking signing identity). `DEVELOPMENT_TEAM` and `PROVISIONING_PROFILE` are
per-machine/per-account — provide them via a gitignored `*.local.xcconfig` or a CI
secret, never in git (`DEVELOPMENT_TEAM = ""` in the committed pbxproj is fine).
Enforced by `scripts/check-no-committed-signing.sh` (diff-based; wired into the
pre-commit hook + `verify-pr.sh` + `tooling-checks.yml`). To intentionally allow an
entry, add a substring to the signing allowlist consulted by that script.
