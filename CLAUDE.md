# Palace iOS Core

Library reading app supporting EPUB, PDF, and audiobooks with multiple DRM systems.

## Contributing

- Fork, branch from `develop` (never `main`), open the PR back to `develop`. Tests are mandatory for production changes.
- Maintainer-only local tooling is wired through hooks that no-op when it is not installed. Nothing extra is needed to build, test, or open a PR.
- **Pre-PR self-check:** `scripts/verify-pr.sh --quick` runs build, tests, lint, coverage and accessibility on the iPhone 16 Pro simulator; the unit-test leg is a full-scheme single pass. `--report /tmp/v.json` writes JSON.
- `--quick` skips exactly one leg: **mutation testing**. Drop the flag to include it, or use `--mutation-only`. A leg reported `skip` names its reason; a leg that recorded nothing fails the run.
- Design rationale lives in [`docs/architecture/`](./docs/architecture/). Start at [`docs/README.md`](./docs/README.md).

## Release & hotfix merge policy

- Merges into `main` use merge commits (`gh pr merge <num> --merge`), never squash. This covers `release/X.Y.Z` → `main`, `hotfix/X.Y.Z-*` → `main`, and forward-ports of those hotfixes into `develop`.
- Squash-merge is fine for feature PRs into `develop`.
- `main` branch protection should allow only "Create a merge commit".
- Why, and the recovery recipe: [`docs/architecture/release-merge-policy.md`](./docs/architecture/release-merge-policy.md).

## Build & Test

```bash
# Use the xcodeproj, not the workspace (the workspace hits Firebase SPM issues).
xcodebuild -project Palace.xcodeproj -scheme Palace \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build

xcodebuild -project Palace.xcodeproj -scheme Palace \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test

# Single class: a spot check only, never "the suite".
xcodebuild -project Palace.xcodeproj -scheme Palace \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:PalaceTests/MyTestClass test
```

**Before calling a change verified, run the suite CI runs**: `scripts/xcode-test-optimized.sh` (CI parity: all test targets, `-test-iterations 3 -retry-tests-on-failure`) or `scripts/verify-pr.sh --quick`. Then:
- The run ends `** TEST SUCCEEDED **` with no `exceeded execution time allowance` or `Restarting after … test timeout` lines. A timeout is a failure even at 0 assertion failures.
- Read the count from the top-level `Test Suite 'All tests'` rollup; per-suite `Executed N` lines over-count.

Environment: Xcode 26, iOS 17.0+. Targets `Palace` (full DRM) and `Palace-noDRM` (open source). DRM builds run natively on Apple Silicon.

