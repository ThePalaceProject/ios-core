# simdrive journey recording runbook

Operational guide for capturing the regression-campaign journey recordings
(`~/.simdrive/recordings/<journey-id>/recording.yaml`). Pairs with
`RECORDING_COVERAGE_GAP.md` (the work-list) and `regression-areas.json` (the
manifest). Written 2026-06-12 from the live P0 recording sprint; each section is
a lesson learned the hard way.

## 0. Sim selection + hermetic baseline

- **Use YOUR assigned fleet sim**, not a sibling's. Check
  `~/.claude/peer-bridge/channels/palace/fleet-registry.json` → your identity →
  `sim_udid`. (During the sprint, w-stabilize = pool-3 `6C6BD82F…`; 141BD227 is
  w-mutex's — keychain-resetting it would wreck their session.)
- Kill stale xctest runners: `pgrep -f "xcodebuild test-without-building" | xargs -r kill -9`.
- Pre-grant permissions BEFORE launch (avoids the SpringBoard alert race):
  `xcrun simctl privacy <udid> grant notifications org.thepalaceproject.palace`
  (+ `location`). If it returns "Operation not permitted" (TCC locked), fall
  back to `mcp__simdrive__dismiss_first_launch_alerts choice=allow` after launch.
- Debug toggles: `xcrun simctl spawn <udid> defaults write org.thepalaceproject.palace showDeveloperSettings -bool true`.
- Keychain-reset for a clean signed-out baseline: `xcrun simctl keychain <udid> reset`.
  Keychain reset wipes credentials only — **libraries + the hidden-libraries
  toggle persist** (they're UserDefaults, not keychain).

## 1. Hidden/test libraries (A1QA, SAML-gorgon, OIDC) — LOAD-BEARING

**The `simctl ... defaults write NYPLUseBetaLibrariesKey -bool true` write is
NOT sufficient.** Setting the UserDefault directly does not fire the registry
re-fetch, so the QA/test libraries never load (Add Library only shows the
production registry — no A1QA).

**You must flip the toggle IN-APP** so the app re-fetches the hidden registry:
`Settings → Testing → "Enable Hidden Libraries"` (the switch maps to
`TPPSettings.useBetaLibraries`; toggling it posts `.TPPUseBetaDidChange` →
registry refetch). After that, search "A1QA" in `Add Library` and it appears as
**"A1QA Test Library"**. This unblocks every auth journey (basic / SAML / OIDC).

## 2. Credentials

From the harness vault (never committed; non-sensitive test accounts):
`~/harness/bin/harness creds get palace-ios.lib.<slug>` →
`HARNESS_USER` (barcode), `HARNESS_PASS` (PIN). Slugs available:
`palace-ios.lib.a1qa` (basic), `palace-ios.lib.danny-test-gorgon` (SAML),
`palace-ios.lib.main-street-city`. **No OIDC/icarus slug yet** — flag the
coordinator for OIDC creds before attempting `icarus-oidc-signin`.

SAML/OIDC sign-ins are IdP-redirect flows that may require an OTP/2FA code:
post `🔻 TRIGGERING LOGIN NOW` on the bridge and hold for the coordinator's
relay — **do not block silently**.

## 3. Precondition-ordering (state-dependent journeys)

A recording encodes the state it was captured from (its `requires:` block). The
recorder verifies that state before replaying step 1. So **journeys must be
recorded — and the campaign must replay them — in dependency order within a
cell**:

| Order | Journey class | Precondition to establish first |
|---|---|---|
| 1 | `*-stateless`, `library-picker`, catalog browse | just a loaded catalog (any library) |
| 2 | auth sign-IN (`a1qa-basic-signin`, SAML, OIDC) | signed-OUT account view (keychain reset) |
| 3 | auth sign-OUT (`a1qa-sign-out`) | **signed-IN** — run the sign-in first (replay `a1qa-basic-signin` puts the sim there in 3 steps) |
| 4 | circulation borrow | signed-in (or anonymous Palace Bookshelf) on a catalog |
| 5 | circulation return (`book-return-from-mybooks`) | a **borrowed book in My Books** — run a borrow first |
| 6 | reading (`reader2-*`, `PP-4161`) | the book **opened in the reader** / the search-source catalog loaded |

**Campaign implication:** the area-worker / campaign driver must run a cell's
journeys in this order (or each journey must self-establish its `requires:`),
else state-dependent journeys all FAIL with `state_contract_mismatch` on an
unmet precondition. (This is exactly why `PP-4161` and the `reading` shard FAIL
on a fresh signed-out sim — correctly surfaced as FAIL by the anti-false-pass
guard, PR #1080, not hidden as PASS.)

## 4. State-contract brittleness — two real gotchas (from PP-4161)

When a replay halts with `halt_reason: state_contract_mismatch`, check these
before assuming the recording is wrong:

1. **Device-name suffix (CAMPAIGN-CRITICAL).** `requires.sim.device` is matched
   **literally**. A recording captured on a base **`iPhone 16 Pro`** HALTS when
   replayed on a fleet sim named **`iPhone 16 Pro (pool-3)`** /
   `(fleet-N)` — reason: `sim.device: expected 'iPhone 16 Pro', got 'iPhone 16
   Pro (pool-3)'`. Since every fleet/pool sim carries a suffix, a base-sim
   recording mismatches **every** campaign sim. MITIGATIONS: (a) record on the
   same suffixed fleet sim you'll replay on (a recording made on pool-3 encodes
   `(pool-3)` and matches pool-3); (b) ask simdrive to normalize the device
   model (strip the `(…)` clone suffix) in the contract check; (c) as a
   stopgap, replay with `halt_on_state_mismatch=false` (drives steps but loses
   the precondition guard — only for verification, never for certification).
2. **OCR `text_subset_required` drift.** The contract requires a set of OCR'd
   on-screen strings. Book titles in a **horizontally-scrollable lane** scroll
   off-screen, and OCR mis-reads ("The Impeachmen" → "The Impeachr"), so a
   correct screen fails the subset check. MITIGATION: keep `text_subset_required`
   to **stable chrome** (lane headers like "DPLA Publications", "More…", tab
   labels) — NOT specific book titles that move or churn server-side.

## 5. The 914 / no-network checklist (campaign sim prep)

`HTTP status error 914` in the logs is **not a real HTTP code** — it is
`TPPErrorCode.invalidOrNoHTTPResponse` (`TPPErrorLogger.swift:207`): the request
got **no valid HTTP response** = the sim couldn't reach the catalog/registry
backend. It is an **environment** condition (sim network reachability), not a
product catalog bug. The campaign's build-install + sim-prep MUST verify network
access before recording/replaying. **Pre-flight:** launch the app, open a
Catalog, confirm lanes render (not a spinner / "A Problem Has Occurred"). pool-3
loaded the A1QA + Palace Bookshelf catalogs fine; the sim that showed 914 did
not — so it was that sim, not the app.

## 6. Recording procedure

1. Navigate (via the simdrive MCP: `observe` → `tap`/`type_text`/`swipe`) to the
   journey's **exact precondition state** (per §3). Navigation is NOT recorded.
2. `record_start name=<journey-id> tags=[…]`.
3. Drive **exactly the journey's steps** — no extra taps (keep the recording
   curated). `observe` between steps is fine (observes aren't recorded).
4. `record_stop` → writes `~/.simdrive/recordings/<journey-id>/recording.yaml`.
5. Verify: replay it from the same precondition with the anti-false-pass guard
   (`classify_replay`) — it must execute **all** steps (N/N), not halt.

**ALWAYS `observe` (annotate=true) immediately before a `tap text=…` /
`tap stable_id=…`** — text/mark resolution caches against the LAST observe; a
stale cache taps the wrong element. Re-observe after every navigation.

## 7. Status (sprint, 2026-06-12)

Banked: `a1qa-basic-signin` (3 steps, verified 3/3 replay), `a1qa-sign-out`
(2 steps). Remaining P0: `danny-saml-signin-init` + `icarus-oidc-signin`
(IdP/OTP — coordinator relay; OIDC needs vaulted creds), `library-picker-stateless`,
circulation (`book-return-from-mybooks`, `read-return-from-mybooks-roundtrip`).
