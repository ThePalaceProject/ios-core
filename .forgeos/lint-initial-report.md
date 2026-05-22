# Harness Lint — palace-ios

- **Scope:** Palace/
- **Files scanned:** 598
- **Findings:** 224 (17 blockers, 207 warnings)

## By category

| Category | Count | Autofix |
| --- | ---: | --- |
| `ticket_refs` | 168 | yes |
| `commented_out_code` | 32 | yes |
| `force_unwraps` | 17 | no |
| `archaeology` | 7 | no |

## Findings

### [BLOCK] `force_unwraps` — `Palace/Settings/TPPSettings+SE.swift:12`

force unwrap — use guard let / if let / ??

```
return URL(string: "https://librarysimplified.org/callbacks/SimplyE")!
```

### [WARN] `ticket_refs` — `Palace/Settings/AccountDetailView.swift:344`

ticket ref 'PP-4421' in comment

```
// PP-4421: explicit prompt with `.secondary` foreground overrides the
```

### [WARN] `ticket_refs` — `Palace/Settings/AccountDetailView.swift:369`

ticket ref 'PP-4421' in comment

```
// PP-4421: explicit prompt with `.secondary` foreground overrides
```

### [WARN] `ticket_refs` — `Palace/Settings/AccountDetailView.swift:448`

ticket ref 'PP-4282' in comment

```
/// PP-4282 / HelpSpot 17716: destructive "Reset This Library Account"
```

### [WARN] `ticket_refs` — `Palace/Settings/TPPSettingsAccountsList.swift:228`

ticket ref 'PP-3707' in comment

```
// PP-3707: Offer retry for library loading failures (likely transient)
```

### [WARN] `archaeology` — `Palace/Settings/TPPSettingsAccountsList.swift:75`

archaeology comment ('removed')

```
// the user previously added that have since been renamed, removed, or whose
```

### [WARN] `commented_out_code` — `Palace/Settings/TPPSettingsProviding.swift:24`

block of 2 lines of commented-out code

```
///     }
```

### [BLOCK] `force_unwraps` — `Palace/Settings/EULAView.swift:27`

force unwrap — use guard let / if let / ??

```
private static let fallbackEULAURL = URL(string: "https://thepalaceproject.org")!
```

### [WARN] `ticket_refs` — `Palace/Settings/AccountDetailViewModel.swift:78`

ticket ref 'PP-4020' in comment

```
// what silently blocked OIDC sign-in after PP-4020; the symmetric miss
```

### [WARN] `ticket_refs` — `Palace/Settings/AccountDetailViewModel.swift:437`

ticket ref 'PP-4229' in comment

```
/// the user does not get signed out by an accidental tap (PP-4229).
```

### [WARN] `ticket_refs` — `Palace/Settings/AccountDetailViewModel.swift:465`

ticket ref 'PP-4282' in comment

```
// MARK: - Reset Account (PP-4282 / HelpSpot 17716)
```

### [WARN] `ticket_refs` — `Palace/Settings/DeveloperSettings/TPPDeveloperSettingsTableViewController.swift:874`

ticket ref 'PP-4282' in comment

```
// MARK: - Reset Account Testing (PP-4282 / HelpSpot 17716)
```

### [WARN] `ticket_refs` — `Palace/Settings/DeveloperSettings/TPPDeveloperSettingsTableViewController.swift:924`

ticket ref 'PP-4275' in comment

```
//    PP-4275 silent-failure mode that Reset Account heals on next launch.
```

### [WARN] `ticket_refs` — `Palace/Settings/DeveloperSettings/TPPDeveloperSettingsTableViewController.swift:928`

ticket ref 'PP-4276' in comment

```
//    triggers the audiobook-OPEN re-auth in PP-4276 and that Reset clears.
```

### [BLOCK] `force_unwraps` — `Palace/Settings/NewSettings/SettingsViewModel.swift:108`

force unwrap — use guard let / if let / ??

```
customLibraryRegistryServer != nil && !customLibraryRegistryServer!.isEmpty
```

### [WARN] `commented_out_code` — `Palace/Settings/NewSettings/SettingsViewModel.swift:26`

block of 2 lines of commented-out code

```
/// let mockSettings = TPPSettingsMock()
```

### [BLOCK] `force_unwraps` — `Palace/Settings/NewSettings/TPPSettingsView.swift:138`

force unwrap — use guard let / if let / ??

```
private static let fallbackURL = URL(string: "https://thepalaceproject.org")!
```

### [BLOCK] `force_unwraps` — `Palace/Settings/Debug/DebugSettings.swift:284`

force unwrap — use guard let / if let / ??

```
let url = URL(string: "https://example.com/test-reserved-\(index)")!
```

### [BLOCK] `force_unwraps` — `Palace/Settings/Debug/DebugSettings.swift:333`

force unwrap — use guard let / if let / ??

```
let url = URL(string: "https://example.com/test-ready-\(index)")!
```

### [WARN] `ticket_refs` — `Palace/OPDS2/Models/OPDS2PublicationExtended.swift:298`

ticket ref 'PP-4230' in comment

```
// PP-4230: surface narrator into TPPBook.contributors so audiobook
```

### [BLOCK] `force_unwraps` — `Palace/Migrations/SEMigrations.swift:79`

force unwrap — use guard let / if let / ??

```
return $0 as? String ?? (idInt != nil ? accountMap[idInt!] : nil)
```

### [WARN] `ticket_refs` — `Palace/Migrations/SEMigrations.swift:32`

ticket ref 'PP-4179' in comment

```
// Palace v3.1.0 (PP-4179)
```

### [WARN] `ticket_refs` — `Palace/Migrations/SEMigrations.swift:36`

ticket ref 'HelpSpot 17517' in comment

```
// loans (HelpSpot 17517 — patron reported 1.2 GB backup footprint).
```

### [WARN] `ticket_refs` — `Palace/Migrations/BackupExclusionMigration.swift:5`

ticket ref 'PP-4179' in comment

```
//  PP-4179 — one-shot upgrade pass that walks Application Support and
```

### [WARN] `ticket_refs` — `Palace/CarPlay/CarPlayTemplateManager.swift:94`

ticket ref 'PP-3679' in comment

```
// PP-3679: If an audiobook is already playing, jump straight to Now Playing
```

### [WARN] `ticket_refs` — `Palace/CatalogUI/ViewModels/CatalogLaneMoreViewModel.swift:212`

ticket ref 'PP-3629' in comment

```
// Extract facets (including sort facets) from grouped feeds (PP-3629)
```

### [WARN] `ticket_refs` — `Palace/CatalogUI/Views/CatalogLaneRowView.swift:46`

