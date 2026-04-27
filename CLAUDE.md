# Palace iOS Core

Library reading app supporting EPUB, PDF, and audiobooks with multiple DRM systems.

## Contributing & Development Workflow

**Outside contributors:** standard GitHub flow — fork the repo, branch from `develop` (never `main`), open a PR back to `develop` when ready. Tests are mandatory for production changes (see [TDD & Test Quality](#tdd--test-quality--mandatory) below).

**Internal Synctek contributors** additionally run through ForgeOS governance gates (changeset → evidence → review → promote). That tooling is in `scripts/forgeos-*.sh` and is exercised via the local-only `.claude/settings.json` PreToolUse hooks. Outside contributors can ignore those scripts; they no-op gracefully without an API key.

**Pre-PR self-check (anyone):** `scripts/verify-pr.sh --quick` runs the full battery — build, tests, lint, coverage, accessibility — against the iPhone 16 Pro simulator. JSON report optional: `--report /tmp/v.json`.

**Architecture decisions:** see [`docs/architecture/`](./docs/architecture/) for the rationale behind major refactors (the post-modernization triad work, the parallel-agent rebase pattern, post-PR retros).

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

- Xcode 16.1+, iOS 16.0+ deployment target
- Two targets: `Palace` (full DRM) and `Palace-noDRM` (open-source)
- Rosetta required on Apple Silicon for DRM builds

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

## pbxproj

Two build phases (two targets) — new source files need entries in both Sources sections.

## Secrets

Never commit: `APIKeys.swift`, `GoogleService-Info.plist`, `TPPSecrets.swift`, `.env` files.

## SpecterQA E2E Testing

25 canonical journey YAMLs in `.specterqa/journeys/` (plus `_GAP_ANALYSIS.md`), 46 replay YAMLs in `.specterqa/replays/`. Only 19 of the 25 journeys have a matching-name replay; the other 27 replays are historical captures (SQ-005/007/008 fix iterations, version-specific snapshots, dogfood runs, regression variants) with no corresponding journey.

Recording coverage is reported as `<journeys-with-matching-replay> / <total-journeys>` (see `.github/workflows/unit-testing.yml`). Do NOT divide total replay files by total journeys — that ratio is meaningless and was the bug behind the "46/25 passing" mislabel.

MCP server: `specterqa-ios==7.0.0`.

### MCP Tool Rules — MANDATORY

**`ios_tap` only accepts `element_index` (integer).** Call `ios_elements()` first. Indices change after every navigation — always re-fetch before tapping.

**`ios_type` works. `ios_press_key(key="return")` crashes the session.** Search auto-submits after typing. For forms, tap a submit button element instead. Never press return after typing.

**`ios_set_appearance` / `ios_simctl` fail during active sessions.** Set appearance BEFORE `ios_start_session` via bash: `xcrun simctl ui <UDID> appearance dark`.

**`ios_screenshot` exceeds MCP size limit.** Use `ios_elements()` instead — returns labels, types, positions. This IS your screenshot.

**Kill stale runners before every session.** `pgrep -f "xcodebuild test-without-building" | xargs -r kill -9`. Old runners hold the port and block new sessions.

**EPUB reader nav controls are invisible to XCTest.** Readium WKWebView renders outside the accessibility tree. Page content IS visible but back/settings buttons are not. `ios_swipe_back` does NOT exit the reader.

**`ios_save_replay` captures ALL actions since session start.** For clean replays, start a fresh session per journey. 0-step replays are valid (e.g., app-launch).

### Simulator Setup

```bash
# Kill stale runners; replace SIM_UDID with your iPhone simulator UDID:
pgrep -f "xcodebuild test-without-building" | xargs -r kill -9
SIM_UDID=$(xcrun simctl list devices iPhone | awk '/Booted/ {print $NF; exit}' | tr -d '()')
xcrun simctl spawn "$SIM_UDID" defaults write org.thepalaceproject.palace showDeveloperSettings -bool true
xcrun simctl spawn "$SIM_UDID" defaults write org.thepalaceproject.palace NYPLUseBetaLibrariesKey -bool true
```

Test library credentials live in your local environment (e.g. `~/.specterqa/credentials/`) and are never committed to the repo.
