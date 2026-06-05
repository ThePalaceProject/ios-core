---
name: PP-4340-readium-3.9.0
created: 2026-06-05
author: claude-opus-4-8
ticket: PP-4340
---

## Summary

Upgrade Readium swift-toolkit from 3.7.0 to 3.9.0 in `ios-core` and the
`ios-audiobooktoolkit` submodule (which links `ReadiumShared` directly and
must move in lockstep). Apply the 3.8.0 + 3.9.0 breaking-change migrations:
JSONValue type-safe JSON, EPUB + PDF navigators no longer require an HTTP
server (remove `ReadiumAdapterGCDWebServer` / `GCDHTTPServer` entirely), and
migrate LCP license/passphrase storage from the deprecated
`ReadiumAdapterLCPSQLite` repositories to the built-in Keychain repositories
with a one-time SQLite→Keychain data migration for existing users.

User decisions (2026-06-05): migrate LCP to Keychain **now** (with data
migration); bump + migrate the **submodule** in this same pass.

## Claims

### SPM version pins
- bumps `swift-toolkit` from `exactVersion 3.7.0` → `3.9.0` in
  `Palace.xcodeproj/project.pbxproj` and updates `Package.resolved`
- bumps `swift-toolkit` from `exactVersion 3.7.0` → `3.9.0` in
  `ios-audiobooktoolkit/PalaceAudiobookToolkit.xcodeproj/project.pbxproj`
- updates the submodule pointer in `ios-core` to the migrated submodule commit

### JSONValue migration (3.9.0)
- `Palace/Reader2/Bookmarks/TPPBookLocation+Locator.swift`: replaces the two
  `serializeJSONString(dict)` calls (removed free function) with Foundation
  `JSONSerialization` serialization of the `[String: Any]` dict; reads
  `otherLocations[...]?.string` and constructs `Locator.Locations(otherLocations:)`
  with `[String: JSONValue]` (was `[String: Any]`)
- `Palace/Reader2/BusinessLogic/TPPLastReadPositionPoster.swift`: changes
  `locator.jsonString` (property) → `try? locator.jsonString()` (throwing method)
- `Palace/Reader2/Internal/Publication+NYPLAdditions.swift`: `link.properties["id"]`
  is now `JSONValue?` → read via `?.string`
- `ios-audiobooktoolkit/.../Player/RangeResource.swift` +
  `Palace/Reader2/ReaderStackConfiguration/AdobeDRM/AdobeDRMContentProtection.swift`:
  `ResourceProperties` subscript now requires `JSONValueEncodable & JSONValueDecodable`;
  `UInt64` is encode-only, so length is stored as `Int` and bridged to `UInt64`

Note: the EPUB/PDF `httpServer:` inits and the LCP SQLite repos are **deprecations**
in 3.9.0 (old APIs still compile), not hard removals — the project builds with
warnings before migration. `ReadiumAdapterLCPSQLite` is **kept** in the project
because the one-time migrator must read the legacy store; its removal is deferred to
a follow-up once migration adoption is complete (the single remaining, intentional,
self-documented deprecation warning).

### EPUB HTTP-server removal (3.8.0)
- drops the `httpServer:` argument from the `EPUBNavigatorViewController(...)`
  init in `Palace/Reader2/UI/TPPEPUBViewController.swift`
- unwinds the `resourcesServer: HTTPServer` plumbing through
  `TPPEPUBViewController.init`, `TPPR3Owner` (`ReaderModule(resourcesServer:)`),
  and the `ReaderModule`/format-module chain

### PDF HTTP-server removal (3.9.0)
- drops the `httpServer:` argument from the `PDFNavigatorViewController(...)`
  init in `Palace/PDF/ReadiumPDF/ReadiumPDFViewController.swift`
- unwinds the `httpServer` plumbing through `ReadiumPDFViewController`,
  `ReadiumPDFContainer`, `ReadiumPDFReaderView`,
  `Palace/AppInfrastructure/NavigationHostView.swift`, and
  `ReaderService.httpServer`

### GCDWebServer removal
- removes `GCDHTTPServer` creation/`serve`/`remove`/`releaseServedPublication`
  from `Palace/Reader2/ReaderStackConfiguration/LibraryService.swift`