**`nearly matches optional requirement` on an `@objc` delegate is never benign.** The method is not registered as the protocol witness, so the callback is skipped at runtime with no error (this broke web-sheet sign-in when `WKNavigationDelegate` became `@MainActor`, #1205). Match the SDK requirement's isolation exactly, e.g. a `@MainActor` method with an `@escaping @MainActor` handler. Check this warning first when a delegate callback does not fire. Gated by `scripts/check-objc-witness-nearly-matches.sh`.

## CI: keep the board trustworthy

A board that is usually red from flakes hides real failures. Rationale and incidents: [`docs/architecture/testing-rules-rationale.md`](./docs/architecture/testing-rules-rationale.md).

1. **Retries absorb flakes, not regressions.** CI retries each test up to 3 times; a real failure fails all 3.
2. **Fix test pollution at its source** (`.shared` singletons, background tasks outliving a test, off-main layout, keychain/UserDefaults bleed). Find the polluter with `scripts/find-test-polluter.sh --victim <TestClass>`. Exit 0 is clean, 1 is a finding, 3 means no usable verdict — never read 3 as either of the others.
3. **Tooling is gated too.** `tooling-checks.yml` runs `bash -n` on every shell script, the pytests in `scripts/tests/`, and the hook fixture tests.
4. **A new gate lands only when** it has a pytest in `scripts/tests/`, its wiring is tested end to end (the hook fixture test `scripts/tests/test_pre_commit_phase35_detectors.sh` must exercise it, including a clean-diff pass), and it has been dry-run on the current tree.
5. **A red test is a question about history.** Before theorising, establish whose it is:
   ```bash
   python3 scripts/ci-test-history.py --scan [--run <id>]     # which tests failed an iteration, even on a green run
   python3 scripts/ci-test-history.py <TestClass>[.method]    # new here, pre-existing, or retry-masked?
   scripts/find-test-polluter.sh --victim <TestClass>         # passes alone? then who dirties it?
   ```
   Read per-iteration results and the sampling depth the scan prints; "passed · FAILED · passed" is a finding. A test that flips with machine load should assert a property of the code instead.
6. **Red means stop.** `--admin` over a red check only for a specific, named, already-tracked flake that passes in isolation and has a de-flake item.

## Writing conventions

Write for a colleague opening the repo cold, not for tooling. These are enforced by `scripts/check-pr-hygiene.py` (PR title/body, `pr-hygiene.yml`) and `scripts/check-comment-hygiene.py` (source comments; `tooling-checks.yml`, `verify-pr.sh`, pre-commit).

**Voice.** Describe the change, not a verdict on the code you found: "refresh the Adobe licensor before device activation", not "the Adobe licensor went stale". No epigrams ("a redactor that is not called is not a redactor"), no reconstructing someone's reasoning to grade it, no scornful emphasis (ALL CAPS, "silently", "nobody", "never once"). Keep the precision: exact mechanism, measured evidence, what was not fixed.

**PR titles and commit subjects.** Imperative, 72 characters max. A Jira key is fine as prefix or suffix. No internal run or campaign identifiers (swarm/wave/phase IDs, `rev_<hex>`, changeset IDs).

**PR bodies.** Use the template: What (1-3 sentences), Why (1-3 sentences, Jira link), How verified (one line per test and what it asserts, 4 bullets max, plus manual checks), optional Not done. About 20 lines, hard limit ~1,500 characters; screenshots and HTML comments do not count.
- Keep Jira links, `Closes #N`, related PRs, screenshots. One line of mutation results is fine.
- Leave out AI footers and `Co-Authored-By` trailers, reviewer transcripts and verdicts, score tables, command transcripts, red-before-green logs, retro prose, and internal tooling vocabulary.

**Commit bodies.** Optional; at most ~10 lines with the same content as What/Why. No AI trailer. A single `Scope: ...` or `Not done: ...` line is allowed where a local hook asks for it.

**Source comments** (`Palace/`, `PalaceTests/`). Explain why: an invariant, a platform quirk, a non-obvious constraint. The code says what.
- Allowed references: Jira keys, GitHub PR/issue numbers, Apple docs or radar URLs, `docs/architecture/` pages.
- Not allowed: run/campaign IDs, reviewer names or rounds, citations of this file, incident diaries, mutation-run narratives, ALL-CAPS section headings.
- File headers at most ~10 lines (the check fails at 15). Design essays go in `docs/architecture/` with a link.
- Test doc comments: one or two lines on the behavior pinned and why it matters.

**Adding a detector.** A new `check-*` script needs at least one real instance in the tree, or a near-miss that reached review or production. Prefer replacing or extending an existing check over adding another. Follow CI rule 4 above.

## Documentation

- Search order: this file → `docs/README.md` → the area's `verification-checklist.md` → the ADR → the code.
- Write a doc only if someone would make a materially worse decision without it: a road not taken, an invisible constraint, a failure whose cause is not recoverable from the diff. Plans, run logs, review dumps and reports on shipped versions do not belong in the tree.
- Gates: `scripts/check-doc-hygiene.sh` (no process/generated artifacts), `scripts/check-doc-references-resolve.py` (every path a doc names exists), `scripts/check-doc-index-complete.py` (every doc is in its index). Each baselines pre-existing breakage and fails on new breakage.
- A doc you will not maintain is worse than none. Delete it.

## Project Structure

```
Palace/
  AppInfrastructure/   # App launch, Firebase, navigation, AppContainer DI root
  Accounts/            # Library account management
  Book/                # Book models and detail views
  MyBooks/             # Downloaded books management
  Catalog/, CatalogDomain/, CatalogUI/   # Catalog UI (legacy), API/parsing, SwiftUI views
  Audiobooks/          # Audiobook playback management
  Reader2/             # EPUB reader (Readium 3.x, SwiftUI)
  Reader3/             # PDF reader
  OPDS/, OPDS2/        # OPDS 1.x parsing (Objective-C), OPDS 2.0
  SignInLogic/         # Authentication flows (OAuth, SAML, basic, OIDC)
  Network/             # HTTP networking layer
  Keychain/            # Secure credential storage
  Holds/               # Reservations flows + HoldsReducer
  Utilities/           # Extensions, helpers, concurrency
  Migrations/          # App upgrade migrations
PalaceTests/           # Mocks/, ViewModels/, Network/, Snapshots/, by feature area
PalaceConfig/          # Assets, certs, plists
scripts/               # Build, test, release automation
docs/                  # Architecture decisions + testing posture
```

## Architecture

- **MVVM + Services + Reducers.** ViewModels are `@MainActor ObservableObject`; critical-path state machines are pure `Reducer.reduce(state, action) -> Effect` functions.
- **`AppContainer`** (`Palace/AppInfrastructure/AppContainer.swift`) is the composition root. `AppContainer.production()` for the live graph; pass an explicit container in tests and previews. Avoid `.shared` reads in new code.
- **`Store<State, Action, Environment>`** (`Palace/AppInfrastructure/Store.swift`): a small closure-based reducer store, not TCA.
- SwiftUI for new UI, UIKit for legacy screens; Combine for reactive state; manual DI through protocols and constructors; Objective-C for legacy OPDS parsing.
- Rationale: [`docs/architecture/architectural-triad.md`](./docs/architecture/architectural-triad.md).

Dependencies: Readium 3.x (SPM), Firebase, Adobe RMSDK / LCP (private repos), PalaceAudiobookToolkit (submodule), Carthage for some binaries.

Key patterns:
- Network: `TPPNetworkExecutor` → `TPPNetworkResponder` → domain models; `TPPNetworkQueue` retries offline requests.
- `TPPBookRegistry` is the single source of truth for book state.
- Test mocks live in `PalaceTests/Mocks/`; `TPPBookMocker` builds books; stub HTTP with `HTTPStubURLProtocol` + `URLSession.stubbedSession()`.
- Triage bot (`Palace/Packages/PalaceTriageBot/`): read [`docs/architecture/triage-bot-v1-as-built.md`](./docs/architecture/triage-bot-v1-as-built.md) before changing it; where package comments disagree with it, the document is correct.

## TDD & Test Quality — MANDATORY

Write the failing test first, then the minimum code to pass, then refactor. Never commit production code without a test.

Every test must:
- **Test behavior, not implementation.** `XCTAssertEqual(cart.total, 15.99)`, not asserting a flag you just set.
- **Arrange → Act → Assert** with a real Act step.
- **Use mocks/stubs.** Never real singletons (`.shared`), network, keychain, or `UserDefaults`; inject via protocol.
- **Cover edge cases:** empty, nil, concurrent access, error responses, expired tokens, malformed data.
- **Be named as a behavior spec:** `testBorrow_WhenNotSignedIn_ShowsAuthPrompt`.

Banned: set-then-assert, asserting enum raw values, `XCTAssertNotNil(MyClass())`, toggle-and-check, asserting initial state with no action, tautologies (`x == true || x == false`, `XCTAssertNotNil(Singleton.shared)`, `x is SomeType`, `XCTAssertEqual(x, x)`), and coverage-only tests. Replace fluff 1:1 with a test that could fail if the code regressed.

**Critical paths** (sign-in, borrow, download, DRM fulfillment, payment): every branch and error path has a test, and every test kills at least one mutant.

### Mutation testing

A test must fail if you flip a conditional, negate a return, or change `+=` to `-=` in the code it covers.

```bash
python3 scripts/palace_mutate.py --file Palace/Path/ChangedFile.swift --tests PalaceTests/ChangedFileTests --dry-run
python3 scripts/palace_mutate.py --file Palace/Path/ChangedFile.swift --tests PalaceTests/ChangedFileTests
python3 scripts/palace_mutate.py --file Palace/Path/ChangedFile.swift --tests PalaceTests/ChangedFileTests --diff-only [--diff-base origin/develop]
```

- `--tests` is `<TestBundle>/<XCTestCase class>`, not a directory. "0 tests executed" is a misconfiguration, not a pass.
- Derive mutants with `palace_mutate.py`, never from a hand-written list; label any hand-authored mutant as illustration.
- A mutant that fails to compile is not a kill. Count a mutant dead only with a named failing test; `errored` is reported separately.
- A kill rate is not coverage. Also ask which reachable (state, event) pairs have no test.
- **State machines:** when a state enum is mutated by more than one method, write the states × events table and assert every cell. When a fix adds a state dimension, say what it does to every existing cell.
- **Shared helpers:** a behavior change needs a census of every caller and what each now does differently.
- Mutate the audiobook toolkit with `--repo-root <toolkit checkout>`, `--project PalaceAudiobookToolkit.xcodeproj` and `--scheme PalaceAudiobookToolkit`. It builds from its own checkout (PalaceUIKit was vendored into it, PP-4953); its one outside input is `AudioEngine.xcframework` in `../Carthage/Build` relative to that checkout, which `scripts/fetch-audioengine.sh` fills when run from this repo's root. Without it every mutant errors.

### Contract-snapshot tests

For classes that call 2+ dependencies in an order callers rely on (`BorrowOperation`, `BookReturnService`, `DownloadStart`, `BorrowReducer`; `SignIn`/OIDC callbacks and `BookRegistry` mutations are good candidates), lock the call order and argument shape as a JSON snapshot.
- Lives in `PalaceTests/Contract/` (`CallLog.swift`, `ContractSnapshot.swift`). Baselines are at `__Snapshots__/<TestClass>/<name>.json`; the first run records and fails. Re-record deliberately with `CONTRACT_SNAPSHOT_RECORD=1` and review the diff.
- Pattern: spy dependencies record into a `CallLog`, drive the scenario, `ContractSnapshot.assert(log, named:)`.
- Not for pure transformations, single-call methods, or anything touching a real network/keychain/UserDefaults.

## pbxproj

New source files need entries in both targets' Sources phases. Don't hand-edit `Palace.xcodeproj/project.pbxproj`; use:

```bash
ruby scripts/pbxproj_add_swift.rb [--targets Palace,Palace-noDRM] [--group <path>] FILE [FILE ...]
```

It is idempotent and routes `PalaceTests/...` files to the test target.

## Secrets & signing

- Never commit `APIKeys.swift`, `GoogleService-Info.plist`, `TPPSecrets.swift`, or `.env` files.
- `CODE_SIGN_STYLE = Manual` on every config. `DEVELOPMENT_TEAM` and `PROVISIONING_PROFILE` come from a gitignored `*.local.xcconfig` or a CI secret, never git (`DEVELOPMENT_TEAM = ""` is fine). Enforced by `scripts/check-no-committed-signing.sh`; allowlist entries go in that script.
