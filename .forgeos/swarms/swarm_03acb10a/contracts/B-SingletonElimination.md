# Module B — Singleton elimination

**Status:** REFINED post-triage.

## Scope summary

Delete two `static let shared` declarations + their parameterless seed
conveniences. Migrate 3 production call sites to
`AppContainer.production().audiobookSession` / `.playbackBootstrapper`.
Touch test files only to keep the build green — Module D follows up to clean
the now-redundant setUp/tearDown bodies.

## In-scope files (exclusive write)

| File | Edit | Lines |
|---|---|---|
| `Palace/Audiobooks/AudiobookSessionManager.swift` | DELETE `static let shared`; DELETE parameterless `private convenience init()` | 87; 197–206 |
| `Palace/Audiobooks/PlaybackBootstrapper.swift` | DELETE `static let shared`; DELETE parameterless `private convenience init()`; drop default closure value on `audiobookSessionProvider` | 56; 90–95; 103 |
| `Palace/AppInfrastructure/TPPAppDelegate.swift` | 1-line edit | 55 |
| `Palace/CarPlay/CarPlaySceneDelegate.swift` | 1-line edit | 43 |
| `Palace/Book/UI/BookDetail/BookService.swift` | 1-line edit | 75 |
| `Palace/Accounts/Library/AccountsManager.swift` | Update doc comment | 307 |
| `PalaceTests/Audiobooks/AudiobookSessionStateTests.swift` | Replace 10 `AudiobookSessionManager.shared` reads with locally-constructed instances | 115, 130, 140, 150, 159, 170, 181, 197, 208, 221 |
| `PalaceTests/Audiobooks/PlaybackBootstrapperTests.swift` | Replace 3 `.shared` reads | 23, 30, 50, 65 |
| `PalaceTests/Audiobooks/AudiobookSessionManagerShutdownTests.swift` | Replace ~5 `.shared` reads | from line 54 onward |
| `PalaceTests/CarPlay/CarPlayTests.swift` | Replace `.shared` reads at line 36 + others (Module D handles setUp body cleanup) | 36 + others |

## Out-of-scope (read-only)

- `Palace/AppInfrastructure/AppContainer.swift` (Module A)
- `PalaceTests/AppInfrastructure/AppContainerAudiobookFactoryTests.swift` (Module A — new file)
- `Palace/Audiobooks/Tracker/AudiobookDataManager.swift` (Module C originally; architect dropped per D5, so no-one touches it)
- `Palace/Audiobooks/NowPlayingCoordinator.swift` (Module C)
- `Palace/Audiobooks/AudiobookLoader.swift` (Swarm 1 territory)
- `PalaceTests/Audiobook/AudiobookReliabilityTests.swift` (Module D will delete the dead-API class)
- All `TPPUserAccountMock.resetShared()` instances (meta-test enforced — do not touch)

## Locked migration steps

### 1. `AudiobookSessionManager.swift`

```diff
-    // MARK: - Singleton
-
-    public static let shared = AudiobookSessionManager()
-
     // MARK: - Published State
```

Drop the parameterless seed convenience:

```diff
-    /// Backwards-compatible convenience for the singleton. Resolves every
-    /// dependency from `.shared` accessors at the moment the singleton is
-    /// first touched. Production code should prefer
-    /// `init(appContainer:)` so the dep graph is explicit.
-    private convenience init() {
-        self.init(
-            bookRegistry: AppContainer.production().bookRegistry,
-            accountsManager: AppContainer.production().accountsManager,
-            settings: AppContainer.production().settings,
-            reachabilityProvider: { AppContainer.production().reachability },
-            bookCoverRegistryProvider: { TPPBookCoverRegistry.shared },
-            navigationCoordinatorHubProvider: { AppContainer.production().navigationCoordinatorHub }
-        )
-    }
-
     /// AppContainer-friendly initializer. Used by future call sites that
```

The designated `init(...)` at line 171 stays `private` (the convenience at 212
calls it; no external caller needs the designated init).

The `convenience init(appContainer:)` at line 212 **stays as-is** — no
modifier changes; it's already accessible (no `private` modifier). This
becomes the only construction path.

### 2. `PlaybackBootstrapper.swift`

```diff
-    // MARK: - Singleton
-
-    public static let shared = PlaybackBootstrapper()
-
     // MARK: - State
```

Drop the parameterless seed convenience:

```diff
-    /// Backwards-compatible convenience for the singleton accessor. Resolves
-    /// every dependency from `.shared` at first touch.
-    private convenience init() {
-        self.init(
-            bookRegistry: AppContainer.production().bookRegistry,
-            audiobookSessionProvider: { AudiobookSessionManager.shared }
-        )
-    }
-
     /// AppContainer-friendly initializer for future call sites that thread
```

Drop the default closure value on the `audiobookSessionProvider:` parameter:

```diff
     convenience init(
         appContainer: AppContainer,
-        audiobookSessionProvider: @escaping () -> AudiobookSessionManaging = { AudiobookSessionManager.shared }
+        audiobookSessionProvider: @escaping () -> AudiobookSessionManaging
     ) {
```

Module A's factory supplies the closure; tests construct with an explicit mock provider.

The designated `init(bookRegistry:audiobookSessionProvider:)` at line 75 keeps
its current `private` modifier — only the `convenience init(appContainer:...)`
needs to be accessible to AppContainer (it is — no `private`).