- removes `import ReadiumAdapterGCDWebServer` from all sites
- removes the `ReadiumAdapterGCDWebServer` SPM product link from
  `Palace.xcodeproj/project.pbxproj` (both targets)
- removes the orphan Carthage `GCDWebServer.{framework,xcframework}` and
  `ReadiumLCP.{framework,xcframework}` PBXGroup file references (dead refs)

### LCP SQLite→Keychain migration (3.8.0)
- `Palace/Reader2/ReaderStackConfiguration/LCP/LCPLibraryService.swift`:
  swaps `LCPSQLiteLicenseRepository`/`LCPSQLitePassphraseRepository` for
  `LCPKeychainLicenseRepository`/`LCPKeychainPassphraseRepository`; the new
  repos are non-throwing
- adds a one-time SQLite→Keychain data migration (gated, runs once) under
  `Palace/Migrations/` so existing users' stored LCP licenses/passphrases
  carry over; removes `import ReadiumAdapterLCPSQLite` once migration is the
  only remaining SQLite consumer
- removes the `ReadiumAdapterLCPSQLite` SPM product link after migration is
  wired (kept only if the one-time migrator still imports it; tracked)

### Submodule ReadiumShared API migration
- applies whatever `ReadiumShared` API drift surfaces at build in
  `ios-audiobooktoolkit` (Resource/streaming APIs in `RangeResource`,
  `StreamingResourceProvider`, `LCPStreamingPlayer`, `HTTPRangeRetriever`,
  `LCPResourceLoaderDelegate`, `Audiobook`); submodule JSON code is plain
  Foundation `JSONSerialization` and is expected to be unaffected

## Anti-claims
- does NOT change the LCP-PDF disk-extract architecture or the
  decrypt/OOM-guard logic in `ReaderService.openPDF` (only removes the now-unused
  `httpServer` plumbing around it)
- does NOT change EPUB/PDF reading-position persistence wire format
  (`TPPBookLocation` JSON shape is preserved byte-for-byte)
- does NOT change audiobook playback logic beyond ReadiumShared API renames
- does NOT alter sign-in/borrow/return/download flows
- does NOT change the LCP passphrase-authentication UX

## Files in scope
- `Palace.xcodeproj/project.pbxproj`
- `Palace.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
- `Palace/Reader2/Bookmarks/TPPBookLocation+Locator.swift`
- `Palace/Reader2/BusinessLogic/TPPLastReadPositionPoster.swift`
- `Palace/Reader2/UI/TPPEPUBViewController.swift`
- `Palace/Reader2/ReaderStackConfiguration/TPPR3Owner.swift`
- `Palace/Reader2/ReaderStackConfiguration/LibraryService.swift`
- `Palace/Reader2/ReaderStackConfiguration/LCP/LCPLibraryService.swift`
- `Palace/Reader2/.../ReaderModule` + EPUB format module (resourcesServer plumbing)
- `Palace/PDF/ReadiumPDF/ReadiumPDFViewController.swift`
- `Palace/PDF/ReadiumPDF/ReadiumPDFReaderView.swift`
- `Palace/AppInfrastructure/ReaderService.swift`
- `Palace/AppInfrastructure/NavigationHostView.swift`
- `Palace/Migrations/` (new one-time LCP SQLite→Keychain migrator)
- `ios-audiobooktoolkit/PalaceAudiobookToolkit.xcodeproj/project.pbxproj`
- `ios-audiobooktoolkit/PalaceAudiobookToolkit/...` (ReadiumShared API drift)
- test files under `PalaceTests/` for JSON round-trip + LCP migration

## Verification plan
- submodule builds standalone at 3.9.0
- `xcodebuild ... build` clean for Palace + Palace-noDRM
- `scripts/verify-pr.sh --quick`
- simdrive smoke (AC): EPUB paginated + scroll, PDF, LCP-protected PDF,
  audiobook, EPUB search, PDF search, EPUB TTS, rotation-preserves-preferences
- no new deprecation warnings (LCP SQLite deprecation resolved by Keychain swap)