ticket ref 'PP-4289' in comment

```
// PP-4289: lift the cover when a pointer (iPad pencil/mouse,
```

### [WARN] `ticket_refs` — `Palace/CatalogUI/Views/CatalogLaneRowView.swift:56`

ticket ref 'PP-3980' in comment

```
.accessibilityAddTraits(.isHeader) // PP-3980: scroll container exposes title in heading rotor
```

### [WARN] `ticket_refs` — `Palace/CatalogUI/Views/CatalogLaneRowView.swift:61`

ticket ref 'PP-3968' in comment

```
/// PP-3968: Single source of truth for the catalog cell VoiceOver label.
```

### [WARN] `ticket_refs` — `Palace/CatalogUI/Views/CatalogLaneRowView.swift:80`

ticket ref 'PP-3980' in comment

```
.accessibilityAddTraits(.isHeader) // PP-3980: expose swimlane title in heading rotor
```

### [WARN] `ticket_refs` — `Palace/CatalogUI/Views/CatalogLaneMoreView.swift:21`

ticket ref 'PP-4065' in comment

```
// PP-4065: scroll-to-top should fire exactly once, on the first appearance
```

### [WARN] `ticket_refs` — `Palace/CatalogUI/Views/CatalogLaneMoreView.swift:395`

ticket ref 'PP-4065' in comment

```
// PP-4065: scroll to top on the FIRST appearance only.
```

### [WARN] `ticket_refs` — `Palace/CatalogUI/Views/CatalogSearchView.swift:7`

ticket ref 'PP-3834' in comment

```
// MARK: - Accessibility focus target (PP-3834: move VoiceOver to results after search)
```

### [WARN] `ticket_refs` — `Palace/CatalogUI/Views/CatalogSearchView.swift:71`

ticket ref 'PP-4115' in comment

```
// PP-4115: when returning from book detail, registry state may have
```

### [WARN] `ticket_refs` — `Palace/ErrorHandling/TPPPresentationUtils.swift:69`

ticket ref 'HelpSpot 17716' in comment

```
// new) topmost VC and present there. HelpSpot 17716 follow-up.
```

### [WARN] `ticket_refs` — `Palace/ErrorHandling/PalaceError.swift:555`

ticket ref 'PP-3716' in comment

```
// PP-3716: OPDSFeedService wraps PalaceErrors in NSErrors to attach problem
```

### [WARN] `ticket_refs` — `Palace/ErrorHandling/TPPAlertUtils.swift:211`

ticket ref 'PP-3673' in comment

```
// PP-3673: Announce the alert to VoiceOver without moving focus.
```

### [WARN] `ticket_refs` — `Palace/ErrorHandling/TPPAlertUtils.swift:448`

ticket ref 'PP-3707' in comment

```
/// instead of a single "OK" button (PP-3707).
```

### [WARN] `ticket_refs` — `Palace/ErrorHandling/TPPAlertUtils.swift:450`

ticket ref 'PP-3439' in comment

```
/// This is the primary integration point for PP-3439.
```

### [WARN] `ticket_refs` — `Palace/ErrorHandling/TPPAlertUtils.swift:526`

ticket ref 'PP-3707' in comment

```
// PP-3707: Add Retry + Cancel for retryable errors, or OK for non-retryable
```

### [WARN] `commented_out_code` — `Palace/ErrorHandling/ProblemReportEmail.swift:86`

block of 2 lines of commented-out code

```
//    case .vision:
```

### [WARN] `ticket_refs` — `Palace/Reader2/UI/TPPReaderPositionsVC.swift:299`

ticket ref 'PP-3707' in comment

```
// PP-3707: Offer retry for bookmark sync failures (likely transient network issue)
```

### [WARN] `ticket_refs` — `Palace/Reader2/UI/TPPBaseReaderViewController.swift:321`

ticket ref 'PP-4326' in comment

```
// PP-4326 follow-up (product requirement): when a book is opened
```

### [WARN] `archaeology` — `Palace/Reader2/UI/TPPBaseReaderViewController.swift:495`

archaeology comment ('removed')

```
// at this point the bookmark has already been removed, so we just need
```

### [WARN] `ticket_refs` — `Palace/Reader2/UI/TPPEPUBViewController.swift:281`

ticket ref 'PP-3715' in comment

```
/// from its text fields (PP-3715).
```

### [WARN] `ticket_refs` — `Palace/Reader2/UI/TPPEPUBViewController.swift:297`

ticket ref 'PP-3715' in comment

```
/// and the keyboard won't appear (PP-3715).
```

### [WARN] `ticket_refs` — `Palace/Reader2/UI/TPPEPUBViewController.swift:333`

ticket ref 'PP-4289' in comment

```
/// Exposed at internal access (default) so PP-4289 regression tests can
```

### [WARN] `ticket_refs` — `Palace/Reader2/UI/TPPEPUBViewController.swift:337`

ticket ref 'PP-4289' in comment

```
// Cmd+W: PP-4289 — single-scene iPad-on-Mac apps treat default Cmd+W as
```

### [WARN] `ticket_refs` — `Palace/Reader2/UI/TPPEPUBViewController.swift:342`

ticket ref 'PP-4289' in comment

```
// Cmd+,: PP-4289 — discoverable shortcut for reader preferences.
```

### [WARN] `commented_out_code` — `Palace/Reader2/Bookmarks/TPPAnnotations.swift:98`

block of 2 lines of commented-out code

```
//   }
```

### [WARN] `commented_out_code` — `Palace/Reader2/ReaderStackConfiguration/AdobeDRM/AdobeDRMContainer.h:24`

block of 2 lines of commented-out code

```
/// @param fileURL file URL
```

### [WARN] `commented_out_code` — `Palace/Reader2/ReaderStackConfiguration/AdobeDRM/AdobeDRMContainer.h:28`

block of 2 lines of commented-out code

```
/// @param data Encrypted data
```

### [WARN] `ticket_refs` — `Palace/Reader2/ReaderStackConfiguration/AdobeDRM/AdobeCertificate.swift:251`

ticket ref 'PP-3649' in comment

```
// MARK: - On-Demand Activation (PP-3649)
```

### [WARN] `ticket_refs` — `Palace/Reader2/ReaderStackConfiguration/LCP/LicensesService.swift:59`

ticket ref 'PP-3704' in comment

```
// PP-3704: No credentials may be sent to googleapis.com — use ephemeral session
```

### [WARN] `ticket_refs` — `Palace/Reader2/ReaderStackConfiguration/LCP/LicensesService.swift:66`

ticket ref 'PP-3704' in comment

