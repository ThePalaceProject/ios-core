# Module A — AppContainer audiobook wiring

**Status:** REFINED post-triage.

## Scope summary

Add two cached factory accessors to `AppContainer.swift` — `audiobookSession` and
`playbackBootstrapper` — that mirror the existing `bookCellModelCache` /
`samplePreviewManager` pattern (lines 30–53 of `AppContainer.swift`).

**No per-account caching.** Architect triage (D1) verified that PR #967 did NOT
establish a per-account factory pattern on AppContainer; it established
per-account *cache-keying inside CatalogRepository* and *per-account directory
injection* on MyBooksDownloadCenter — both are consumer-side patterns, not
AppContainer-side caching. AudiobookSessionManager already reads
`accountsManager.currentAccount` internally on every operation, so a single
shared instance (cached statically, like `_bookCellModelCache`) is the correct
shape.

## In-scope files (exclusive write)

- MOD `Palace/AppInfrastructure/AppContainer.swift` — add 2 cache cells + 2
  computed properties (≤60 LOC added)
- NEW `PalaceTests/AppInfrastructure/AppContainerAudiobookFactoryTests.swift` —
  3 tests (caching + production-stack construction)

## Out-of-scope (read-only)

- `Palace/Audiobooks/AudiobookSessionManager.swift` (Module B — Module A
  consumes the existing `init(appContainer:)` convenience at line 212)
- `Palace/Audiobooks/PlaybackBootstrapper.swift` (Module B)
- All `.shared` call sites (Module B)
- The existing `bookCellModelCache` + `samplePreviewManager` code in
  AppContainer — pattern is mirrored, not modified

## Locked API surface

Add to `AppContainer.swift` immediately after the `samplePreviewManager` block
(around line 53):

```swift
@MainActor
var audiobookSession: AudiobookSessionManaging {
    if let cached = AppContainer._audiobookSession { return cached }
    let session = AudiobookSessionManager(appContainer: self)
    AppContainer._audiobookSession = session
    return session
}

@MainActor
var playbackBootstrapper: PlaybackBootstrapper {
    if let cached = AppContainer._playbackBootstrapper { return cached }
    let bootstrapper = PlaybackBootstrapper(
        appContainer: self,
        audiobookSessionProvider: { [self] in self.audiobookSession }
    )
    AppContainer._playbackBootstrapper = bootstrapper
    return bootstrapper
}

@MainActor private static var _audiobookSession: AudiobookSessionManager?
@MainActor private static var _playbackBootstrapper: PlaybackBootstrapper?
```

**Self-capture note:** the `playbackBootstrapper` closure captures `self` (the
AppContainer struct) — a value-copy capture, which is safe because
`production()` returns the same `_cached` struct on every call. The closure
resolves the session lazily, which matches PlaybackBootstrapper's existing
comment at lines 64–70 about init-order race.

**Stored-type vs return-type:** The cache stores
`AudiobookSessionManager` (concrete class — so the `_audiobookSession?`
optional re-resolution is type-correct). The accessor returns
`AudiobookSessionManaging` (protocol), so callers can't reach concrete
internals. The protocol conformance is declared in
`AudiobookSessionManaging.swift:92`.

## Locked tests (3 tests, replaces contract's 4)

