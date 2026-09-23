---
name: dev-registry-explicit-url
created: 2026-06-26
author: Maurice Carrier
branch: feature/dev-registry-explicit-url
priority: dev-tooling — unblocks QA of registry facets on the complete /libraries feed
---

# Intent: let the dev-settings registry field target an explicit URL fetched verbatim

## Context

QA needs to validate the new `order` / `availability` facets the registry is
adding to the complete `/libraries` feed (currently dev-registry-only) before it
deploys widely. The iOS developer-settings "Library Registry Debugging" field
could not exercise it: it hardcoded a `/libraries/qa` suffix
(`TPPConfiguration.customUrl`), and the current app additionally rewrites any base
to the crawlable endpoint (`LibraryRegistryCrawler.crawlableURL`). So a dev could
never point the app at a bare `/libraries`.

Grounded surface:
- `TPPConfiguration.customUrl(settings:)` is the single origin of the custom
  registry URL; `customUrlHash(settings:)` derives the cache key from it.
- `AccountsManager.fetchFromNetwork` / `refreshInBackground` invoke the crawler;
  `fallbackFetchFromNetwork` already performs a verbatim unauthenticated direct
  GET + cache + load, used today as the crawler-failure fallback.
- `TPPRegistryDebuggingCell` renders a fixed `https://` prefix + `/libraries/qa`
  postfix around the input field.

## Claims

- `TPPConfiguration.customUrl(settings:)` uses a full `http(s)://…` entry
  **verbatim**; a bare host keeps the legacy `https://<host>/libraries/qa`.
  Empty / whitespace-only input returns `nil` (was: malformed `https:///libraries/qa`).
- New `TPPConfiguration.customRegistryIsExplicitURL(settings:)` predicate reports
  whether the configured value is a full URL.
- `AccountsManager.fetchFromNetwork` and `refreshInBackground` early-return to
  `fallbackFetchFromNetwork` (verbatim direct GET, no crawlable rewrite) when the
  custom registry is an explicit URL.
- `TPPRegistryDebuggingCell` accepts a full URL and hides the `https://` /
  `/libraries/qa` affix labels when the input looks like a full URL; placeholder
  updated to "host, or full https:// URL".

## Verification

- Unit: `TPPConfigurationCustomRegistryTests` — 8 tests (bare-host→/libraries/qa,
  full https/http verbatim, query preserved, whitespace trim, empty→nil,
  hash-consistency). All green via `-only-testing` spot-check.
- Runtime (simdrive, iPhone 16 Pro): entered
  `https://registry.dev.palaceproject.io/libraries` → affixes hid → Set →
  "Configuration Updated" → Add Library rendered exactly the 1 catalog from the
  bare feed ("Minotaur Test Library"), confirming the app fetched `/libraries`
  verbatim (crawlable variant returns 4) and parsed the new facets cleanly.
- Pre-PR: `scripts/verify-pr.sh --quick` (full scheme) — pending.

## Anti-claims

- Everything is gated behind a custom registry being set. With no custom registry
  (every production user), `customRegistryIsExplicitURL` is `false` and the
  crawler path is unchanged — production registry loading is untouched.
- Does NOT change `LibraryRegistryCrawler.crawlableURL` or the crawler itself.
- Does NOT change prod/beta URL selection (`prodUrl` / `betaUrl`), the
  `useBetaLibraries` ("Enable Hidden Libraries") toggle, or any network/auth code.
- Does NOT alter the registry feed parser (`OPDS2CatalogsFeed`); facet-parse
  safety is a property of the existing lenient decoder, validated separately.

## Files in scope

- `Palace/AppInfrastructure/TPPConfiguration+SE.swift` — `customUrl`,
  `customRegistryIsExplicitURL`, `isExplicitURL`, `customUrlHash(settings:)`.
- `Palace/Accounts/Library/AccountsManager.swift` — explicit-URL early-return in
  `fetchFromNetwork` + `refreshInBackground`.
- `Palace/Settings/DeveloperSettings/TPPRegistryDebuggingCell.swift` — full-URL
  input + `updateAffixVisibility`.
- `PalaceTests/TPPConfigurationCustomRegistryTests.swift` — 8 unit tests.
- `Palace.xcodeproj/project.pbxproj` — test file registration.
