# Palace iOS Core

Library reading app supporting EPUB, PDF, and audiobooks with multiple DRM systems.

## Build & Test

```bash
# Build (use xcodeproj, NOT workspace — workspace hits Firebase SPM issues)
xcodebuild -project Palace.xcodeproj -scheme Palace \
  -destination 'platform=iOS Simulator,id=DF4A2A27-9888-429D-A749-2E157A049A37' build

# Run all tests
xcodebuild -project Palace.xcodeproj -scheme Palace \
  -destination 'platform=iOS Simulator,id=DF4A2A27-9888-429D-A749-2E157A049A37' test

# Run a single test class
xcodebuild -project Palace.xcodeproj -scheme Palace \
  -destination 'platform=iOS Simulator,id=DF4A2A27-9888-429D-A749-2E157A049A37' \
  -only-testing:PalaceTests/MyTestClass test
```

- Xcode 16.1+, iOS 16.0+ deployment target
- Two targets: `Palace` (full DRM) and `Palace-noDRM` (open-source)
- Rosetta required on Apple Silicon for DRM builds

## Project Structure

```
Palace/
  AppInfrastructure/   # App launch, Firebase, navigation
  Accounts/            # Library account management
  Book/                # Book models and detail views
  MyBooks/             # Downloaded books management
  Catalog/             # Catalog UI and data (legacy)
  CatalogDomain/       # Catalog API, repositories, parsing
  CatalogUI/           # Catalog SwiftUI views
  Audiobooks/          # Audiobook playback management
  Reader2/             # EPUB reader (Readium 3.x, SwiftUI)
  Reader3/             # PDF reader
  OPDS/                # OPDS 1.x parsing (Objective-C)
  OPDS2/               # OPDS 2.0 parsing and services
  SignInLogic/         # Authentication flows (OAuth, SAML, basic)
  Network/             # HTTP networking layer
  Keychain/            # Secure credential storage
  Utilities/           # Extensions, helpers, concurrency
  Migrations/          # App upgrade migrations

PalaceTests/
  Mocks/               # 21 shared mock implementations
  ViewModels/          # ViewModel unit tests
  Network/             # Network layer tests
  Snapshots/           # UI snapshot tests
  (organized by feature area)

PalaceConfig/          # Assets, certs, plists
scripts/               # Build, test, release automation
```

## Architecture

- **MVVM + Services** — ViewModels are `@MainActor ObservableObject` with `@Published` properties
- **SwiftUI** for new UI, **UIKit** for legacy screens
- **Combine** for reactive state management
- **Manual DI** via protocols — no framework, inject through constructors
- Mixed **Swift/Objective-C** (legacy OPDS parsing)

## Dependencies

- **Readium 3.x** (swift-toolkit) — EPUB/PDF rendering via SPM
- **Firebase** — remote config, crash reporting
- **Adobe RMSDK / LCP** — DRM (private repos)
- **PalaceAudiobookToolkit** — audiobook playback (git submodule)
- **Carthage** — some binary framework management

## Key Patterns

- Network: `TPPNetworkExecutor` → `TPPNetworkResponder` → domain models
- Offline queue: `TPPNetworkQueue` retries failed requests
- Book state: `TPPBookRegistry` is the single source of truth
- Test mocks: centralized in `PalaceTests/Mocks/`, use `TPPBookMocker` for book factories
- Test HTTP stubbing: `HTTPStubURLProtocol` + `URLSession.stubbedSession()`

## pbxproj

Two build phases (two targets) — new source files need entries in both Sources sections.

## Secrets

Never commit: `APIKeys.swift`, `GoogleService-Info.plist`, `TPPSecrets.swift`, `.env` files.
