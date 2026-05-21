# Contract: ImageLoading-Consolidation (swarm_d5a3d473, Track A)

**Sequence:** Parallel with Logging-TestSeams. File scopes are disjoint.
**Estimated LOC:** ~220 production + ~180 test (new `ImageLoading` protocol + AppContainer wiring + 28 call-site rewrites + new injection-seam tests).
**Phase 0 note:** You'll run in an implementer worktree off the orchestrator's `swarm/swarm_d5a3d473-scaffold` branch per the new `/swarm` skill discipline. Branch back as `swarm/swarm_d5a3d473-impl-imageloading` or similar; the orchestrator integrates.

## Goal

Three overlapping singletons (`ImageCache.shared`, `TPPBookCoverRegistry.shared`, `TPPBookCoverRegistryBridge.shared`) split the same responsibility — fetching, decoding, caching, and bridging book cover/thumbnail images to Obj-C. Consolidate behind a single `ImageLoading` protocol; wire one implementation through `AppContainer`; replace 28 call sites. Production behavior must be identical (no UI / image-loading regression); existing `MockImageCache` survives unchanged.

## Read FIRST

1. `Palace/Utilities/ImageCache/ImageCacheType.swift` — current `ImageCacheType` protocol (the seed for the new umbrella)
2. `Palace/Book/Models/TPPBookCoverRegistry.swift` — actor + Obj-C bridge in one file (~575 LOC)
3. `Palace/AppInfrastructure/AppContainer.swift` — DI composition root pattern (read line 90–150)
4. `PalaceTests/Mocks/MockImageCache.swift` — existing mock that must still compile
5. `Palace/Packages/PalaceCatalog/Sources/PalaceCatalog/CatalogAPI.swift` — reference for SPM-style public-API surface (you are NOT moving anything into a package, but mimic the same `public protocol` + `internal final class` separation)
6. `CLAUDE.md` — TDD discipline, AppContainer-first rule, banned test patterns

## Files in scope (edit)

### Add (new)
- `Palace/Utilities/ImageCache/ImageLoading.swift` — NEW. Single umbrella protocol that captures the union of methods needed by call sites (cover, thumbnail, decoded variant, bridge-style URL fetch, cache get/set/clear).
- `Palace/Utilities/ImageCache/ImageLoaderImpl.swift` — NEW. Concrete `final actor ImageLoader: ImageLoading` that internally holds `imageCache: ImageCacheType` (still the existing `ImageCache` class) AND inlines what `TPPBookCoverRegistry` + `TPPBookCoverRegistryBridge` do today. This is one type, one source of truth.
- `PalaceTests/Mocks/MockImageLoader.swift` — NEW. Conforms to `ImageLoading`; records calls; deterministic returns (no UIKit rendering).
- `PalaceTests/ImageLoading/ImageLoaderTests.swift` — NEW. Unit tests for the unified protocol against `ImageLoader` and against `MockImageLoader`.
- `PalaceTests/AppInfrastructure/AppContainerImageLoaderInjectionTests.swift` — NEW. Integration test exercising the injection seam end-to-end (one `BookListView`-style consumer is handed a `MockImageLoader` via `AppContainer`, and `coverImage(for:)` is observed routing to the mock).

