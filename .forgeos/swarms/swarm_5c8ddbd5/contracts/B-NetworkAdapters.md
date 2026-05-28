---
name: swarm_5c8ddbd5-contract-B-NetworkAdapters
type: immutable
status: active
created: 2026-05-21
last_refresh: 2026-05-21
freshness_window: never
owners: [network]
description: Module B — OpenAccess + BearerToken + LocalFile adapters
---

# Module B — OpenAccess + BearerToken + LocalFile adapters

## In-scope files (exclusive write)
- NEW `Palace/Audiobooks/Vendors/OpenAccessAdapter.swift`
- NEW `Palace/Audiobooks/Vendors/BearerTokenAdapter.swift`
- NEW `Palace/Audiobooks/Vendors/LocalFileAdapter.swift`
- NEW `PalaceTests/Audiobook/Vendors/OpenAccessAdapterTests.swift`
- NEW `PalaceTests/Audiobook/Vendors/BearerTokenAdapterTests.swift`
- NEW `PalaceTests/Audiobook/Vendors/LocalFileAdapterTests.swift`

## Out-of-scope (read-only)
- `Palace/Audiobooks/AudiobookLoader.swift` (Module D's territory)
- `Palace/Audiobooks/LCP/*` (Module C's territory)
- `Palace/Audiobooks/AudioBookVendors+Extensions.swift` (untouched in this swarm)
- All files in the swarm-wide don't-touch list

## Public types exposed
```swift
final class OpenAccessAdapter: AudiobookVendorAdapter { ... }
final class BearerTokenAdapter: AudiobookVendorAdapter { ... }
final class LocalFileAdapter: AudiobookVendorAdapter { ... }
```

Each adapter is initialized with the collaborators it needs (network executor, download center, FileManager) so tests can inject mocks instead of touching `AppContainer.production()`. **Constructor-style DI per CLAUDE.md** — no `.shared` reads from inside adapters.

## Types consumed (from Module A)
- `AudiobookVendorAdapter` protocol

## Behavior carve-out (preserve exactly)

- **LocalFileAdapter** wraps the lines 169-207 path of pre-swarm `AudiobookLoader.swift`:
  - reads `AppContainer.production().downloadCenter.fileUrl(for: book.identifier)`
  - parses as JSON
  - optionally refreshes bearer token via `MyBooksSimplifiedBearerToken` if `book.bearerTokenFulfillURL` is set
  - succeeds with `(json, nil)`

- **OpenAccessAdapter** wraps lines 346-396 *minus* the bearer-token-detection branch:
  - fetches `book.defaultAcquisition.hrefURL`
  - parses as JSON
  - succeeds with `(json, nil)`

- **BearerTokenAdapter** handles the recursion: if `OpenAccessAdapter`'s fetched JSON looks like a bearer token wrapper (`MyBooksSimplifiedBearerToken.simplifiedBearerToken(with: json)` is non-nil):
  - set `book.bearerToken` / `book.bearerTokenFulfillURL`
  - call `BookService.fetchManifestWithBearerToken(...)` for the real manifest

## Tests owned (named cases)

**OpenAccessAdapterTests**
- `testCanHandle_anyOPDSBook_returnsTrueAsFallback`
- `testResolveManifest_successPath_completesWithJSON`
- `testResolveManifest_networkError_failsWithManifestFetchFailed`
- `testResolveManifest_emptyData_failsWithManifestFetchFailed`
- `testResolveManifest_htmlResponse_failsWithManifestFetchFailed`
- `testResolveManifest_invalidJSON_failsWithManifestParseFailed`

**BearerTokenAdapterTests**
- `testResolveManifest_detectsBearerTokenInResponse_recursesToLocationURL`
- `testResolveManifest_bearerTokenFetchSuccess_completesWithRealManifest`
- `testResolveManifest_bearerTokenFetchFails_failsWithManifestFetchFailed`
- `testResolveManifest_setsBookBearerTokenSideEffect` (verifies TPPBook mutation)

**LocalFileAdapterTests**
- `testCanHandle_localFileExists_returnsTrue`
- `testCanHandle_noLocalFile_returnsFalse`
- `testResolveManifest_validJSON_succeeds`
- `testResolveManifest_unreadableFile_failsWithManifestParseFailed`
- `testResolveManifest_bearerTokenFulfillURL_refreshesTokenBeforeReturn`
- `testResolveManifest_noBearerTokenFulfillURL_skipsRefresh`

Each adapter test class injects mock collaborators via constructor — **zero `AppContainer.production()` reads, zero real network, zero real disk**.

## Acceptance criteria
- Each adapter file <=200 LOC
- 100% mutation kill rate on `canHandle` and `resolveManifest` per `palace_mutate.py --diff-only`
- No behavior drift vs lines 169-207 and 346-396 of pre-swarm `AudiobookLoader.swift` (D's tests verify end-to-end behavior preservation; B's tests verify the adapters in isolation)

## Implementer prompt

You are Module B implementer for swarm_5c8ddbd5. Three adapter files, three test classes. Each adapter is a class that takes its collaborators through the constructor — never read `AppContainer.production()` from inside an adapter. The loader's existing logic at lines 169-207 (local file) and 346-396 (open-access network + bearer token detection) is the canonical behavior; move it **verbatim** into the three adapters with no semantic change.

Mutation tests must pass at 100% on the carve-outs — look at `AudiobookLoaderPredicateTests.swift` for the existing pattern.

Use `scripts/pbxproj_add_swift.rb` to add all six files to `Palace.xcodeproj` (both targets).

Validate: `xcodebuild -project Palace.xcodeproj -scheme Palace -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build` succeeds; `xcodebuild ... test -only-testing:PalaceTests/{OpenAccess,BearerToken,LocalFile}AdapterTests` passes.

When done, write `.forgeos/swarms/swarm_5c8ddbd5/transcripts/B-NetworkAdapters.md` with: files added (the 6), tests added (the 16 test names with brief descriptions), key decisions, any gaps for the integrator.

Do NOT commit. Do NOT push. Stage for the integrator.
