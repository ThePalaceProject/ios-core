# Palace iOS Core

Library reading app supporting EPUB, PDF, and audiobooks with multiple DRM systems.

## Contributing & Development Workflow

**Outside contributors:** standard GitHub flow — fork the repo, branch from `develop` (never `main`), open a PR back to `develop` when ready. Tests are mandatory for production changes (see [TDD & Test Quality](#tdd--test-quality--mandatory) below).

**Maintainers** additionally run through ForgeOS governance gates (changeset → evidence → review → promote). That tooling is in `scripts/forgeos-*.sh` and is exercised via the local-only `.claude/settings.json` PreToolUse hooks. Outside contributors can ignore those scripts; they no-op gracefully without an API key.

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

**Don't hand-edit `Palace.xcodeproj/project.pbxproj`.** Use the helper:

```bash
ruby scripts/pbxproj_add_swift.rb [--targets Palace,Palace-noDRM] [--group <path>] FILE [FILE ...]
```

It's idempotent, auto-routes test files (`PalaceTests/...`) to the `PalaceTests` target, and adds all 6 entries (PBXBuildFile×N, PBXFileReference, PBXGroup membership, PBXSourcesBuildPhase×N) cleanly via the `xcodeproj` Ruby gem.

## Multi-module orchestration — /swarm

For changes that touch ≥2 top-level modules (e.g. SPM extractions, cross-module features, refactors with cross-target API changes), use the `/swarm` skill (`.claude/skills/swarm/SKILL.md`). It runs a triage→dispatch→integrate→promote loop: an architect agent identifies modules and writes contract deltas to `.forgeos/swarms/<id>/`; parallel module-implementer subagents land changes against those contracts; `verify-pr.sh` + `forge-review` gate integration. Single-module work and bugfixes <50 LOC stay single-agent — triage overhead exceeds parallelism gain. See [`docs/architecture/swarm-workflow.md`](./docs/architecture/swarm-workflow.md) for rationale and decision log.

Module contracts under `.forgeos/contracts/<module>.json` are emitted by `scripts/export-module-contracts.py` and consumed by the architect; `verify-pr.sh` calls `--check` to flag PRs that change a module's public surface without contract update.

## Mutation testing

Mutation results cache to `.forgeos/mutation-cache/` keyed by file SHA + test selection. `verify-pr.sh` reads the cache automatically — repeat runs on unchanged files are near-instant (<1s vs minutes).

`verify-pr.sh --enforce-mutations` makes the 50% kill-rate threshold strict for ALL changed files. Default mode keeps strict-only on critical paths: `Palace/Audiobooks/`, `Palace/SignInLogic/`, `Palace/MyBooks/Download*`. Other paths warn but don't fail.

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
- `scripts/specterqa-*.sh`, `scripts/fix-replay-assertions.py` — legacy build/coverage tooling kept for archive-replay; do not author new SpecterQA scripts

When in doubt, run `~/harness/bin/harness simdrive status` to confirm version + active sessions.