```
// Use sha256 for a stable session identifier across app launches (PP-3704).
```

### [WARN] `ticket_refs` — `Palace/Reader2/ReaderStackConfiguration/LCP/LCPPassphraseAuthenticationService.swift:8`

ticket ref '#41' in comment

```
For Passphrase in License Document, see https://readium.org/lcp-specs/releases/lcp/latest#41-introduction
```

### [WARN] `commented_out_code` — `Palace/Reader2/Typography/ReaderTypographyButton.swift:19`

block of 2 lines of commented-out code

```
/// }
```

### [WARN] `commented_out_code` — `Palace/Reader2/Typography/TypographyService.swift:240`

block of 2 lines of commented-out code

```
//   let css = typographyService.cssForCurrentSettings()
```

### [WARN] `ticket_refs` — `Palace/Audiobooks/NowPlayingCoordinator.swift:38`

ticket ref 'HelpSpot 17865' in comment

```
/// HelpSpot 17865 — if the writer was dry for longer than this while
```

### [WARN] `ticket_refs` — `Palace/Audiobooks/NowPlayingCoordinator.swift:100`

ticket ref 'HelpSpot 17865' in comment

```
// HelpSpot 17865 — self-subscribe to foreground notification so the
```

### [WARN] `ticket_refs` — `Palace/Audiobooks/NowPlayingCoordinator.swift:240`

ticket ref 'HelpSpot 17865' in comment

```
/// fires. HelpSpot 17865 instrumentation.
```

### [WARN] `ticket_refs` — `Palace/Audiobooks/NowPlayingCoordinator.swift:251`

ticket ref 'HelpSpot 17865' in comment

```
// HelpSpot 17865 — when the app is NOT active, bypass debounce.
```

### [WARN] `ticket_refs` — `Palace/Audiobooks/NowPlayingCoordinator.swift:311`

ticket ref 'HelpSpot 17865' in comment

```
/// HelpSpot 17865 instrumentation — on foreground return, if the writer
```

### [WARN] `commented_out_code` — `Palace/Audiobooks/AudiobookPositionPolicy.swift:193`

block of 2 lines of commented-out code

```
///     toolkit's track count as a stand-in. Must be > 0 to evaluate;
```

### [WARN] `ticket_refs` — `Palace/Audiobooks/AudiobookSessionManager.swift:331`

ticket ref 'PP-3707' in comment

```
// Surface the retry-with-dialog UX (PP-3707) for user-visible
```

### [WARN] `ticket_refs` — `Palace/Audiobooks/AudiobookSessionManager.swift:341`

ticket ref 'HelpSpot 17727' in comment

```
// HelpSpot 17727: SAML credentials went stale upstream
```

### [WARN] `ticket_refs` — `Palace/Audiobooks/AudiobookSessionManager.swift:912`

ticket ref 'HelpSpot 17727' in comment

```
/// HelpSpot 17727: Returns true when an audiobook OPEN (load) failed and the
```

### [WARN] `ticket_refs` — `Palace/Audiobooks/AudiobookSessionManager.swift:917`

ticket ref 'PP-3703' in comment

```
/// `shouldTriggerSAMLReauthForPlaybackFailure` (PP-3703, which handles the
```

### [WARN] `ticket_refs` — `Palace/Audiobooks/AudiobookSessionManager.swift:945`

ticket ref 'PP-3703' in comment

```
/// PP-3703: Returns true when playback failed due to bearer token refresh (e.g. 401 on CM fulfill)
```

### [WARN] `ticket_refs` — `Palace/Audiobooks/AudiobookSessionManager.swift:1125`

ticket ref 'PP-3703' in comment

```
// PP-3703: When BiblioBoard bearer token refresh fails due to SAML session expiration
```

### [WARN] `commented_out_code` — `Palace/Audiobooks/AudiobookSessionManager.swift:238`

block of 2 lines of commented-out code

```
/// for errors that have other dedicated presentation paths — keep this
```

### [WARN] `ticket_refs` — `Palace/Audiobooks/Vendors/LCPAdapter.swift:9`

ticket ref 'PP-4407' in comment

```
//  catches the Marketplace OPDS-shape regression PP-4407 (kill point lives in
```

### [WARN] `commented_out_code` — `Palace/Audiobooks/Vendors/LocalFileAdapter.swift:45`

block of 2 lines of commented-out code

```
/// Constructor-style DI per CLAUDE.md — `downloadCenter`, `fileReader`,
```

### [BLOCK] `force_unwraps` — `Palace/Audiobooks/DPLA/DPLAAudiobooks.swift:38`

force unwrap — use guard let / if let / ??

```
static let certificateUrl = URL(string: "https://listen.cantookaudio.com/.well-known/jwks.json")!
```

### [WARN] `ticket_refs` — `Palace/Audiobooks/LCP/LCPAudiobooks.swift:212`

ticket ref 'PP-4407' in comment

```
/// This is the load-bearing fix for the PP-4407 regression class. Ported
```

### [WARN] `archaeology` — `Palace/Audiobooks/LCP/LCPAudiobooks.swift:45`

archaeology comment ('deprecated')

```
/// - Parameter licenseUrl: optional license URL for streaming authentication (deprecated, use audiobookUrl)
```

### [BLOCK] `force_unwraps` — `Palace/AppInfrastructure/TPPConfiguration+SE.swift:15`

force unwrap — use guard let / if let / ??

```
static let betaUrl = URL(string: "https://registry.palaceproject.io/libraries/qa")!
```

### [BLOCK] `force_unwraps` — `Palace/AppInfrastructure/TPPConfiguration+SE.swift:16`

force unwrap — use guard let / if let / ??

```
static let prodUrl = URL(string: "https://registry.palaceproject.io/libraries")!
```

### [WARN] `commented_out_code` — `Palace/AppInfrastructure/NavigationHostView.swift:72`

block of 2 lines of commented-out code

```
// .overlay { CarModeEntryButton ... }
```

### [WARN] `ticket_refs` — `Palace/AppInfrastructure/TPPAppDelegate.swift:19`

ticket ref 'PP-4329' in comment

```
// PP-4329: state for the first-run library picker. Without these,
```

### [WARN] `ticket_refs` — `Palace/AppInfrastructure/TPPAppDelegate.swift:456`

ticket ref 'PP-4329' in comment

```
// PP-4329: idempotency — once we've presented the picker this
```

### [WARN] `ticket_refs` — `Palace/AppInfrastructure/TPPAppDelegate.swift:466`

ticket ref 'PP-4329' in comment

```
// PP-4329: remove the previous deferred observer (if any)
```

### [WARN] `ticket_refs` — `Palace/AppInfrastructure/NavigationCoordinator.swift:172`

