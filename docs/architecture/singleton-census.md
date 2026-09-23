# Singleton census — god-class decomposition campaign (Wave 0 deliverable)

**Status:** reference · **Captured:** 2026-07-23 · **Feeds:** the `.shared`-read
monotone-down ratchet (`scripts/check-shared-read-count.sh`) and the per-wave
"any `.shared` in a file this wave touches gets a container seam or a written
exemption" checklist rule. **Fills** god-class-decomposition-plan.md §3c
"Explicitly not-yet-mapped" gap #1 (the full 39-row disposition table).

## How this was derived

- **Rows** = every `static let shared` / `static let sharedInstance` declaration
  in `Palace/` **excluding `Palace/Packages/`** (SPM packages are already the
  target shape). Grep: `grep -rnE 'static (let|var) +shared' Palace --exclude-dir=Packages`,
  comment lines discarded. This yields **exactly 39** declared singletons.
- **External fan-in** = count of `Type.shared` reference occurrences across
  `Palace/` (excl. Packages). Because every declaration is written
  `static let shared = Type()` (not `= Type.shared`), the grep count is the
  *external* read count — the declaration site does not self-count. This is the
  quantity the ratchet freezes.
- **Target home / disposition** = the ADR §3c table verbatim for the ~8
  high-fan-in singletons; the remaining rows filled mechanically by the same
  layer rules (§2.2 / §3c injection-mechanism column).

## Disposition legend

| Disposition | Meaning |
|---|---|
| **inject-via-container** | The campaign's default target: replace every `.shared` read with an `AppContainer` `let`/lazy seam injected by constructor. Removes the ambient reach entirely. |
| **permanent-infra** | Legitimately process-wide infrastructure (loggers, monitors, SDK wiring). Stays a singleton, but reached through a **narrow** container protocol so it is testable/mockable — no campaign to delete it, only to narrow its surface. |
| **platform-shim** | Wraps an Apple / DRM-binary / OS singleton (CoreLocation, `ASWebAuthentication` presentation anchor, `MFMailCompose` delegate, Adobe RMSDK / LCP binaries). Out of scope by design (triad platform-shim exemption); gets a thin protocol only where a touched call site needs testability. |
| **later** | Low fan-in; dispositioned by the wave that relocates its folder. No standalone action — the `.shared` reads die when the file gets constructor injection during its wave. |

## Census (39 rows, sorted by external fan-in)