### Edit (call-site rewrite)
- `Palace/AppInfrastructure/AppContainer.swift` — add `let imageLoader: ImageLoading` field; wire `ImageLoader(imageCache: ImageCache.shared)` in `production()`; bump initializer signature.
- `Palace/AppInfrastructure/TPPAppDelegate.swift` — replace `ImageCache.shared.clear()` (line ~709) with `container.imageLoader.clearAll()` reading the container the delegate already holds.
- `Palace/Book/Models/TPPBookCoverRegistry.swift` — keep file (downsampleImage static remains a static utility), but: delete `static let shared` (line 78) and `TPPBookCoverRegistryBridge` class (lines 487-575). Move the public surface into `ImageLoader`. If easier, mark the actor `@available(*, deprecated, message: "Use ImageLoading through AppContainer")` and reroute its public methods to call into `ImageLoader`; or simply delete it and inline the logic — implementer picks the smaller diff.
- `Palace/Book/Models/TPPBook+Presentation.swift` — replace 4 sites:
  - `static let coverRegistry = TPPBookCoverRegistry.shared` → delete (replaced by injected `imageLoader` on TPPBook)
  - `await TPPBookCoverRegistry.shared.coverImage(...)` → `await self.imageLoader.coverImage(for: self, displayPoints: displayHeight)`
  - `TPPBookCoverRegistryBridge.shared.coverImageForBook(...)` → `self.imageLoader.coverImage(for: self) { image in ... }` (new completion-style overload on `ImageLoading`)
  - `TPPBookCoverRegistryBridge.shared.thumbnailImageForBook(...)` → `self.imageLoader.thumbnailImage(for: self) { image in ... }`
  - TPPBook already holds `imageCache: ImageCacheType`; expand to either (a) hold both `imageCache` AND `imageLoader: ImageLoading`, or (b) replace `imageCache` with `imageLoader` (preferred — `ImageLoading` re-exports the cache surface). Implementer picks (b) IF Obj-C bridging tolerates it; otherwise (a).
