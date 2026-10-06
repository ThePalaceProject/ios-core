# UI journeys

Patron journeys that run as XCUITests against local fixtures. They need no
library account, no network and no private tooling.

| Journey | Test | What it asserts |
|---|---|---|
| Sign in and borrow | `SignInAndBorrowJourneyTests` | Settings shows the account signed in; after one borrow the book becomes readable and My Books holds exactly that one book |
| Resume reading | `ResumeReadingJourneyTests` | After reading to the last chapter and relaunching, reopening the book shows that chapter, not the first |

## Run them

Prerequisites: a checkout that builds the `Palace` scheme (Xcode 26, the
setup in [`CONTRIBUTING.md`](../../CONTRIBUTING.md)) and an iPhone simulator.
From the repository root:

```bash
xcodebuild test -project Palace.xcodeproj -scheme PalaceUITests \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=""
```

The signing overrides are the ad-hoc signing CI uses, so no certificate is
needed. The run ends with `** TEST SUCCEEDED **`; on failure, the result
bundle holds a screenshot and the accessibility tree, named after the step
that failed.

The `PalaceUITests` scheme is separate from `Palace`, so the unit-test run and
its coverage report do not include these tests.

## How a journey controls the app

- **Backend.** The test launches the app with `PALACE_MOCK_BACKEND_SCENARIO`
  and `PALACE_MOCK_BACKEND_FIXTURES` in its environment. In DEBUG builds,
  `MockBackendLaunchHook` reads them before any service starts, activates the
  scenario in `MockBackendURLProtocol`, and points the library registry at the
  scenario's fixture library. Release builds do not compile the hook.
- **Fixtures.** `PalaceUITests/Fixtures` holds the registry, authentication
  document, OPDS feeds and an EPUB, all on the reserved host
  `palace-fixtures.test`. A request no route matches goes nowhere, because
  that host does not resolve. The test bundle carries the folder and the app
  reads it from there, which works on the simulator only.
- **State.** `PALACE_MOCK_BACKEND_RESET=1` clears defaults, app files and the
  keychain at launch. A relaunch that must keep state passes `0`.
- **Server-side change.** A route can raise a flag (`setsFlag`) that other
  routes require (`requiresFlag`), which is how the loans feed gains the book
  after the borrow. Flags persist across a relaunch and clear on reset.
- **Reader content.** The EPUB reader's text is in the accessibility tree
  (`app.webViews.staticTexts`). Readium preloads neighbouring chapters, so
  assert the expected chapter's heading and the absence of one that should
  not be loaded.
- **Synchronisation.** Tests wait for elements and predicates with bounded
  timeouts, never fixed sleeps.

`PalaceTests/Integration/MockBackendJourneyFixtureTests.swift` parses the
same fixtures through the app's parsers, so a fixture that drifts fails in the
unit suite first.

## What these journeys do not cover

They exercise the app's own wiring against fixtures. They say nothing about:

- a real circulation manager, or external SAML/OIDC identity providers;
- licensed DRM (Adobe, LCP) fulfilment;
- the background download session (under the mock backend, downloads use a
  foreground session so the URL protocol can serve them);
- background audio, device lock and real VoiceOver use.

Those stay in the manual rows of
[`REGRESSION_TEST_MATRIX.md`](REGRESSION_TEST_MATRIX.md).

## Adding a journey

1. Add fixtures under `PalaceUITests/Fixtures` and a scenario under
   `Fixtures/Scenarios`, using only the `palace-fixtures.test` host.
2. Extend `MockBackendJourneyFixtureTests` to parse the new fixtures.
3. Subclass `JourneyTestCase`, wrap each patron-visible stage in `step`, and
   assert what the patron sees (a label, a count, a row's identity), not just
   that a tap happened.
4. Break the product on purpose once and confirm the journey fails at the
   step you expect.