ticket ref 'PP-3783' in comment

```
/// and "My Books" in the player returns to book detail instead of catalog (PP-3783).
```

### [WARN] `archaeology` — `Palace/AppInfrastructure/NavigationCoordinator.swift:70`

archaeology comment ('deprecated')

```
/// Weak references to prevent retain cycles (deprecated, kept for backward compatibility)
```

### [WARN] `ticket_refs` — `Palace/AppInfrastructure/SceneDelegate.swift:38`

ticket ref 'PP-4289' in comment

```
// PP-4289: when running as "Designed for iPad" on Apple Silicon Macs,
```

### [WARN] `ticket_refs` — `Palace/AppInfrastructure/SceneDelegate.swift:101`

ticket ref 'PP-4289' in comment

```
// MARK: - PP-4289 Mac geometry
```

### [WARN] `commented_out_code` — `Palace/Network/TPPUserFriendlyError.swift:18`

block of 2 lines of commented-out code

```
/// A user-friendly short message describing the error in more detail,
```

### [WARN] `ticket_refs` — `Palace/Network/TPPNetworkExecutor.swift:570`

ticket ref 'PP-4045' in comment

```
// Note: empty password is valid for pinless libraries (PP-4045).
```

### [WARN] `ticket_refs` — `Palace/Network/TPPNetworkResponder.swift:459`

ticket ref 'HelpSpot 17716' in comment

```
// HelpSpot 17716 follow-up, hotfix-branch device test 2026-05-01.
```

### [WARN] `commented_out_code` — `Palace/PDF/LCP/LCPPDFs.swift:115`

block of 2 lines of commented-out code

```
/// Decrypting data takes time;
```

### [WARN] `ticket_refs` — `Palace/PDF/Views/TPPPDFAccessibilityToolbar.swift:5`

ticket ref 'PP-3838' in comment

```
//  Created for PP-3838: Accessible page navigation for PDF Reader.
```

### [WARN] `ticket_refs` — `Palace/Holds/HoldsViewModel.swift:213`

ticket ref 'PP-3811' in comment

```
//      existing PP-3811 behaviour, kept verbatim so the auth-required
```

### [WARN] `ticket_refs` — `Palace/Utilities/TPPAccessibilityAnnouncementCenter.swift:24`

ticket ref 'PP-3673' in comment

```
/// avoid flooding the user with repeated announcements (PP-3673).
```

### [WARN] `ticket_refs` — `Palace/Utilities/TPPAccessibilityAnnouncementCenter.swift:26`

ticket ref 'PP-3839' in comment

```
/// **Transition-aware queuing (PP-3839):**
```

### [WARN] `ticket_refs` — `Palace/Utilities/TPPAccessibilityAnnouncementCenter.swift:86`

ticket ref 'PP-3839' in comment

```
// MARK: - Screen Transition Awareness (PP-3839)
```

### [WARN] `ticket_refs` — `Palace/Utilities/TPPAccessibilityAnnouncementCenter.swift:144`

ticket ref 'PP-3707' in comment

```
// MARK: - Retry Announcements (PP-3707)
```

### [WARN] `ticket_refs` — `Palace/Utilities/TPPAccessibilityAnnouncementCenter.swift:174`

ticket ref 'PP-3673' in comment

```
// MARK: - Search Announcements (PP-3673)
```

### [WARN] `ticket_refs` — `Palace/Utilities/TPPAccessibilityAnnouncementCenter.swift:197`

ticket ref 'PP-3673' in comment

```
// MARK: - Error / Status Announcements (PP-3673)
```

### [WARN] `ticket_refs` — `Palace/Utilities/ImageCache/GeneralCache.swift:79`

ticket ref 'PP-4020' in comment

```
// PP-4020: Reduced limits — GeneralCache backs ImageCache's compressed JPEG
```

### [WARN] `ticket_refs` — `Palace/Utilities/Networking/URL+BackupExclusion.swift:7`

ticket ref 'HelpSpot 17517' in comment

```
//  re-downloadable content (HelpSpot 17517 / PP-4179: patron reported
```

### [WARN] `ticket_refs` — `Palace/Utilities/Testing/AccessibilityIdentifiers.swift:370`

ticket ref 'PP-3707' in comment

```
// MARK: - Error Alerts (PP-3707)
```

### [WARN] `commented_out_code` — `Palace/Utilities/Concurrency/TPPBackgroundExecutor.swift:30`

block of 6 lines of commented-out code

```
/// {
```

### [WARN] `ticket_refs` — `Palace/Utilities/Localization/Strings.swift:18`

ticket ref 'PP-4326' in comment

```
// PP-4326: VoiceOver hint announced after the book row's canonical
```

### [WARN] `ticket_refs` — `Palace/Utilities/Localization/Strings.swift:137`

ticket ref 'PP-3968' in comment

```
// Accessibility - Book cell labels (PP-3968)
```

### [WARN] `ticket_refs` — `Palace/Utilities/Localization/Strings.swift:272`

ticket ref 'PP-3673' in comment

```
// MARK: - Search Announcements (PP-3673)
```

### [WARN] `ticket_refs` — `Palace/Utilities/Localization/Strings.swift:356`

ticket ref 'PP-3673' in comment

```
// MARK: - Status Announcements (PP-3673)
```

### [WARN] `commented_out_code` — `Palace/Utilities/Localization/Strings.swift:678`

block of 2 lines of commented-out code

```
/// borrow phase (network request to the borrow URL is in flight,
```

### [WARN] `ticket_refs` — `Palace/SignInLogic/TPPSignInBusinessLogic+SAML.swift:7`

ticket ref 'PP-3452' in comment

```
// SP-initiated SAML Single Logout client (PP-3452).
```

### [WARN] `ticket_refs` — `Palace/SignInLogic/TPPSignInBusinessLogic+SAML.swift:79`

ticket ref 'PP-3452' in comment

```
/// CM contract (PP-3452 / commit 914bff6):
```

### [WARN] `ticket_refs` — `Palace/SignInLogic/LegacySAMLAuthAdapter.swift:115`

ticket ref 'HelpSpot 17870' in comment

```
/// HelpSpot 17870 — weak back-reference so the presenter can synthesise
```

### [WARN] `ticket_refs` — `Palace/SignInLogic/LegacySAMLAuthAdapter.swift:177`

ticket ref 'HelpSpot 17870' in comment

```
// HelpSpot 17870 — build the handler ON THE NONISOLATED HOP so the
```

### [WARN] `ticket_refs` — `Palace/SignInLogic/TPPSignInBusinessLogic+SignOut.swift:240`