- `Palace/Book/Models/TPPBookRegistry.swift` — replace 7 sites (lines 115, 387, 423, 444, 516, 527, 539). The 6 bridge sites become `imageLoader.thumbnailImage(for: book) { _ in }` or `imageLoader.coverImage(for: book, completion: handler)`. Line 115 (`private var coverRegistry = TPPBookCoverRegistry.shared`) becomes an injected `let imageLoader: ImageLoading` set in TPPBookRegistry's init.
- `Palace/Book/Models/TPPBook.swift` — replace 2 sites (lines 230, 335). These pass `imageCache: ImageCache.shared` to TPPBook.init. If TPPBook adopts (b) above, change to `imageLoader: ImageLoader.shared` (a singleton-shaped accessor on the new ImageLoader for legacy Obj-C `TPPBook(dictionary:)` paths that can't reach the container) — OR keep TPPBook's `imageCache` field for legacy Obj-C compat and DON'T migrate these two sites in this swarm. Implementer picks; document in the PR.
- `Palace/CarPlay/CarPlayImageProvider.swift` (line 31) — `init(imageCache: ImageCacheType = ImageCache.shared)` → `init(imageLoader: ImageLoading = ImageLoader.production)`.
- `Palace/Settings/Debug/DebugSettings.swift` (lines 324, 371) — both are test-book TPPBook factories. Update to whatever TPPBook ends up accepting.
- `Palace/OPDS2/Models/OPDS2PublicationExtended.swift` (lines 330, 459) — same as above; TPPBook factory call-sites.
- `Palace/MyBooks/MyBooks/BookListView.swift` (line 105) — `await TPPBookCoverRegistry.shared.thumbnailImage(for: book)` → use `@Environment(\.appContainer)` to read `container.imageLoader.thumbnailImage(for: book)`. Mirrors the existing AppContainer-Environment pattern (see `AppContainer.swift` line 155).

## Files OFF-LIMITS (do NOT edit)

Verbatim copy of the swarm_81b5099e frozen set + concurrent PR set:

**swarm_81b5099e frozen (concurrent swarm):**
- `Palace/Accounts/Library/` (entire dir, including `AccountsManager.swift` — which has 4 `ImageCache.shared` refs; we defer those)
- `Palace/SignInLogic/TPPSignInBusinessLogic.swift` lines 281, 309, 732, 736, 753, 781
- `Palace/SignInLogic/TPPSignInBusinessLogic+BookmarkSyncing.swift`
- `Palace/SignInLogic/TPPSignInBusinessLogic+CardCreation.swift:17`
- `Palace/Accounts/User/TPPUserAccount.swift:99,102`
- `Palace/Accounts/AgeCheck/TPPAgeCheck.swift`
- `Palace/Notifications/NotificationService.swift`

**PR #956 collision (test capability uplift, in flight — touches these files):**
- `Palace/Audiobooks/AudiobookSessionManager.swift` (has 2 `TPPBookCoverRegistry.shared` refs — defer to follow-up swarm)
- `Palace/Settings/DeveloperSettings/TPPDeveloperSettingsTableViewController.swift` (has 1 `ImageCache.shared.clear()` ref + Track B refs — defer)
- `PalaceTests/Audiobooks/AudiobookSessionManagerShutdownTests.swift`
- All other files in PR #956: re-check with `gh pr view 956 --repo ThePalaceProject/ios-core --json files --jq '.files[].path'` before editing anything in `PalaceTests/Audiobooks/`, `PalaceTests/Contract/`, `PalaceTests/Integration/`, `PalaceTests/DRM/`, `PalaceTests/CatalogDomain/`, `PalaceTests/CatalogUI/`, `Palace/Packages/PalaceCatalog/`, `Palace/Packages/PalaceNetwork/`, `Palace/Network/`, `Palace/Reader2/Bookmarks/`, `Palace/MyBooks/MyBooks/BookCell/`, `Palace/MyBooks/MyBooksDownloadCenter.swift`, `Palace/MyBooks/BookFileManager.swift`, `Palace/AppInfrastructure/AppTabHostView.swift`, `Palace/AppInfrastructure/ReaderService.swift`, `Palace/Audiobooks/AudioBookVendors+Extensions.swift`, `Palace/Audiobooks/AudiobookLoader.swift`, `Palace/Book/UI/BookDetail/`.

**PR #963 collision (Bucket A migration, in flight):**
- All paths from `gh pr view 963 --repo ThePalaceProject/ios-core --json files`: AgeCheck, AudiobookSessionManager, BookRegistrySync, TPPBookRegistryAsync, CarPlayAudiobookBridge, CarPlayTemplateManager, NotificationService, OPDSFeedService, UnifiedOPDSService, TPPReaderBookmarksBusinessLogic, LCPPassphraseAuthenticationService, TPPSignInBusinessLogic*.

If your in-scope edit list above touches any file on this combined off-limits list, STOP and re-triage — escalate to architect.

## Public-API surface delta

```swift
// NEW: Palace/Utilities/ImageCache/ImageLoading.swift

import UIKit

public protocol ImageLoading {
    // Cover / thumbnail (replaces TPPBookCoverRegistry actor methods)
    func coverImage(for book: TPPBook) async -> UIImage?
    func coverImage(for book: TPPBook, displayPoints: CGFloat) async -> UIImage?
    func thumbnailImage(for book: TPPBook) async -> UIImage?
    func playerCoverImage(for book: TPPBook) async -> UIImage?

    // Obj-C bridge surface (replaces TPPBookCoverRegistryBridge)
    func coverImage(for book: TPPBook, completion: @escaping (UIImage?) -> Void)
    func thumbnailImage(for book: TPPBook, completion: @escaping (UIImage?) -> Void)

    // Cache surface (replaces ImageCacheType — keep all methods so existing
    // call sites and MockImageCache continue to compile via a thin adapter)
    func get(for key: String) -> UIImage?
    func getAsync(for key: String) async -> UIImage?
    func set(_ image: UIImage, for key: String, expiresIn: TimeInterval?)
    func remove(for key: String)
    func clearAll()           // renamed from `clear()` for clarity at top-level API
    func evictDecodedImages()
    func warmMemoryCache(for keys: [String]) async
}

public extension ImageLoading {
    func set(_ image: UIImage, for key: String) {
        let sevenDays: TimeInterval = 7 * 24 * 60 * 60
        set(image, for: key, expiresIn: sevenDays)
    }
}
```

`ImageLoader` (the concrete `final actor`) holds an `ImageCacheType` internally (the existing `ImageCache` class continues to exist as the byte/JPEG-on-disk layer — we are NOT rewriting it). The Obj-C bridge methods are inlined off the actor (free functions or a small `@objc` adapter class behind the protocol), preserving the weak-book-reference safety pattern from `TPPBookCoverRegistryBridge`.

`MockImageCache` (the existing `ImageCacheType` mock) keeps its conformance to `ImageCacheType` (the underlying disk-layer protocol stays). A new `MockImageLoader` conforms to `ImageLoading` and is what new tests use; call-site changes still typecheck through both.

## AppContainer wiring

```swift
// AppContainer.swift — add field + initializer arg + production() construction.
let imageLoader: ImageLoading

// production():
let imageCache = ImageCache.shared            // disk + memory layer stays
let imageLoader = ImageLoader(imageCache: imageCache)

return AppContainer(
    // ... existing args ...
    imageCache: imageCache,                   // KEEP for now (legacy consumers)
    imageLoader: imageLoader,                 // NEW
    // ...
)
```

We keep `imageCache: ImageCacheType` on `AppContainer` for backward-compat during this swarm (CarPlayImageProvider, OPDS2PublicationExtended, etc., all read `container.imageCache`). After the contract closes and the call sites are migrated to `container.imageLoader`, a follow-up swarm can remove the redundant field.

`ImageLoader.production` is a static accessor (NOT a fresh `.shared` — it reads `AppContainer.production().imageLoader` so we don't reintroduce the duplicate-graph problem). Used ONLY as a default-arg for legacy Obj-C-reachable init signatures (TPPBook factories) where threading the container through is impractical. Annotate with `@available(*, deprecated, message: "Inject ImageLoading through AppContainer")` so call sites get a warning at every use.

## Migration table (28 sites)

| File | Site count | Strategy |
|---|---|---|
| `Palace/Book/Models/TPPBookCoverRegistry.swift` | 10 | Delete `TPPBookCoverRegistryBridge` class, delete `static let shared`. The `TPPBookCoverRegistry` actor logic moves into `ImageLoader`. |
| `Palace/Book/Models/TPPBookRegistry.swift` | 7 | Inject `let imageLoader: ImageLoading` via init; replace `.shared` reads. |
| `Palace/Book/Models/TPPBook+Presentation.swift` | 4 | Read `self.imageLoader` (added field on TPPBook). |
| `Palace/Book/Models/TPPBook.swift` | 2 | TPPBook gains `imageLoader: ImageLoading`; factory inits pass `ImageLoader.production` (deprecated default). |
| `Palace/AppInfrastructure/AppContainer.swift` | 1 | Add `imageLoader` field; wire production. |
| `Palace/AppInfrastructure/TPPAppDelegate.swift` | 1 | `container.imageLoader.clearAll()`. |
| `Palace/CarPlay/CarPlayImageProvider.swift` | 1 | `init(imageLoader: ImageLoading = ImageLoader.production)`. |
| `Palace/Settings/Debug/DebugSettings.swift` | 2 | Pass `imageLoader` to TPPBook factory. |
| `Palace/OPDS2/Models/OPDS2PublicationExtended.swift` | 2 | Pass `imageLoader` to TPPBook factory. |
| `Palace/MyBooks/MyBooks/BookListView.swift` | 1 | Read `@Environment(\.appContainer)` → `container.imageLoader.thumbnailImage(for:)`. |

## Tests required (TDD — write FIRST)

Add `PalaceTests/ImageLoading/ImageLoaderTests.swift`:

1. **`testCoverImage_cacheHit_returnsCachedImageWithoutNetwork`** — preload `imageCache`, assert no URL fetch.
2. **`testCoverImage_cacheMiss_downsamplesAndStores`** — stub URLSession via `HTTPStubURLProtocol`, assert decoded UIImage returned + `imageCache.set` recorded.
3. **`testCoverImage_decodingFails_logsAndReturnsNil`** — feed malformed bytes, assert returns nil and TPPErrorLogger.logImageDecodeFail recorded (use a mock TPPErrorLogger or inject a closure).
4. **`testThumbnailImage_falsBackToPlaceholder_whenURLNil`** — assert TenPrint placeholder returned for book with no thumbnailURL.
5. **`testHostCircuitBreaker_trips_skipsSubsequentRequests`** — feed two consecutive `NSURLErrorCannotFindHost` errors, assert third request short-circuits without URLSession call.
6. **`testCoverImage_displayPoints_clampsAtMaxDimension`** — assert decoded image dimension ≤ `maxDecodeDimension` regardless of input.
7. **`testPlayerCoverImage_usesScreenWidth_notDeviceMemoryCap`** — assert decode dimension uses screen-pixel limit, not memory-tier limit.
8. **`testCompletionBridge_thumbnail_invokesOnMainThread`** — call `thumbnailImage(for:completion:)`, assert callback runs on `Thread.isMainThread`.
9. **`testCompletionBridge_book_deallocatedDuringFetch_noCrash`** — repro the EXC_BAD_ACCESS pattern the bridge guarded against.

Add `PalaceTests/AppInfrastructure/AppContainerImageLoaderInjectionTests.swift`:

10. **`testContainer_injectsImageLoader_intoBookListView`** — construct an `AppContainer` with a `MockImageLoader`, route through SwiftUI Environment, observe a thumbnail call on the mock.
11. **`testContainer_clearAll_callsThroughToImageLoader`** — wire mock, call `container.imageLoader.clearAll()`, assert mock recorded the clear.

Add `PalaceTests/Mocks/MockImageLoader.swift` (mock; not a test file but lives in Mocks/):
- Conforms to `ImageLoading`; deterministic returns; per-method call records (`coverCalls`, `thumbnailCalls`, `clearCount`).

Existing `PalaceTests/TPPBookCoverRegistryTests.swift` keeps working IF `TPPBookCoverRegistry.downsampleImage` static + `TPPBookCoverRegistry.imageSession` static stay reachable (they're not the singleton; they're plain `static`/`nonisolated static` utilities). Either:
- Keep the `TPPBookCoverRegistry` actor as a `nonisolated public enum TPPBookCoverRegistry { … }` host for the static utilities, or
- Migrate `downsampleImage` + `imageSession` into `ImageLoader` and rewrite the 7 test assertions in `TPPBookCoverRegistryTests.swift` to point at `ImageLoader`.

Implementer picks; document choice in PR description.

## Mutation gate

**Warn-only** for this contract. `Palace/Utilities/ImageCache/` and `Palace/Book/Models/TPPBookCoverRegistry.swift` are NOT on the critical-path strict list per `CLAUDE.md` (the strict list is `Palace/Audiobooks/`, `Palace/SignInLogic/`, `Palace/MyBooks/Download*`). Aim for ≥50% kill rate but don't fail the verify gate on it.

Run mutation on `Palace/Utilities/ImageCache/ImageLoaderImpl.swift` + `Palace/Utilities/ImageCache/ImageLoading.swift`:
```bash
python3 scripts/palace_mutate.py \
  --file Palace/Utilities/ImageCache/ImageLoaderImpl.swift \
  --tests PalaceTests/ImageLoading/ImageLoaderTests
```

## pbxproj

Use `ruby scripts/pbxproj_add_swift.rb --targets Palace,Palace-noDRM Palace/Utilities/ImageCache/ImageLoading.swift Palace/Utilities/ImageCache/ImageLoaderImpl.swift` for the two new prod files. Test files: `--targets PalaceTests`.

## Acceptance criteria

- Build green on Palace AND Palace-noDRM.
- All 11 new tests pass.
- All existing PalaceTests pass (no MockImageCache regressions).
- `TPPBookCoverRegistry.shared` and `TPPBookCoverRegistryBridge.shared` are no longer reachable from the in-scope file list (grep returns 0 matches outside the deletion site).
- `ImageCache.shared` references outside the in-scope list (i.e., in `AccountsManager.swift`, `AudiobookSessionManager.swift`, `TPPDeveloperSettingsTableViewController.swift`) are UNCHANGED — those are off-limits.
- `scripts/verify-pr.sh --quick` passes (mutation warns; does not fail).
- LOC delta within budget: ~220 prod + ~180 test.

## Reporting back

Write `.forgeos/swarms/swarm_d5a3d473/transcripts/ImageLoading-Consolidation.md`: summary, files modified, tests added, mutation results (warn-mode), build + test command outputs, any TPPBook factory decisions, and a final `.shared` ref count to confirm we hit the ~28-site target.
