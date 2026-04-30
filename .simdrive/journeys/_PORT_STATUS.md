# SpecterQA → simdrive Port Status

Honest accounting of which `.simdrive/journeys/*.yaml` flows have been ported to `.simdrive/journeys/`. Last updated 2026-04-30.

## Current state

- **8 / 25 ported and verified** (32%)
- **6 portable but not yet recorded** (estimated 1–4 hours each)
- **3 require capability simdrive doesn't have today** (audio-output verification, perf baselines, deep crash detection)
- **8 require sign-in / library state setup** (test credentials + state-reset preludes)

## Fully ported (8)

| SpecterQA journey | simdrive equivalent | Verified |
|---|---|---|
| `tab-navigation` | `tab-bar-tour.yaml` | ✅ struct-check passes |
| `catalog-browsing` | `catalog-browse-stateless.yaml` | ✅ struct-check passes |
| `search-flow` | `search-flow-stateful.yaml` | ✅ smoke passes |
| `settings-screen` | `settings-tour-stateless.yaml` | ✅ struct-check passes |
| `epub-reading` | `reader2-page-forward.yaml` | ✅ smoke passes (Reader2 chrome reachable) |
| `book-detail` | `book-detail-stateless.yaml` | ✅ struct-check passes (verifies title, Borrow, DESCRIPTION, Back) |
| `library-picker` | `library-picker-stateless.yaml` | ✅ struct-check passes (verifies Find Your Library, Add Library, Cancel) |
| `feed-refresh` | `feed-refresh-stateless.yaml` | ✅ struct-check passes (post-refresh chrome intact) |

## Portable, not yet ported (6)

These need to be recorded but use only primitives we already have. Estimated effort: small.

| SpecterQA journey | What it covers | Notes |
|---|---|---|
| `app-launch` | Cold launch + filter tabs (All/Ebooks/Audiobooks) | Fast win; near-trivial recording |
| `reservations-empty` | Holds tab empty state copy | Already partly covered by tab-bar-tour |
| `catalog-filter` | All/Ebooks/Audiobooks filter chips | Stateless; tap filter → verify lane filter |
| `smoke-test` | Multi-step happy path (launch + browse + open detail + back) | Composite of others |
| `persistence-reading-position` | Open book → page forward → kill → reopen → verify same page | Stateful; needs app-kill via `xcrun simctl terminate` |
| `concurrent-borrow` | Rapid Borrow taps → verify debounce | Stateful; needs cleanup |

## Capability-blocked (3) — simdrive doesn't have these primitives today

| SpecterQA journey | Blocker | Workaround |
|---|---|---|
| `audiobook-playback` | OCR can't verify audio output (no audible signal in screenshot) | Manual testing only. Out of scope for any vision-first driver. |
| `sleep-timer` | Same as above (audio playback verification) | Manual only. |
| `opds2-feed-parsing` | Was a network-layer test under SpecterQA's `ios_network`; simdrive has no equivalent network monitor today | Move to XCTest unit-level coverage. Filed as upstream simdrive feature request. |

## State-setup-blocked (8) — need sign-in + test credentials + state-reset

These require either authenticated session state or the ability to deterministically reset library/loan state between runs. Possible to port once we wire up:

1. A test-credentials helper (matches the SpecterQA pattern at `~/.simdrive/credentials/`)
2. State-reset preludes (sign out, remove libraries, clear keychain) per journey

| SpecterQA journey | Auth required | State mutation |
|---|---|---|
| `borrow-book` | A1QA Test Library (basic) | Borrows a book — needs Return to clean up |
| `book-transactions` | A1QA basic | Multi-step Borrow + Return |
| `return-book` | A1QA basic | Returns a borrowed book |
| `return-loan` | A1QA basic | Same as `return-book` (likely a duplicate) |
| `place-hold` | A1QA basic | Places a hold — needs cancel-hold cleanup |
| `switch-library` | Multiple libraries added | Switches between them |
| `credential-isolation` | Multiple libraries with different auth types | Security regression check |
| `sign-out` | Any signed-in account | Sign out + verify keychain cleanup |

## Capability gaps (simdrive vs SpecterQA, beyond journeys)

SpecterQA had MCP tools for things that aren't journey-shaped but mattered for the testing posture. These are gone from our automation surface as of the cutover:

| SpecterQA tool | Purpose | What we lose | Workaround / replacement |
|---|---|---|---|
| `ios_accessibility_audit` | Walks AX tree, flags missing labels / contrast issues | A11y regression detection | Manual AX inspector + simdrive `observe()` mark-vs-AX-tree diff (not yet built) |
| `ios_perf` / `ios_perf_baseline` / `ios_perf_compare` | CPU/memory/launch-time baselines | Performance regression detection | `scripts/run-perf-suite.sh` (Instruments traces) — heavier, manual trigger |
| `ios_crashes` | Crash log capture + parse | Crash-on-replay detection | Sim's CrashReporter + manual log inspection |
| `ios_network` | HTTP request/response monitoring during a session | Contract-drift signals during a flow | `palace-cm-monitor` MCP for backend drift; no in-flow signal today |
| `ios_app_state` | Foreground / background / suspended detection | State-aware journeys | Workaround: shell out to `xcrun simctl listapps` JSON parse |
| `ios_set_appearance` | Light/dark mode toggle | Theme-switch journeys | Workaround: `xcrun simctl ui <UDID> appearance dark` BEFORE session_start |
| `ios_pre_grant_permissions` | Pre-grant push/location/etc. permissions | Avoid SpringBoard alert race | Workaround: `xcrun simctl privacy <UDID> grant ...` BEFORE session_start |
| `ios_dismiss_*` | Dismiss SpringBoard alerts, sheets, springboard alerts | Race-handling | Workaround: simdrive `tap` at known coords; structural check after to confirm dismissal |

## Recommendations

1. **Port the 9 easy ones first** (no auth needed). Lifts coverage to 14/25 (~56%).
2. **Wire credentials + state-reset preludes** to enable the 8 auth-required journeys. Lifts to 22/25 (~88%).
3. **Accept the 3 blocked journeys as manual-only** until simdrive ships network/perf/crash primitives.
4. **File the 8 capability gaps as upstream feature requests** in the next dogfood update.
5. **Don't claim SpecterQA parity until items 1+2 are done** — today the cutover is "primitives ported, corpus partial."

## Appendix — full SpecterQA journey list (for cross-reference)

```
app-launch              borrow-book             credential-isolation
audiobook-playback      catalog-browsing        epub-reading
book-detail             catalog-filter          feed-refresh
book-transactions       concurrent-borrow       library-picker
opds2-feed-parsing      persistence-reading-position  place-hold
reservations-empty      return-book             return-loan
search-flow             settings-screen         sign-out
sleep-timer             smoke-test              switch-library
tab-navigation
```
