# Mobile Integration Tests (Appium)

Appium-based integration tests for the Palace iOS app.

## Configuration

- `src/test/resources/settings.json` — Appium driver and capability settings. Contains profiles for `local` (simulator) and `browserstack` (CI) execution.
- `src/test/resources/devices.json` — Available simulator/device definitions.

## Profiles

| Profile       | Use case                        |
|---------------|---------------------------------|
| `local`       | Local Xcode simulator via Appium |
| `browserstack`| BrowserStack CI environment      |

Set `activeProfile` in `settings.json` to switch between them.

## Local Setup

1. Install Appium 2.x: `npm install -g appium`
2. Install XCUITest driver: `appium driver install xcuitest`
3. Ensure the target simulator is booted or let Appium boot it automatically.
4. Run tests with `activeProfile` set to `local`.

## BrowserStack CI

Set the following environment variables:
- `BROWSERSTACK_APP_URL` — uploaded app URL
- `BUILD_NAME` — CI build identifier
