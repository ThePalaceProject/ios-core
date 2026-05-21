# Module A — AppContainer audiobook wiring

**Status:** skeleton — architect to refine on triage.

## In-scope files (exclusive write)

- MOD `Palace/AppInfrastructure/AppContainer.swift` — add per-account `audiobookSession: AudiobookSessionManaging` factory + `playbackBootstrapper` factory
- NEW `PalaceTests/AppInfrastructure/AppContainerAudiobookFactoryTests.swift` — verify the factory returns distinct instances per account, caches per-account, and accepts injected dependencies for tests

## Out-of-scope (read-only)

- `Palace/Audiobooks/AudiobookSessionManager.swift` (Module B territory — Module A consumes its protocol, doesn't edit the class)
- `Palace/Audiobooks/PlaybackBootstrapper.swift` (Module B)
- All `.shared` call sites (Module B)
- Existing Account state machine code in AppContainer (touch only the audiobook section)

## Public surface (architect to lock)

```swift
extension AppContainer {
    /// Per-account audiobook session manager. Caches per-account UUID so
    /// repeated lookups return the same instance for the lifetime of an
    /// account. On account switch the cache evicts.
    public var audiobookSession: AudiobookSessionManaging { get }

    /// Shared playback bootstrapper. Owns the warm-start CarPlay session
    /// initialization invariant — a `static let shared` no longer.
    public var playbackBootstrapper: PlaybackBootstrapper { get }
}
```

The factory follows whatever per-account pattern AppContainer already exposes (architect verifies — PR #967 Account state machine Phase 2 should have established the precedent). If no per-account pattern exists yet, Module A may add a minimal one (`func make<T>(for account:)` style) scoped to audiobook only.

## Tests owned

- `testAudiobookSession_sameAccount_returnsSameInstance` — caching invariant
- `testAudiobookSession_differentAccount_returnsDifferentInstance` — per-account isolation
- `testAudiobookSession_accountSwitch_evictsOldInstance` — lifecycle
- `testPlaybackBootstrapper_returnsSameInstance` — singleton semantics retained (just AppContainer-mediated, not `static let`)

## Acceptance criteria

- `audiobookSession` factory ≤80 LOC added to AppContainer
- New test class with 4 named scenarios
- Existing AppContainer tests continue to pass
- No `static let shared` reads inside the new factory implementation

## Implementer prompt

You are Module A implementer for `swarm_03acb10a`. Add per-account `audiobookSession` factory + `playbackBootstrapper` factory to `Palace/AppInfrastructure/AppContainer.swift`.

PRE-WORK:
1. Write transcript skeleton FIRST at `.forgeos/swarms/swarm_03acb10a/transcripts/A-AppContainerWiring.md` (5 sections).
2. Read the refined contract + plan + triage transcript.
3. Read AppContainer.swift fully; identify the existing per-account pattern landed by PR #967 (Account state machine Phase 2). Mirror it for audiobook.

The factory does NOT instantiate `AudiobookSessionManager` via `static let shared` — it constructs a new instance with explicit dependencies. Until Module B lands, the existing `static let shared` still works for callers that haven't migrated; the factory just provides a parallel path.

Use the `pbxproj_add_swift.rb` helper to add the new test file.

Validate: `xcodebuild build` + `xcodebuild test -only-testing:PalaceTests/AppContainerAudiobookFactoryTests` both succeed.

Write the full transcript at the end. Do NOT commit, do NOT push, do NOT dispatch other agents.