```swift
import XCTest
@testable import Palace

final class AppContainerAudiobookFactoryTests: XCTestCase {

    @MainActor
    func testAudiobookSession_returnsSameInstanceAcrossReads() {
        let c = AppContainer.production()
        let a = c.audiobookSession
        let b = c.audiobookSession
        // Identity check via protocol — both reads resolve to the same cached cell.
        XCTAssertTrue((a as AnyObject) === (b as AnyObject),
                      "audiobookSession must return the cached instance on repeated reads")
    }

    @MainActor
    func testPlaybackBootstrapper_returnsSameInstanceAcrossReads() {
        let c = AppContainer.production()
        let a = c.playbackBootstrapper
        let b = c.playbackBootstrapper
        XCTAssertTrue(a === b,
                      "playbackBootstrapper must return the cached instance on repeated reads")
    }

    @MainActor
    func testPlaybackBootstrapper_audiobookSessionProvider_resolvesToAppContainerCache() {
        // Verifies the bootstrapper's provider closure routes through
        // AppContainer's audiobookSession cache — NOT a fresh instance. If
        // this fails, the bootstrapper is constructing a parallel session
        // and CarPlay commands won't reach the phone-side instance.
        let c = AppContainer.production()
        let sessionViaContainer = c.audiobookSession
        let bootstrapper = c.playbackBootstrapper
        // Reflect the provider closure via the existing protocol-level
        // `hasActiveManager` flag — flipping it on the container's instance
        // must be visible through the bootstrapper's resolved session.
        // (If we can't reflect without a protocol break, the test reads
        // both instance addresses through `Unmanaged.passUnretained`.)
        // Simpler: identity comparison via reflection in the
        // PlaybackBootstrapper's `audiobookSessionProvider` closure result.
        XCTAssertTrue(
            (sessionViaContainer as AnyObject) === (bootstrapper.audiobookSessionProvider() as AnyObject),
            "playbackBootstrapper.audiobookSessionProvider must resolve to AppContainer.audiobookSession"
        )
    }
}
```

**Test-visibility note:** `PlaybackBootstrapper.audiobookSessionProvider` is
currently `private` (line 70). Module A may need to relax to `internal` for
the third test — OR replace the third test with a runtime-behavior assertion
(send an event through the bootstrapper and observe it arrive via the
container's `audiobookSession.errorPublisher` subscriber). Architect leaves
the decision to Module A's implementer; the spirit is "verify the wiring."

## Add to pbxproj

```bash
ruby scripts/pbxproj_add_swift.rb --targets PalaceTests \
    PalaceTests/AppInfrastructure/AppContainerAudiobookFactoryTests.swift
```

(Test files auto-route to PalaceTests target.)

## Acceptance criteria

- 2 cache cells + 2 computed properties added to AppContainer.swift, total ≤60 LOC
- 3 tests in `AppContainerAudiobookFactoryTests.swift`
- Existing AppContainer tests (none currently — `AppContainer.swift` has no
  test file in this branch; verify via
  `find PalaceTests -name "AppContainer*Tests*.swift"`) continue to pass
- No `static let shared` reads inside the new factory bodies — the closure on
  `playbackBootstrapper` calls `self.audiobookSession` (the cache), not
  `AudiobookSessionManager.shared` (which Module B is about to delete)
- `xcodebuild build` succeeds for Palace + Palace-noDRM

## Implementer prompt

You are Module A implementer for `swarm_03acb10a`. Add per-instance audiobook
session + bootstrapper factories to `Palace/AppInfrastructure/AppContainer.swift`.

PRE-WORK:
1. Write transcript skeleton FIRST at
   `.forgeos/swarms/swarm_03acb10a/transcripts/A-AppContainerWiring.md` with
   5 section headings (Read steps / API added / Tests written / Validation /
   Hand-off to B+C).
2. Read this contract + the architect's `transcripts/triage.md`.
3. Read AppContainer.swift fully — note the `_bookCellModelCache` pattern at
   lines 30–53 (you're mirroring it).
4. Read AudiobookSessionManager.swift line 212 (existing `init(appContainer:)`
   convenience) and PlaybackBootstrapper.swift line 101 (existing
   `init(appContainer:audiobookSessionProvider:)` convenience). You're CALLING
   these — not modifying them.

**You are NOT touching:**
- AudiobookSessionManager.swift
- PlaybackBootstrapper.swift
- The 3 `.shared` call sites (Module B)
- Any test file other than the new one you're creating

**You ARE touching:**
- AppContainer.swift — add 2 cache cells + 2 computed properties
- Create `PalaceTests/AppInfrastructure/AppContainerAudiobookFactoryTests.swift`
  with 3 tests
- Add the test file to pbxproj via `pbxproj_add_swift.rb`

Validate: `xcodebuild build` + run the new test class. Both succeed.

Write the full transcript at the end with concrete API shapes locked for
Modules B and C. Do NOT commit, do NOT push, do NOT dispatch other agents.