ticket ref 'PP-3452' in comment

```
// CM logout endpoints (OIDC and SAML SLO / PP-3452) require
```

### [WARN] `ticket_refs` — `Palace/SignInLogic/TPPSignInBusinessLogic+SignOut.swift:262`

ticket ref 'PP-3452' in comment

```
// SAML: if the CM advertises a logout link (PP-3452), call the CM's
```

### [WARN] `ticket_refs` — `Palace/SignInLogic/TPPSignInBusinessLogic+SignOut.swift:283`

ticket ref 'PP-3452' in comment

```
/// SAML + logout link present (PP-3452): authenticated API call to CM
```

### [WARN] `commented_out_code` — `Palace/SignInLogic/TPPSignInBusinessLogic+SignOut.swift:28`

block of 2 lines of commented-out code

```
// it works across different business-logic instances for the same library,
```

### [WARN] `ticket_refs` — `Palace/SignInLogic/TPPSignInBusinessLogic+UI.swift:32`

ticket ref 'PP-3819' in comment

```
// PP-3819: Cancel any pending sign-out for this library so that
```

### [WARN] `ticket_refs` — `Palace/SignInLogic/TPPSignInBusinessLogic+OAuth.swift:96`

ticket ref 'HelpSpot 17870' in comment

```
// HelpSpot 17870 — TPPSAMLHelper's `if let error, let errorTitle,
```

### [WARN] `ticket_refs` — `Palace/SignInLogic/TPPSignInBusinessLogic+OAuth.swift:127`

ticket ref 'HelpSpot 17870' in comment

```
// HelpSpot 17870 — synthesise an Error so TPPSAMLHelper's guard fires.
```

### [WARN] `ticket_refs` — `Palace/SignInLogic/TPPSignInBusinessLogic+OAuth.swift:149`

ticket ref 'HelpSpot 17870' in comment

```
// HelpSpot 17870 — synthesise an Error so TPPSAMLHelper's guard fires.
```

### [WARN] `ticket_refs` — `Palace/SignInLogic/TPPSignInBusinessLogic+OAuth.swift:184`

ticket ref 'HelpSpot 17870' in comment

```
// HelpSpot 17870 — preserve the parsed title in the title slot
```

### [WARN] `ticket_refs` — `Palace/SignInLogic/TPPSignInBusinessLogic+OAuth.swift:214`

ticket ref 'HelpSpot 17870' in comment

```
// HelpSpot 17870 — this is the literal silent-failure shape from
```

### [WARN] `commented_out_code` — `Palace/SignInLogic/TPPSignInBusinessLogic+OAuth.swift:96`

block of 2 lines of commented-out code

```
// HelpSpot 17870 — TPPSAMLHelper's `if let error, let errorTitle,
```

### [WARN] `ticket_refs` — `Palace/SignInLogic/SignInWebSheet.swift:107`

ticket ref 'PP-4289' in comment

```
// PP-4289: suppress automatic content-inset adjustments that cause the
```

### [WARN] `ticket_refs` — `Palace/SignInLogic/TPPSignInBusinessLogic+OIDC.swift:236`

ticket ref 'PP-4282' in comment

```
// PP-4282 (HelpSpot 17716): the patron-driven "Reset Account"
```

### [BLOCK] `force_unwraps` — `Palace/SignInLogic/TPPSignInBusinessLogic.swift:32`

force unwrap — use guard let / if let / ??

```
func authorize(withVendorID vendorID: String!, username: String!, password: String!, completion: ((Bool, Error?, String…
```

### [BLOCK] `force_unwraps` — `Palace/SignInLogic/TPPSignInBusinessLogic.swift:33`

force unwrap — use guard let / if let / ??

```
func deauthorize(withUsername username: String!, password: String!, userID: String!, deviceID: String!, completion: ((B…
```

### [WARN] `ticket_refs` — `Palace/SignInLogic/TPPSignInBusinessLogic.swift:98`

ticket ref 'HelpSpot 17870' in comment

```
// - presenter (HelpSpot 17870): needs businessLogic so its
```

### [WARN] `ticket_refs` — `Palace/SignInLogic/TPPSignInBusinessLogic.swift:445`

ticket ref 'PP-3649' in comment

```
// PP-3649: Save DRM credentials from profile document but defer Adobe
```

### [WARN] `commented_out_code` — `Palace/SignInLogic/TPPSignInBusinessLogic.swift:295`

block of 2 lines of commented-out code

```
/// - password reset link exists in authentication document;
```

### [WARN] `ticket_refs` — `Palace/SignInLogic/TPPSignInBusinessLogic+ForceReset.swift:9`

ticket ref 'HelpSpot 17716' in comment

```
// patrons whose app is already broken (HelpSpot 17716 Cornell SAML and
```

### [WARN] `ticket_refs` — `Palace/SignInLogic/TPPSignInBusinessLogic+ForceReset.swift:96`

ticket ref 'PP-3649' in comment

```
//      decrypt the EPUB. When activation gets desynced (PP-3649,
```

### [WARN] `ticket_refs` — `Palace/SignInLogic/TPPSignInBusinessLogic+DRM.swift:17`

ticket ref 'PP-3649' in comment

```
/// Adobe device activation. Activation is deferred to borrow time (PP-3649).
```

### [WARN] `ticket_refs` — `Palace/SignInLogic/TPPSignInBusinessLogic+DRM.swift:22`

ticket ref 'PP-3784' in comment

```
/// PP-3784 (barcode disappearing after sign-in).
```

### [WARN] `ticket_refs` — `Palace/Accounts/Library/Account+profileDocument.swift:29`

ticket ref 'PP-4164' in comment

```
// /patrons/me/ 401 storm at every cold relaunch (PP-4164 → F-007 →
```

### [WARN] `commented_out_code` — `Palace/Accounts/Library/AccountsManager.swift:318`

block of 2 lines of commented-out code

```
/// `AppContainer.production().audiobookSession.openAudiobook`,
```

### [WARN] `commented_out_code` — `Palace/Accounts/Library/AccountsManager.swift:402`

block of 2 lines of commented-out code

```
/// If we blindly fell back to a fresh/empty instance in that window,
```

### [WARN] `ticket_refs` — `Palace/Accounts/Library/Account.swift:95`

ticket ref 'PP-3452' in comment

```
/// added by CM PP-3452 for SP-initiated Single Logout.
```

### [WARN] `commented_out_code` — `Palace/Accounts/Library/Account.swift:374`

block of 2 lines of commented-out code

```
//      return Authentication.init(auth: opdsAuth)
```

### [WARN] `ticket_refs` — `Palace/Accounts/User/TPPUserAccount.swift:61`

ticket ref 'PP-3819' in comment

```
/// PP-3819: Incremented by `cancelPendingSignOut()` each time the user
```

### [WARN] `archaeology` — `Palace/Packages/PalaceKeychain/Tests/PalaceKeychainTests/TPPKeychainSwiftTests.swift:46`

archaeology comment ('removed')

```
// MARK: - Absence (missing, removed, cross-key)
```

### [WARN] `ticket_refs` — `Palace/Packages/PalaceAuth/Sources/PalaceAuth/TokenRequest.swift:58`

ticket ref 'PP-4045' in comment

```
// Memorial Library (PP-4045).
```

### [WARN] `commented_out_code` — `Palace/Packages/PalaceAuth/Sources/PalaceAuth/AuthSeams.swift:14`

block of 2 lines of commented-out code

```
//  Moving `TPPCurrentLibraryAccountProvider`, `TPPUserAccountResolving`,
```

### [WARN] `ticket_refs` — `Palace/Packages/PalaceCatalog/Sources/PalaceCatalog/TPPOPDSEntry.swift:78`

ticket ref 'PP-4046' in comment

```
// PP-4046 — Audience is published as `<category scheme="schema.org/audience">`;
```

### [WARN] `ticket_refs` — `Palace/Packages/PalaceCatalog/Sources/PalaceCatalog/TPPOPDSEntry.swift:85`

ticket ref 'PP-4046' in comment

```
// PP-4046 — `<dcterms:language>` is normally namespace-stripped to
```

### [WARN] `ticket_refs` — `Palace/Packages/PalaceCatalog/Sources/PalaceCatalog/TPPOPDSEntry.swift:89`

ticket ref 'PP-4230' in comment

```
// as the role/opf:role lookup in parseContributors (PP-4230).
```

### [WARN] `ticket_refs` — `Palace/Packages/PalaceCatalog/Sources/PalaceCatalog/TPPOPDSEntry.swift:130`

ticket ref 'PP-4230' in comment

```
// PP-4230: Foundation's XMLParser with shouldProcessNamespaces=true
```

### [BLOCK] `force_unwraps` — `Palace/Packages/PalaceCatalog/Sources/PalaceCatalog/OPDS2Feed.swift:59`

force unwrap — use guard let / if let / ??

```
navigation != nil && !navigation!.isEmpty
```

### [BLOCK] `force_unwraps` — `Palace/Packages/PalaceCatalog/Sources/PalaceCatalog/OPDS2Feed.swift:63`

force unwrap — use guard let / if let / ??

```
publications != nil && !publications!.isEmpty
```

### [BLOCK] `force_unwraps` — `Palace/Packages/PalaceCatalog/Sources/PalaceCatalog/OPDS2Feed.swift:67`

force unwrap — use guard let / if let / ??

```
groups != nil && !groups!.isEmpty
```

### [WARN] `ticket_refs` — `Palace/Packages/PalaceCatalog/Sources/PalaceCatalog/OPDS2Publication.swift:53`

ticket ref 'PP-4230' in comment

```
// Narrator follows the same array-or-single shape — PP-4230
```

### [WARN] `ticket_refs` — `Palace/Book/UI/BookDetail/BookDetailView.swift:543`

ticket ref 'PP-4046' in comment

```
// PP-4046: ordered by patron decision-making priority — Format/Audience/
```

### [WARN] `commented_out_code` — `Palace/Book/UI/BookDetail/BookButtonMapper.swift:15`

block of 2 lines of commented-out code

```
/// First look at registryState. If that alone dictates a clear UI state,
```

### [WARN] `ticket_refs` — `Palace/Book/UI/BookDetail/BookService.swift:95`

ticket ref 'PP-3707' in comment

```
/// `AudiobookSessionManager` after a loader failure, and by the PP-3707
```

### [WARN] `ticket_refs` — `Palace/Book/UI/BookDetail/BookService.swift:114`

ticket ref 'PP-3707' in comment

```
// PP-3707: Offer retry for audiobook open failures (may be transient)
```

### [WARN] `ticket_refs` — `Palace/Book/UI/BookDetail/BookImageView.swift:46`

ticket ref 'PP-4326' in comment

```
// PP-4326 follow-up: the inner Image carries .accessibilityHidden(true)
```

### [WARN] `ticket_refs` — `Palace/Book/UI/BookDetail/BookDetailViewModel.swift:697`

ticket ref 'HelpSpot 17716' in comment

```
// reinstalling. HelpSpot 17716 (Cornell SAML).
```

### [WARN] `archaeology` — `Palace/Book/UI/BookDetail/BookDetailViewModel.swift:636`

archaeology comment ('removed')

```
// Don't remove processing here - will be removed when state changes to .downloading or .downloadFailed
```

### [WARN] `ticket_refs` — `Palace/Book/Models/BookRegistrySync.swift:82`

ticket ref 'PP-4129' in comment

```
// PP-4129: books whose registry state says "downloaded" but whose content file
```

### [WARN] `ticket_refs` — `Palace/Book/Models/BookRegistrySync.swift:164`

ticket ref 'PP-3704' in comment

```
// from GCS (PP-3704).
```

### [WARN] `ticket_refs` — `Palace/Book/Models/BookRegistrySync.swift:224`

ticket ref 'PP-4129' in comment

```
// PP-4129: schedule recovery for orphaned downloads. Each scheduled block
```

### [WARN] `ticket_refs` — `Palace/Book/Models/BookRegistrySync.swift:281`

ticket ref 'PP-4129' in comment

```
// when the save commits (PP-4129 regression).
```

### [WARN] `ticket_refs` — `Palace/Book/Models/BookRegistrySync.swift:297`

ticket ref 'PP-4164' in comment

```
// Discovered by chaos-qa dogfood-3 → F-007 (PP-4164).
```

### [WARN] `ticket_refs` — `Palace/Book/Models/BookRegistrySync.swift:314`

ticket ref 'PP-4407' in comment

```
// PHASE 1 (swarm_81b5099e Bucket A — PP-4407): the loansUrl read used
```

### [WARN] `ticket_refs` — `Palace/Book/Models/BookRegistrySync.swift:488`

ticket ref 'PP-4129' in comment

```
/// contamination (PP-4129 regression).
```

### [WARN] `ticket_refs` — `Palace/Book/Models/BookRegistryStore.swift:75`

ticket ref 'PP-4129' in comment

```
/// exclusive access" (PP-4129 crash fix).
```

### [WARN] `ticket_refs` — `Palace/Book/Models/TPPBook+Accessibility.swift:5`

ticket ref 'PP-3968' in comment

```
//  PP-3968: Single source of truth for the VoiceOver label of a book cell.
```

### [WARN] `ticket_refs` — `Palace/Book/Models/TPPBookRegistry.swift:97`

ticket ref 'PP-4129' in comment

```
/// loop" symptom captured in PP-4129.
```

### [WARN] `ticket_refs` — `Palace/Book/Models/TPPBookRegistry.swift:134`

ticket ref 'PP-4129' in comment

```
// mutations against a mismatched auth context (PP-4129).
```

### [WARN] `ticket_refs` — `Palace/Book/Models/TPPBookRegistry.swift:563`

ticket ref 'PP-4129' in comment

```
// can't retarget the save to the wrong account — PP-4129), then pass it
```

### [WARN] `archaeology` — `Palace/Book/Models/TPPBookCoverRegistry.swift:489`

archaeology comment ('removed')

```
// `TPPBookCoverRegistryBridge` was removed in the swarm_d5a3d473 Track A
```

### [BLOCK] `force_unwraps` — `Palace/Book/Models/TPPBookRegistryRecord.swift:128`

force unwrap — use guard let / if let / ??

```
guard let state = TPPBookState(stateString!) else {
```

### [BLOCK] `force_unwraps` — `Palace/Book/Models/TPPBookRegistryRecord.swift:132`

force unwrap — use guard let / if let / ??

```
self.book = book!
```

### [WARN] `ticket_refs` — `Palace/Book/Models/TPPBook.swift:78`

ticket ref 'PP-4046' in comment

```
/// own row in the book detail INFORMATION section (PP-4046).
```

### [WARN] `ticket_refs` — `Palace/Book/Models/TPPBook.swift:82`

ticket ref 'PP-4046' in comment

```
/// Use ``displayLanguage`` for a localized name (PP-4046).
```

### [WARN] `ticket_refs` — `Palace/Book/Models/TPPBook.swift:633`

ticket ref 'PP-3649' in comment

```
/// PP-3649: Whether this book requires Adobe DRM activation before download.
```

### [WARN] `ticket_refs` — `Palace/Book/Models/BookmarkManager.swift:12`

ticket ref 'PP-4129' in comment

```
/// while the async work was in flight (PP-4129 regression).
```

### [WARN] `ticket_refs` — `Palace/FeatureFlags/RemoteFeatureFlags.swift:187`

ticket ref 'PP-4282' in comment

```
/// PP-4282: UserDefaults override that lets QA / support force the Reset
```

### [WARN] `ticket_refs` — `Palace/FeatureFlags/RemoteFeatureFlags.swift:193`

ticket ref 'PP-4282' in comment

```
/// PP-4282 / HelpSpot 17716: gate for the destructive "Reset This Library
```

### [WARN] `ticket_refs` — `Palace/Logging/TPPErrorLogger.swift:161`

ticket ref 'HelpSpot 17865' in comment

```
/// HelpSpot 17865 — NowPlayingCoordinator dry while `isPlaying` was true
```

### [WARN] `ticket_refs` — `Palace/MyBooks/MyBooksDownloadCenter.swift:129`

ticket ref 'PP-4114' in comment

```
/// `bindReachability()`. PP-4114 follow-up: lets a mid-flight reachability
```

### [WARN] `ticket_refs` — `Palace/MyBooks/MyBooksDownloadCenter.swift:776`

ticket ref 'PP-4114' in comment

```
// PP-4114 follow-up: react to mid-flight reachability drops. PR #901
```

### [WARN] `ticket_refs` — `Palace/MyBooks/MyBooksDownloadCenter.swift:788`

ticket ref 'PP-4114' in comment

```
// MARK: - PP-4114: mid-flight network drop handling
```

### [WARN] `ticket_refs` — `Palace/MyBooks/MyBooksDownloadCenter.swift:827`

ticket ref 'PP-4114' in comment

```
// the regression of PP-4114 reported on iPad. Only states that
```

### [WARN] `ticket_refs` — `Palace/MyBooks/MyBooksDownloadCenter.swift:911`

ticket ref 'PP-3673' in comment

```
// MARK: - Error Announcements (PP-3673)
```

### [WARN] `ticket_refs` — `Palace/MyBooks/MyBooksDownloadCenter.swift:948`

ticket ref 'PP-4114' in comment

```
// PP-4114 follow-up: pre-flight reachability before kicking off a new
```

### [WARN] `commented_out_code` — `Palace/MyBooks/MyBooksDownloadCenter.swift:106`

block of 2 lines of commented-out code

```
/// regular), and the inner regular-download routing (re-borrow,
```

### [WARN] `commented_out_code` — `Palace/MyBooks/MyBooksDownloadCenter.swift:868`

block of 2 lines of commented-out code

```
/// Services not yet in `AppContainer` (`errorActivityTracker`,
```

### [WARN] `commented_out_code` — `Palace/MyBooks/MyBooksDownloadCenter.swift:1593`

block of 2 lines of commented-out code

```
// Empty conformance — every required surface (bookRegistry, userAccount,
```

### [WARN] `ticket_refs` — `Palace/MyBooks/DownloadAuthRetryHandler.swift:128`

ticket ref 'PP-3716' in comment

```
// PP-3716: When browser-based auth expires, the server may return
```

### [WARN] `ticket_refs` — `Palace/MyBooks/DownloadAuthRetryHandler.swift:183`

ticket ref 'PP-3716' in comment

```
/// PP-3716: same treatment as the browser-session-expired path but
```

### [WARN] `ticket_refs` — `Palace/MyBooks/MyBooksDownloadCenter+Async.swift:32`

ticket ref 'PP-4178' in comment

```
/// the canonical implementation, PP-4178 rationale, and Place Hold
```

### [WARN] `ticket_refs` — `Palace/MyBooks/RightsManagementDispatcher.swift:132`

ticket ref 'PP-3649' in comment

```
// PP-3649 deferred Adobe device activation from login to borrow
```

### [WARN] `commented_out_code` — `Palace/MyBooks/RightsManagementDispatcher.swift:15`

block of 2 lines of commented-out code

```
//    - `.simplifiedBearerTokenJSON` — parse bearer-token JSON,
```

### [WARN] `commented_out_code` — `Palace/MyBooks/BookContentResetService.swift:73`

block of 2 lines of commented-out code

```
/// Resets the *current* account: cancels every in-flight download,
```

### [WARN] `ticket_refs` — `Palace/MyBooks/DownloadAlertPresenter.swift:106`

ticket ref 'PP-4114' in comment

```
// (the regression of PP-4114 — same root cause as the
```

### [WARN] `ticket_refs` — `Palace/MyBooks/DownloadAlertPresenter.swift:139`

ticket ref 'PP-3673' in comment

```
// Publish error and announce via VoiceOver (PP-3673)
```

### [WARN] `ticket_refs` — `Palace/MyBooks/DownloadAlertPresenter.swift:179`

ticket ref 'PP-3673' in comment

```
// Publish error and announce via VoiceOver (PP-3673)
```

### [WARN] `commented_out_code` — `Palace/MyBooks/DownloadAlertPresenter.swift:22`

block of 2 lines of commented-out code

```
//  for the retry-action closure, and `schedulePendingStartsIfPossible()`
```

### [WARN] `ticket_refs` — `Palace/MyBooks/TokenRefreshInterceptor.swift:113`

ticket ref 'PP-3716' in comment

```
// Check for "no active loan" with browser-based auth — treat as session expiry (PP-3716)
```

### [WARN] `ticket_refs` — `Palace/MyBooks/TokenRefreshInterceptor.swift:527`

ticket ref 'PP-4282' in comment

```
// EXCEPT when the patron just ran "Reset Account" (PP-4282 / HelpSpot 17716)
```

### [WARN] `commented_out_code` — `Palace/MyBooks/BookReturnService.swift:7`

block of 2 lines of commented-out code

```
//  LOC of nested error handling: Adobe DRM return, OPDS revoke fetch,
```

### [WARN] `ticket_refs` — `Palace/MyBooks/LCPFulfillmentHandler.swift:124`

ticket ref 'PP-4114' in comment

```
// PP-4114-adjacent: LCP audiobooks are marked
```

### [WARN] `ticket_refs` — `Palace/MyBooks/BorrowOperation.swift:11`

ticket ref 'PP-4178' in comment

```
//      injected fetchBook closure, evaluates the response (PP-4178
```

### [WARN] `ticket_refs` — `Palace/MyBooks/BorrowOperation.swift:18`

ticket ref 'PP-3707' in comment

```
//      gated by UserRetryTracker (PP-3707).
```

### [WARN] `ticket_refs` — `Palace/MyBooks/BorrowOperation.swift:129`

ticket ref 'PP-4178' in comment

```
///   NOT a failure. (PP-4178 follow-up — pre-fix, the alert was a false
```

### [WARN] `ticket_refs` — `Palace/MyBooks/BorrowOperation.swift:137`

ticket ref 'PP-4178' in comment

```
/// PP-4178 behavior (treat `unavailable`/`reserved` as race losses) for
```

### [WARN] `ticket_refs` — `Palace/MyBooks/BorrowOperation.swift:198`

ticket ref 'PP-4178' in comment

```
/// no-copies title and able only to Place Hold? PP-4178 follow-up.
```

### [WARN] `ticket_refs` — `Palace/MyBooks/BorrowOperation.swift:357`

ticket ref 'PP-3649' in comment

```
// PP-3649: ensure Adobe DRM device activation before proceeding.
```

### [WARN] `ticket_refs` — `Palace/MyBooks/BorrowOperation.swift:401`

ticket ref 'PP-4178' in comment

```
// PP-4178 follow-up: pass `book` (pre-borrow) so the helper can
```

### [WARN] `ticket_refs` — `Palace/MyBooks/BorrowOperation.swift:441`

ticket ref 'PP-3811' in comment

```
// PP-3811: trigger a sync after a short delay so hold position
```

### [WARN] `ticket_refs` — `Palace/MyBooks/BorrowOperation.swift:709`

ticket ref 'PP-3707' in comment

```
// PP-3707: gate retry button on per-operation retry budget.
```

### [WARN] `ticket_refs` — `Palace/MyBooks/LocalBookContentService.swift:8`

ticket ref 'PP-3704' in comment

```
//  `.lcpl` license is left on disk (PP-3704).
```

### [WARN] `ticket_refs` — `Palace/MyBooks/LocalBookContentService.swift:134`

ticket ref 'PP-3704' in comment

```
/// runs in the background (PP-3704).
```

### [WARN] `ticket_refs` — `Palace/MyBooks/AdobeDRMHandler.swift:147`

ticket ref 'PP-3649' in comment

```
// Pre-PP-3649 behavior was to show a sign-in modal, but now that we call
```

### [WARN] `ticket_refs` — `Palace/MyBooks/MyBooks/BookListView.swift:19`

ticket ref 'PP-3682' in comment

```
/// when browsing catalogs with many entries (e.g., Stanislaus County PP-3682).
```

### [WARN] `ticket_refs` — `Palace/MyBooks/MyBooks/BookListView.swift:25`

ticket ref 'PP-4326' in comment

```
// PP-4326: just wrap the cell in a SwiftUI Button with a
```

### [WARN] `ticket_refs` — `Palace/MyBooks/MyBooks/BookListView.swift:35`

ticket ref 'PP-3968' in comment

```
// that location, the outer row Button gets focus. PP-3968
```

### [WARN] `commented_out_code` — `Palace/MyBooks/MyBooks/MyBooksViewModel.swift:51`

block of 2 lines of commented-out code

```
/// Tracks whether the My Books tab is currently visible. When false,
```

### [WARN] `ticket_refs` — `Palace/MyBooks/MyBooks/BookCell/BookCellModel.swift:64`

ticket ref 'PP-4116' in comment

```
// reader presentations (PP-4116) because isLoading flips back to false
```

### [WARN] `ticket_refs` — `Palace/MyBooks/MyBooks/BookCell/BookCellModel.swift:266`

ticket ref 'PP-3811' in comment

```
// PP-3811: Update book from registry so availability data (hold position,
```

### [WARN] `ticket_refs` — `Palace/MyBooks/MyBooks/BookCell/BookCellModel.swift:377`

ticket ref 'PP-4114' in comment

```
/// PP-4114: react to mid-flight network drops. The pre-flight check on
```

### [WARN] `ticket_refs` — `Palace/MyBooks/MyBooks/BookCell/BookCellModel.swift:468`

ticket ref 'PP-4114' in comment

```
// PP-4114 pre-flight: Download/Retry/Get/Reserve all hit the network
```

### [WARN] `ticket_refs` — `Palace/MyBooks/MyBooks/BookCell/BookCell.swift:17`

ticket ref 'PP-4289' in comment

```
// PP-4289: `.hoverEffect(.lift)` gives Mac (iPad-on-Mac) and iPadOS
```

### [WARN] `ticket_refs` — `Palace/Notifications/NotificationService.swift:293`

ticket ref 'HelpSpot 17680' in comment

```
/// Why `hasUpdatedToken` is set only on confirmed success (HelpSpot 17680):
```

