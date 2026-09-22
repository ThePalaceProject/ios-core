---
name: pp5070-mdm-managed-app-config
created: 2026-09-22
author: Maurice Carrier
branch: spike/PP-5070-mdm-managed-app-config (off origin/develop)
priority: PP-5070 spike (timeboxed 2 days) — K-12 partner deploy-time library pre-selection
---

# Intent: prove the app can read a library from MDM Managed App Configuration

## Context

PP-5070 asks whether a K-12 partner can push Palace to every student device and
have each device already pointed at the right one of their three divisional
libraries. This branch is the spike's evidence leg: a throwaway prototype that
proves the app can read a value the MDM sends and act on it, so the follow-up
story can be sized honestly. It is NOT expected to ship as-is.

Registry facts established before writing any code (all measured, not assumed):

- The partner is **North Shore Country Day** (Winnetka, IL). It is the ONLY
  organisation in the whole registry with all three of Lower/Middle/Upper
  School — 1 of 1 across 1,651 entries, so the identification is not a guess.
- All three are in the **production** feed the shipping app reads
  (`/libraries/crawlable`, 1,465 entries); none needs the hidden-libraries
  toggle. The "registry question" the ticket put first comes back clean.
- All three authenticate with **SAML 2.0 Web SSO** (Google Workspace IdP), so
  there is **no COPPA age gate** — but there IS a web-sheet sign-in before a
  student can borrow. Anonymous catalog browsing works (226 entries on Lower).
- The registry serves a **single-library endpoint**
  (`/library/{uuid}`, accepting both `urn:uuid:…` and bare UUID) whose payload
  decodes as the same `OPDS2CatalogsFeed` the app already parses. That is the
  fallback if a configured library is absent from the loaded set.

## Claims

1. `UserDefaults.standard.dictionary(forKey: "com.apple.configuration.managed")`
   is the only channel needed — no entitlement, no Info.plist key, no SDK.
   Nothing in the tree reads it today (grep: zero hits).
2. Pre-configuring a library is exactly the five side effects the first-run
   picker's selection callback already performs in
   `TPPAppDelegate.presentFirstRunFlowIfNeeded` (append to
   `settingsAccountIdsList`, set `accountMainFeedURL`, set
   `accountsManager.currentAccount`, load the auth document, post
   `.TPPCurrentAccountDidChange`). The prototype reuses that contract rather
   than inventing a second way to select a library.
3. The apply decision is a finite table over (configuration present?,
   fingerprint already applied?, registry loaded?, identifier resolves?) and is
   asserted cell by cell, not by scenario.
4. The re-application rule is **apply once per configuration VALUE**: an app
   update does not re-apply, a student who removes the library is not fought, an
   MDM that changes the value re-applies, and a re-imaged device (wiped
   defaults) applies again. The stored fingerprint is what makes those four
   outcomes fall out of one rule.
5. The identifier accepted from the MDM is normalized: `urn:uuid:` prefix
   optional, case-insensitive, whitespace trimmed — because a registry UUID is
   the thing an administrator is most likely to paste wrong, and `Account.uuid`
   is the full `urn:uuid:` form, not the bare UUID.

## Anti-claims

- This does NOT lock the app to one library. Other libraries stay addable and
  removable; there is no kiosk mode.
- This does NOT sign a student in. These three libraries are SAML; the student
  still meets a Google SSO web sheet before borrowing. The honest answer to the
  ticket's "does this get a young student all the way to a book" is **one less
  step, not zero**.
- This does NOT implement the single-library registry fallback fetch. The
  endpoint is proven to exist and to decode with the app's own parser (fixture
  test); building the fetch belongs to the follow-up story.
- This does NOT touch the dead Firebase Dynamic Links path, which requires a
  `barcode` alongside `libraryid` and is therefore useless for SAML libraries
  even if FDL were still alive.

## Files in scope

- `Palace/AppInfrastructure/ManagedAppConfiguration.swift` (new — parse + decide, pure)
- `Palace/AppInfrastructure/ManagedLibraryPreconfigurator.swift` (new — apply)
- `Palace/AppInfrastructure/TPPAppDelegate.swift` (wiring, one call site)
- `PalaceTests/AppInfrastructure/ManagedAppConfigurationTests.swift` (new)
- `PalaceTests/AppInfrastructure/ManagedLibraryPreconfiguratorTests.swift` (new)

## Not done

- Android parity. Needs the Android session to mirror the key names before the
  partner gets one configuration document; flagged on the ticket, not built here.
- Shared-vs-one-to-one device question and which MDM the partner runs. Both are
  questions for the partner, not the code.

## Revised after measurement (2026-09-22) — the bundled snapshot invalidates claim 2

Claim 2 as written above ("resolve the identifier against the loaded registry")
is WRONG on the only launch that matters, and the measurement that shows it is
the reason this branch exists rather than a design document.

On cold first launch there is no disk cache, so `AccountRegistryLoader` hydrates
`Palace/Accounts/Library/bundled_registry.json` — a BUILD-TIME cut — posts
`.TPPCatalogDidLoad`, and only then fetches from the network. That snapshot is
70 days old, holds **1,142** libraries against the registry's current 1,465, and
its newest entry was modified 2026-05-20. All three North Shore libraries are
**absent** from it (they carry `modified` 2026-09-11). It does contain 728 other
`il.thepalaceproject.org` catalogs, so this is not a consortium-wide gap — it is
the ordinary staleness of a checked-in snapshot.

Consequence for the naive design: the first `.TPPCatalogDidLoad` of a managed
install finds the registry loaded and the configured identifier unresolvable, so
the picker appears — the exact barrier the feature removes — and the device
silently self-heals on the SECOND launch once the network crawl is on disk. A
7-year-old meets the picker once, which is once too many, and a log would read
as though the administrator's identifier were wrong.

So the design gains a bounded wait rather than a registry-insertion seam:

- `ManagedLibraryPreconfigurator.launchStep` turns `.registryNotLoaded` and
  `.unresolved` into `.waitForRegistry` for 15 s, then `.presentPicker`. The
  network crawl supersedes the snapshot well inside that window.
- The wait is bounded because an unbounded one leaves a genuinely misconfigured
  device with no way to pick a library at all — strictly worse than today.
- `.noConfiguration` and `.alreadyApplied` never wait, so an unmanaged install
  keeps its current timing exactly.

The alternative — fetching the library from the registry's single-library
endpoint on `.unresolved` — is proven feasible (the endpoint exists, accepts both
identifier spellings, and its verbatim payload decodes with the app's own
`OPDS2CatalogsFeed` parser; fixture test included) but is NOT built here, because
an `Account` obtained that way is absent from `AccountRegistryStore` and
`AccountsManager.currentAccount`'s getter resolves through that store — so
selecting it would leave `currentAccountId` set and `currentAccount` nil. Making
that work needs a production seam to merge a single library into the registry
store (only the DEBUG `_seedAccountForTesting` does it today). That is real
follow-up scope and is sized as such rather than smuggled into a spike.

Second-order recommendation, independent of this feature: refresh the bundled
snapshot on the release cycle. The freshness check
(`scripts/check_registry_snapshot_freshness.sh`) only emits an Xcode `warning:`,
and a 70-day-old snapshot means every new library in the registry is invisible
to a fresh install until its network crawl lands.