| # | Singleton | Declared in | Fan-in | Target home (§2.2 / §3c) | Disposition |
|---|---|---:|---:|---|---|
| 1 | `RemoteFeatureFlags` | `FeatureFlags/RemoteFeatureFlags.swift` | 27 | **PalaceFeatureFlags** (new, Layer 0) — Firebase-backed impl stays app-target | **inject-via-container** (§3c: `let featureFlags: FeatureFlagProviding`) |
| 2 | `FirebaseManager` | `AppInfrastructure/FirebaseManager.swift` | 25 | **permanent app-target Infrastructure** (Firebase SDK) | **permanent-infra** (§3c: split into `CrashReporting` / `RemoteConfigProviding` capability protocols; no package names Firebase) |
| 3 | `LCPPDFOpenProgress` | `PDF/ReadiumPDF/LCPPDFOpenProgress.swift` | 24 | app-target Infrastructure (LCP DRM PDF open) | **inject-via-container** behind an `LCPOpenProgressReporting` protocol — high fan-in on a DRM path warrants a seam even though the impl stays app-side |
| 4 | `ImageCache` | `Utilities/ImageCache/ImageCacheType.swift` | 19 | app-target now; optional **PalaceImaging** later (zero cycle pressure) | **inject-via-container** (§3c: `container.imageCache` seam exists; migrate the reads; builder stops reading `.shared`) |
| 5 | `UserAccountPublisher` | `Accounts/User/UserAccountPublisher.swift` | 16 | **PalaceAccounts** (account-change broadcast of `CurrentAccountStore`) | **inject-via-container** (§3c: `container.userAccountPublisher` seam exists; migrate the 16 reads) |
| 6 | `AccountStateStore` | `Accounts/Library/AccountStateStore.swift` | 16 | **PalaceAccounts** (beside `AccountStateMachine`) | **inject-via-container** (§3c: `let accountStateStore` on container, injected into `AuthDocumentLoader`) |
| 7 | `NotificationService` | `Notifications/NotificationService.swift` | 13 | **permanent app-target Infrastructure** (FCM + `UNUserNotificationCenter`) | **permanent-infra** (§3c: narrow `NotificationScheduling` protocol; delegate half stays wired in `TPPAppDelegate`) |
| 8 | `TPPBookCoverRegistry` | `Book/Models/TPPBookCoverRegistry.swift` | 5 | **PalaceBookModel**/imaging (constructs on `ImageCache.shared`) | **inject-via-container** — moves with the book model in Wave 2; take `ImageCacheType` by injection |
| 9 | `AppLaunchTracker` | `Platform/AppLaunchTracker.swift` | 5 | app-target Platform | **permanent-infra** (launch-count telemetry; narrow seam) |
| 10 | `AccessibilityService` | `Platform/AccessibilityService.swift` | 5 | app-target Platform (wraps `UIAccessibility`) | **platform-shim** (protocol-wrap the touched reads for VoiceOver-state testability) |
| 11 | `TPPBookmarkDeletionLog` | `Reader2/Bookmarks/TPPBookmarkDeletionLog.swift` | 4 | **PalaceReadingPosition** / Reader2 | **later** (moves when Reader2 bookmark sync is touched) |
| 12 | `ProblemReportEmail` | `ErrorHandling/ProblemReportEmail.swift` | 4 | app-target ErrorHandling (Presentation) | **later** (cycle-2 cleanup: `DeviceContext` value inversion, §3b) |
| 13 | `LCPDecryptCache` | `Reader2/.../LCP/TPPLCPClient.swift` | 4 | app-target Infrastructure (LCP DRM) | **platform-shim** (LCP binary-adjacent cache; keep, protocol only if a test needs it) |
| 14 | `ErrorActivityTracker` | `ErrorHandling/ErrorActivityTracker.swift` | 4 | app-target ErrorHandling | **later** (error diagnostics; dispositioned in the ErrorHandling cleanup) |
| 15 | `DLNavigator` | `AppInfrastructure/DLNavigator.swift` | 4 | app-target AppInfrastructure (deep-link routing) | **inject-via-container** (routing is composition; give it a container seam) |
| 16 | `DeviceSpecificErrorMonitor` | `Utilities/DeviceSpecificErrorMonitor.swift` | 4 | app-target Utilities/ErrorHandling | **later** |
| 17 | `AudiobookFileLogger` | `Logging/AudiobookFileLogger.swift` | 4 | **PalaceLogging** | **permanent-infra** (file logger; narrow `LogSink` seam, ties to cycle-6 `LogArchiveExporting`) |
| 18 | `AdobeDRMService` | `Reader2/.../AdobeDRM/AdobeCertificate.swift` | 4 | app-target Infrastructure (Adobe RMSDK binary) | **platform-shim** (private DRM binary — permanent app-target; behind `TPPDRMAuthorizing` seam that already exists) |
| 19 | `UserRetryTracker` | `MyBooks/UserRetryTracker.swift` | 3 | **PalaceDownloads** | **inject-via-container** (moves in Wave 3b with the download engine) |
| 20 | `TPPAssociatedColors` | `Reader2/ReaderSettings/TPPAssociatedColors.swift` | 3 | app-target Reader2 (Presentation) | **later** |
| 21 | `OfflineQueueService` | `Platform/OfflineQueueService.swift` | 3 | **PalaceNetwork** (offline request queue) | **inject-via-container** (moves with the network layer; seam on the container) |
| 22 | `MockBackendService` | `Settings/Debug/MockBackend/MockBackendService.swift` | 3 | app-target Debug tooling | **later** (debug-only; written exemption — never ships in a release path) |
| 23 | `ErrorLogExporter` | `Logging/ErrorLogExporter.swift` | 2 | app-target Logging (Presentation export) | **later** (mail-export UI glue; cycle-6 `LogArchiveExporting`) |
| 24 | `UnifiedOPDSService` | `OPDS2/Service/UnifiedOPDSService.swift` | 1 | **PalaceCatalog** | **inject-via-container** (moves with catalog services) |
| 25 | `TypographyService` | `Reader2/Typography/TypographyService.swift` | 1 | app-target Reader2 (Presentation) | **later** |
| 26 | `TPPProblemDocumentCacheManager` | `ErrorHandling/TPPProblemDocumentCacheManager.swift` | 1 | app-target Infrastructure (problem-doc cache) | **later** |
| 27 | `TPPAnnouncementBusinessLogic` | `Accounts/User/Announcements/TPPAnnouncementBusinessLogic.swift` | 1 | app-target Presentation (announcements) | **later** |
| 28 | `SmallDeviceResolver` | `MyBooks/DiskBudgetManager.swift` | 1 | app-target Utilities (device heuristic) | **later** |
| 29 | `PerformanceMonitor` | `Platform/PerformanceMonitor.swift` | 1 | app-target Platform | **permanent-infra** (cross-cutting perf sampling) |
| 30 | `OIDCPresentationContextProvider` | `MyBooks/TokenRefreshInterceptor.swift` | 1 | app-target SignInLogic (Presentation) | **platform-shim** (`ASWebAuthentication` presentation anchor — UIKit-bound) |
| 31 | `OIDCBorrowPresentationContext` | `MyBooks/BorrowOperation.swift` | 1 | app-target SignInLogic (Presentation) | **platform-shim** (`ASWebAuthentication` anchor; moves out of BorrowOperation when it goes to PalaceDownloads — the anchor stays app-side) |
| 32 | `MemoryPressureMonitor` | `AppInfrastructure/TPPAppDelegate.swift` | 1 | app-target Infrastructure | **permanent-infra** (OS memory-pressure source) |
| 33 | `MailComposerDelegate` | `Logging/ErrorLogExporter.swift` | 1 | app-target Presentation | **platform-shim** (`MFMailComposeViewController` delegate) |
| 34 | `LogoProxyHolder` | `Settings/NewSettings/TPPSettingsView.swift` | 1 | app-target Settings (Presentation) | **later** |
| 35 | `LocationManager` | `Utilities/System/LocationManager.swift` | 1 | app-target Platform | **platform-shim** (CoreLocation wrapper) |
| 36 | `DeviceLogCollector` | `Logging/DeviceLogCollector.swift` | 1 | **PalaceLogging** | **permanent-infra** (device log sink) |
| 37 | `OPDS2FeedCache` | `OPDS2/Cache/OPDSFeedCache.swift` | 0 | **PalaceCatalog** | **later** (no external `.shared` reads — accessed internally; moves with catalog) |
| 38 | `OPDS1FeedCache` | `OPDS2/Cache/OPDSFeedCache.swift` | 0 | **PalaceCatalog** / app-target | **later** (no external `.shared` reads) |
| 39 | `FontManager` | `Reader2/Typography/FontManager.swift` | 0 | app-target Reader2 (Presentation) | **later** (0 external `.shared` reads — verify it is not dead before the Reader2 wave) |

