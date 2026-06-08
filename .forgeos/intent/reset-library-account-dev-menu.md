---
name: reset-library-account-dev-menu
created: 2026-06-08
author: Maurice Carrier
---

# Intent: promote account reset to a permanent Developer Settings feature

## Context

The destructive "Reset This Library Account" (`performForceReset`, PP-4282 /
HelpSpot 17716) is currently a Firebase-gated button in the per-library Account
Detail screen. Two asks:

1. Make it a **permanent** feature (no Firebase gate) and relocate it to the
   Developer Settings menu's new **Support tier**.
2. Restructure Developer Settings so production users (who can unlock the menu)
   see only production-relevant tools; debug/engineering tooling is hidden in
   App Store builds.

Verification finding (2026-06-08): the existing `performForceReset` is NOT
purely active-library-scoped. Credentials, downloaded books, bookmarks, FCM
token, and SAML/IDP state are scoped to `libraryAccountID`, but the WKWebView
data wipe (step 6) and Adobe DRM device deauthorize (step 2.5) are
app/device-global — they affect every library. So a single "only this library"
reset requires a NEW scoped path; the existing aggressive reset is kept as a
clearly-labeled "Full Reset (All Libraries)".

## Claims

- Adds a new active-library-scoped reset, `performScopedReset`, that clears ONLY
  the current library's credentials, downloaded books, bookmarks, registry, FCM
  token, and SAML/IDP state, plus that library's web cookies scoped via
  `Account.authSurfaceHosts` — and does NOT deauthorize Adobe DRM or touch other
  libraries.
- Adds two Developer Settings Support-tier rows: "Reset This Library" (scoped)
  and "Full Reset (All Libraries)" (existing `performForceReset`), each with a
  destructive confirmation alert.
- Adds an audience tier to `TPPDeveloperSettingsTableViewController.Section`
  (support vs engineering); engineering sections render only in DEBUG/TestFlight
  builds and are hidden in App Store builds.
- Removes the Firebase `reset_account_enabled` gate from the reset's
  availability; removes the `.resetAccount` cell from `AccountDetailView` /
  `AccountDetailViewModel` (reset moves to Developer Settings).

## Anti-claims

- Does NOT change `performForceReset`'s behavior (the Full Reset stays exactly as
  the stuck-state recovery tool it is today).
- Does NOT touch server-side loans/holds for any library.
- Does NOT change sign-in, borrow, return, or download flows.
- Does NOT alter Adobe DRM behavior for the Full Reset path.

## Files in scope

- `Palace/SignInLogic/TPPSignInBusinessLogic+ForceReset.swift` (new scoped reset)
- `Palace/Settings/DeveloperSettings/TPPDeveloperSettingsTableViewController.swift` (tiering + rows)
- `Palace/Settings/AccountDetailViewModel.swift` (remove gate + cell)
- `Palace/Settings/AccountDetailView.swift` (remove cell rendering)
- `Palace/FeatureFlags/RemoteFeatureFlags.swift` (retire reset gate)
- `PalaceTests/...` (scoped-reset behavior + tiering visibility tests)
