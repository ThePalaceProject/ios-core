---
name: pp-4698-registry-availability-all
created: 2026-06-30
author: claude-opus-4-8
---

# Intent: PP-4698 — registry debugging menu applies `availability=all` when Hidden Libraries is on

## Problem
PP-4698 finishes the work explicitly deferred by #1123 (`dev-registry-explicit-url`).
The "Library Registry Debugging" developer field already accepts a full
`http(s)://…` URL fetched verbatim (the explicit-URL path bypasses the crawler via
`fallbackFetchFromNetwork`). What is missing is the *behavior* half of PP-4698:
when "Enable Hidden Libraries" (`TPPSettings.useBetaLibraries`) is set, the custom
registry fetch must carry an `availability=all` query parameter so hidden/testing
libraries are returned.

Today `availability=all` is appended ONLY inside `LibraryRegistryCrawler.crawlableURL`
and ONLY when the path ends in `/qa`. An explicit custom URL never hits the crawler,
so toggling "Enable Hidden Libraries" with a custom URL set has no effect on the
fetched URL. That is the gap.

Per the user decision (2026-06-30) the field stays as-is (#1123's flexible
full-URL + bare-host + `http://` model is superior to the ticket's literal
"fixed https" wording and already accepts arbitrary host/path/query).

## Claims
- `TPPConfiguration.customUrl(settings:)` injects `availability=all` into the
  returned URL's query **on the explicit-URL branch only**, gated on
  `settings.useBetaLibraries`. An existing `availability` query value is
  overwritten to `all`; all other query items are preserved.
- When `useBetaLibraries` is false, an explicit custom URL is returned exactly as
  the developer typed it (no `availability` injection, no stripping of any
  `availability` the developer typed themselves).
- Because `customUrlHash` derives from `customUrl`, toggling Hidden Libraries with
  a custom explicit URL set produces a distinct cache bucket and triggers a
  re-fetch via the existing `.TPPUseBetaDidChange` → `updateAccountSet` path.
- Tightens `customRegistryIsExplicitURL(settings:)` (deferred SoD item #1 from
  #1123) to return true only when the explicit string actually parses to a URL,
  removing the predicate/`customUrl()` divergence on unparseable input.

## Anti-claims
- Does NOT touch `LibraryRegistryCrawler.crawlableURL` — the bare-host `/qa`
  legacy path and the non-custom beta/prod registry paths are unchanged, so no
  double-append of `availability=all` and no change to production registry loading.
- Does NOT change the registry debugging cell UI / field model (kept flexible per
  the user decision).
- Does NOT change `AccountsManager` fetch dispatch (it already consumes `customUrl`
  / `customUrlHash`; the new query rides through unchanged).
- Does NOT touch any auth/borrow/return/download/DRM/audiobook critical path.

## Files in scope
- `Palace/AppInfrastructure/TPPConfiguration+SE.swift`
- `Palace/Utilities/Networking/URL+Extensions.swift`
- `PalaceTests/TPPConfigurationCustomRegistryTests.swift`
- `PalaceTests/Network/URLExtensionsTests.swift`