### 3. `TPPAppDelegate.swift:55`

```diff
-        PlaybackBootstrapper.shared.ensureInitialized()
+        AppContainer.production().playbackBootstrapper.ensureInitialized()
```

### 4. `CarPlaySceneDelegate.swift:43`

```diff
-        PlaybackBootstrapper.shared.ensureInitializedForCarPlay()
+        AppContainer.production().playbackBootstrapper.ensureInitializedForCarPlay()
```

### 5. `BookService.swift:75`

```diff
-                _ = await AudiobookSessionManager.shared.openAudiobook(book, startPlaying: true)
+                _ = await AppContainer.production().audiobookSession.openAudiobook(book, startPlaying: true)
```

`BookService.openBook` is a `static func` (architect D4 verified) — no
`self.appContainer` path; `AppContainer.production()` direct read is correct.

### 6. `AccountsManager.swift:307` (doc-comment only)

```diff
     ///     `currentAccount` (e.g.
-    ///     `AudiobookSessionManager.shared.openAudiobook`,
+    ///     `AppContainer.production().audiobookSession.openAudiobook`,
     ///     `CarPlayAuthHelper.isAuthenticated`,
```

### 7. Test files (build-fix only — Module D does final cleanup)

For each `let manager = AudiobookSessionManager.shared` site, replace with:

```swift
// Module B: replace shared singleton with locally-constructed instance.
// Module D will follow up to remove any now-redundant setUp/tearDown.
let manager = AudiobookSessionManager(appContainer: AppContainer.production())
```

Or, if the test class can hold an instance variable, declare it once:

```swift
final class AudiobookSessionStateTransitionTests: XCTestCase {
    private var manager: AudiobookSessionManager!

    override func setUp() async throws {
        try await super.setUp()
        manager = AudiobookSessionManager(appContainer: AppContainer.production())
    }
    // ... body uses self.manager ...
}
```

Pick whichever shape (per-test let vs instance var) keeps the diff smallest.
Module D will decide the final idiomatic shape on its pass.

**`await AudiobookSessionManager.shared.stopPlayback(dismissPhoneUI: false)`
in test setUp:** Module B replaces `.shared` with a freshly-constructed local
instance — a fresh instance has nothing to stop, so the call is a no-op.
Leave the call in place for now; Module D removes the redundant call (and
likely the entire setUp body if nothing else remains).

## Acceptance criteria

- `grep "static let shared" Palace/Audiobooks/ --include='*.swift'` returns 0
- `grep "AudiobookSessionManager\.shared\|PlaybackBootstrapper\.shared" Palace --include='*.swift'` returns 0
  (the AccountsManager.swift:307 comment is updated; no other matches)
- All build-blocking test references are migrated (grep above also returns 0 in PalaceTests for the production singleton names; Module D may leave some setUp body references, but build must be green)
- `xcodebuild build` succeeds for Palace AND Palace-noDRM
- `xcodebuild test -only-testing:PalaceTests/AudiobookSessionStateTransitionTests` passes
- `xcodebuild test -only-testing:PalaceTests/PlaybackBootstrapperTests` passes
- `xcodebuild test -only-testing:PalaceTests/AudiobookSessionManagerShutdownTests` passes
- `palace_mutate.py --diff-only --file Palace/Audiobooks/AudiobookSessionManager.swift --tests AudiobookSessionManagerTests` kill rate ≥80%
- No `clearAllState`-style dead-API calls remain — those are Module D's territory but Module B should verify they don't sneak in via copy-paste

## Implementer prompt

You are Module B implementer for `swarm_03acb10a`. You depend on Module A —
read `transcripts/A-AppContainerWiring.md` before starting; you need
`AppContainer.production().audiobookSession` and `.playbackBootstrapper` to exist.

PRE-WORK:
1. Write transcript skeleton FIRST at
   `.forgeos/swarms/swarm_03acb10a/transcripts/B-SingletonElimination.md`
   with 5 section headings (Read steps / Singletons deleted / Call sites /
   Test edits / Validation).
2. Read this contract + `transcripts/triage.md` + Module A's transcript.
3. Read AudiobookSessionManager.swift lines 80–230 (singleton + the two
   convenience inits you're keeping).
4. Read PlaybackBootstrapper.swift lines 50–110 (singleton + the two
   convenience inits).
5. Read the 3 production call sites (TPPAppDelegate:55, CarPlaySceneDelegate:43,
   BookService:75) to confirm the surrounding context matches the diff above.

Apply the 7 edits in the order listed. Validate after each:
- After edit 1 (delete `static let shared`): `xcodebuild build` will fail at
  the 3 call sites. Expected.
- After edits 2–5 (delete bootstrapper singleton + migrate 3 call sites):
  build succeeds.
- After edits 6–7 (test files): full test suite builds and passes.

**Do NOT touch** any file outside the in-scope list. The orchestrator's
worktree-symlink setup means stray edits to other modules' files will surface
as conflicts at integrate time.

Run mutation test on AudiobookSessionManager.swift after edits:

```bash
python3 scripts/palace_mutate.py \
  --file Palace/Audiobooks/AudiobookSessionManager.swift \
  --tests AudiobookSessionManagerTests \
  --diff-only
```

Write transcript. Do NOT commit, push, or dispatch agents.
