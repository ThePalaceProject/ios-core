# Module B — Singleton elimination

**Status:** skeleton — architect to refine on triage.

## In-scope files (exclusive write)

- MOD `Palace/Audiobooks/AudiobookSessionManager.swift` — remove `static let shared` at line 87; constructor accepts dependencies (architect verifies exact dependency surface)
- MOD `Palace/Audiobooks/PlaybackBootstrapper.swift` — remove `static let shared` at line 56; the 3 internal references to `AudiobookSessionManager.shared` (lines 69, 93, 103) become injection points
- MOD `Palace/AppInfrastructure/TPPAppDelegate.swift:55` — `PlaybackBootstrapper.shared.ensureInitialized()` → `AppContainer.production().playbackBootstrapper.ensureInitialized()`
- MOD `Palace/CarPlay/CarPlaySceneDelegate.swift:43` — `PlaybackBootstrapper.shared.ensureInitializedForCarPlay()` → `AppContainer.production().playbackBootstrapper.ensureInitializedForCarPlay()`
- MOD `Palace/Book/UI/BookDetail/BookService.swift:75` — `AudiobookSessionManager.shared.openAudiobook(...)` → `AppContainer.production().audiobookSession.openAudiobook(...)` OR (preferred) `self.audiobookSession.openAudiobook(...)` if `BookService` already has an AppContainer injected
- MOD `PalaceTests/Audiobook/AudiobookSessionManagerTests.swift` (architect inventories) — replace shared-state setUp with injection
- MOD `PalaceTests/Audiobook/PlaybackBootstrapperTests.swift` (architect inventories) — same

## Out-of-scope (read-only)

- `Palace/AppInfrastructure/AppContainer.swift` (Module A territory)
- All files in swarm-wide don't-touch list

## Migration approach

`AudiobookSessionManager.swift`:
- Convert `static let shared = AudiobookSessionManager()` private parameterless init pattern to an `init(dependencies:)` form with defaults that pull from `AppContainer.production()` when not injected.
- Existing instance state (whatever it is) becomes per-instance.
- If the class is `@MainActor`-isolated, document the isolation in the new init.

`PlaybackBootstrapper.swift`:
- Remove `static let shared`.
- Lines 69 + 93 + 103 reference `AudiobookSessionManager.shared` — convert to an injected `audiobookSessionProvider: @escaping () -> AudiobookSessionManaging` parameter (line 103 already has this shape with `static let shared` as default — just remove the `static let` default and require injection from AppContainer).

## Migration of test files (architect inventories)

Many audiobook tests probably reset shared state in `setUp`. Once `static let shared` is gone:
- Tests that injected via `static let` can use the AppContainer's factory directly (`AppContainer.production().audiobookSession`)
- Tests that need spies subclass `AudiobookSessionManager` (architect verifies the class isn't `final`)
- The `setUp resets shared mock` workaround pattern (per ADR Pattern 5) becomes a no-op and is deleted in Module D

## Acceptance criteria

- `grep "static let shared" Palace/Audiobooks/` returns 0
- `grep "AudiobookSessionManager\.shared\|PlaybackBootstrapper\.shared" Palace --include='*.swift'` returns 0 outside AppContainer.swift's factory implementation
- All existing audiobook tests still pass
- No callback added to `AudiobookSessionManager`'s public surface
- `xcodebuild build` succeeds for Palace + Palace-noDRM

## Implementer prompt

You are Module B implementer for `swarm_03acb10a`. You depend on Module A's AppContainer factory.

PRE-WORK:
1. Write transcript skeleton FIRST.
2. Read Module A's transcript section "B/C handoff" — exact factory call signature.
3. Read the 3 production call sites (`TPPAppDelegate.swift:55`, `CarPlaySceneDelegate.swift:43`, `BookService.swift:75`).
4. Read AudiobookSessionManager.swift constructor + `init` — what dependencies does the singleton hide?
5. Read PlaybackBootstrapper.swift lines 56-110 — the existing `audiobookSessionProvider:` shape gives the migration template.

Use defaulted parameters on `AudiobookSessionManager.init` and `PlaybackBootstrapper.init` if needed for backward compat with tests that hadn't migrated yet. The defaults can reference AppContainer.

Validate: `xcodebuild build` + run all audiobook test classes + `palace_mutate.py --diff-only` on lifecycle methods (target ≥80% kill).

Write transcript. Do NOT commit, push, or dispatch agents.
