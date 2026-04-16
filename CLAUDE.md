# Palace iOS Core

Library reading app supporting EPUB, PDF, and audiobooks with multiple DRM systems.

## Mandatory Verification — READ FIRST

Every session that produces code changes MUST follow this workflow. No exceptions.

### 1. ForgeOS governance (every session)
```bash
# Session start — initialize project
forge_init  # project: proj_87884c17
forge_propose_changeset  # BEFORE coding — read required evidence to shape implementation

# During work — collect evidence as milestones hit
scripts/forgeos-session.sh evidence <changeset_id>

# Before PR — ALL gates must be promoted
scripts/forgeos-session.sh promote <changeset_id>
forge_release_check  # must return can_release: true
```

### 2. Pre-PR verification (every PR)
```bash
# Full verification battery — build, tests, lint, coverage, mutation, a11y
scripts/verify-pr.sh                     # All checks
scripts/verify-pr.sh --quick             # Skip mutation (faster)
scripts/verify-pr.sh --report /tmp/v.json  # JSON report for tracking
```

### 3. Enforcement hooks (automatic — you WILL be blocked)
- **git commit**: blocked unless ForgeOS changeset exists for current branch
- **git push**: blocked unless ForgeOS gates pass
- **gh pr create**: blocked unless ForgeOS gates pass

### 4. Testing posture
Full testing capabilities, confidence matrix, and gaps documented in:
**`docs/Testing/TESTING_POSTURE.md`** — read before writing tests for unfamiliar areas.

### 5. Before every PR
- Run mutation testing: `python3 scripts/palace_mutate.py --file <changed>.swift --tests PalaceTests/`
- ForgeOS gate-check passes
- Target branch: `develop` (never `main` directly)

## Build & Test

```bash
# Build (use xcodeproj, NOT workspace — workspace hits Firebase SPM issues)
xcodebuild -project Palace.xcodeproj -scheme Palace \
  -destination 'platform=iOS Simulator,id=DF4A2A27-9888-429D-A749-2E157A049A37' build

# Run all tests
xcodebuild -project Palace.xcodeproj -scheme Palace \
  -destination 'platform=iOS Simulator,id=DF4A2A27-9888-429D-A749-2E157A049A37' test

# Run a single test class
xcodebuild -project Palace.xcodeproj -scheme Palace \
  -destination 'platform=iOS Simulator,id=DF4A2A27-9888-429D-A749-2E157A049A37' \
  -only-testing:PalaceTests/MyTestClass test
```

- Xcode 16.1+, iOS 16.0+ deployment target
- Two targets: `Palace` (full DRM) and `Palace-noDRM` (open-source)
- Rosetta required on Apple Silicon for DRM builds

## Project Structure

```
Palace/
  AppInfrastructure/   # App launch, Firebase, navigation
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
  SignInLogic/         # Authentication flows (OAuth, SAML, basic)
  Network/             # HTTP networking layer
  Keychain/            # Secure credential storage
  Utilities/           # Extensions, helpers, concurrency
  Migrations/          # App upgrade migrations

PalaceTests/
  Mocks/               # 21 shared mock implementations
  ViewModels/          # ViewModel unit tests
  Network/             # Network layer tests
  Snapshots/           # UI snapshot tests
  (organized by feature area)

PalaceConfig/          # Assets, certs, plists
scripts/               # Build, test, release automation
```

## Architecture

- **MVVM + Services** — ViewModels are `@MainActor ObservableObject` with `@Published` properties
- **SwiftUI** for new UI, **UIKit** for legacy screens
- **Combine** for reactive state management
- **Manual DI** via protocols — no framework, inject through constructors
- Mixed **Swift/Objective-C** (legacy OPDS parsing)

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
- **Use mocks/stubs for dependencies.** Never hit real singletons (.shared), network, keychain, or UserDefaults. Inject via protocol.
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
python3 scripts/palace_mutate.py --file Palace/Path/ChangedFile.swift --tests PalaceTests/Path/ --dry-run
# Then without --dry-run to verify tests catch the mutants
```

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

29 journey YAMLs in `.specterqa/journeys/`, 29 replay YAMLs in `.specterqa/replays/`.
MCP server: `specterqa-ios==7.0.0`. Preferred sim: iPhone 12 (`31CF5C43-DD55-4889-B3B2-9A6810B4E98F`, iOS 26).

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
# Kill stale runners, boot sim, enable dev settings
pgrep -f "xcodebuild test-without-building" | xargs -r kill -9
xcrun simctl boot 31CF5C43-DD55-4889-B3B2-9A6810B4E98F 2>/dev/null || true
xcrun simctl spawn 31CF5C43-DD55-4889-B3B2-9A6810B4E98F defaults write org.thepalaceproject.palace showDeveloperSettings -bool true
xcrun simctl spawn 31CF5C43-DD55-4889-B3B2-9A6810B4E98F defaults write org.thepalaceproject.palace NYPLUseBetaLibrariesKey -bool true
```

Two libraries configured: A1QA Test Library (signed in) + Lyrasis Reads. Credentials at `~/.specterqa/credentials/a1qa-test.env`.