## Notes / addenda

- **`TPPKeychain.shared` (fan-in 40) is NOT a row above** — it is declared inside
  the **PalaceKeychain package**, so it is out of the `Palace/`-excluding-Packages
  scan. It remains the single highest-fan-in singleton in the codebase; per §3c
  its `.shared` is retained only for the ObjC bridge until those call sites die,
  reached elsewhere via a `KeychainStoring` seam / `CredentialStore`. Tracked in
  the ADR §3c table, not here.
- **`TPPBookRegistry` has no `shared` declaration** — it was killed in triad
  Phase 6.6 (`container.bookRegistry` is the seam). Its file contains only a
  historical comment referencing the removed singleton, so it is correctly absent
  from the 39.
- **Fan-in ≠ removal priority alone.** The ratchet counts *all* non-system
  `.shared` reads together (baseline 250 in `scripts/godclass-shared-read-baseline.txt`);
  this table tells each wave *where* each read should land. A wave that touches
  any file above must move its listed `.shared` to the target seam or record a
  written exemption (permanent-infra / platform-shim / debug-only rows are the
  pre-approved exemptions).
- **Cross-check with the ratchet exclusion list:** the system singletons the
  ratchet excludes (`UIApplication`, `URLSession`, `URLCache`,
  `HTTPCookieStorage`, `FileManager`, `NotificationCenter`, `Bundle`, …) are
  Apple-owned and intentionally absent from this census — they are platform
  shims by definition, never campaign targets.
