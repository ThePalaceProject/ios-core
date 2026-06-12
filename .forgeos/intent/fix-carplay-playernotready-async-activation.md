---
name: fix-carplay-playernotready-async-activation
created: 2026-06-11
author: claude-opus-4-8 (w-carplay)
tracking: WS-2 (3.2.0 M1 crash triage follow-up, initiative init_17bfe690 — no dedicated Jira ticket)
related_prs: ["#1050 (3.2.0 crash triage that deferred this — changeset cs_e1abd9f4)"]
crashlytics: ["d45f5aa9 (CarPlay OpenAccess .playerNotReady)"]
---

## Summary

PR #1050 (3.2.0 pre-regression crash triage) confirmed but **deferred** the CarPlay
OpenAccess `.playerNotReady` crash (Crashlytics `d45f5aa9`) to a reviewed follow-up.
This is that follow-up.

Root cause (app-side seam pinned in `.forgeos/intent/3.2.0-crash-triage.md`): during a
CarPlay **cold launch**, `PlaybackBootstrapper.ensureInitializedForCarPlay()` calls
`activateAudioSession()`, which issues a single `AVAudioSession.setActive(true)`. On a
cold CarPlay connect the audio session can transiently refuse activation (observed
error code `561015905`, plus `-50 paramErr` in the very-early-launch window). The
current code swallows that single failure and logs it — leaving the audio session
**not active**. The toolkit's `OpenAccessPlayer` then reports `playerIsReady != .readyToPlay`
when CarPlay issues the play command, hits `attemptToPlay`'s default branch
(`handlePlaybackError(.playerNotReady)` at `OpenAccessPlayer.swift:254`), and the
resulting failure surfaces the `.playerNotReady` crash on the CarPlay path.

The pinned fix is an **async bounded retry with backoff** on the activation: retry
`setActive` a small number of times with exponential backoff so the session has time to
become active before the play command is issued — and it MUST be async because
`activateAudioSession()` runs on the MainActor during CarPlay cold launch, so a
synchronous retry/sleep would block main for up to ~1s.

The retry/backoff/classification logic is extracted into a pure, injectable, deterministic
unit — `AudioSessionActivator` — so the bounded loop, the transient-vs-terminal error
predicate, and the backoff schedule are all unit-testable with no real `AVAudioSession`
and no real sleeps (CI-safe). `PlaybackBootstrapper` wires the real `AVAudioSession` +
`Task.sleep` into it and invokes it from a `Task { @MainActor }` so the synchronous
CarPlay `didConnect` path is never blocked.

## Claims

- Adds `Palace/Audiobooks/AudioSessionActivator.swift` — a new **internal** struct
  `AudioSessionActivator` encapsulating bounded async retry of audio-session activation.
  No new public API surface.
- `AudioSessionActivator.activate() async -> Outcome` runs a **bounded** loop
  (`1...maxAttempts`, default 3 — no unbounded loop): on success returns
  `.activated(attempts:)`; on a retriable error sleeps the backoff and retries; on a
  non-retriable error returns `.failed` immediately; when other audio is playing returns
  `.skippedOtherAudioPlaying` without activating.
- Adds pure static helper `AudioSessionActivator.isRetriable(errorCode:) -> Bool` —
  true for the transient activation codes (`561015905` observed in `d45f5aa9`, `-50`
  paramErr, `AVAudioSession.ErrorCode.cannotStartPlaying`/`.cannotInterruptOthers`
  rawValues), false otherwise (genuine/terminal errors fail fast — never retried).
- Adds pure static helper `AudioSessionActivator.backoff(forAttempt:base:cap:) -> TimeInterval`
  — exponential `base * 2^(attempt-1)` clamped to `cap`.
- The loop does **not** sleep after the final attempt (no wasted backoff before failing).
- `PlaybackBootstrapper.activateAudioSession()` is replaced by an async
  `activateAudioSessionWithRetry()` that builds an `AudioSessionActivator` from the real
  `AVAudioSession.sharedInstance()` (`isOtherAudioPlaying`, `setActive`) + `Task.sleep`
  for backoff, and logs the outcome.
- `PlaybackBootstrapper.ensureInitializedForCarPlay()` invokes the async activation via
  `Task { @MainActor [weak self] in await self?.activateAudioSessionWithRetry() }` so the
  synchronous `CPTemplateApplicationScene.didConnect` path is not blocked (the ~1s
  main-thread block the deferral flagged).
- Adds `PalaceTests/Audiobooks/AudioSessionActivatorTests.swift` — red-first tests:
  first-try success (1 attempt, setActive once), transient-then-success (retries with
  backoff, sleep called per retry), persistent-transient bounded at maxAttempts
  (setActive == maxAttempts, sleep == maxAttempts-1), non-retriable fails immediately
  (setActive once, sleep never), other-audio-playing skip (setActive never), plus pure
  `isRetriable` classification and `backoff` schedule tests.
- Registers both new files in the `Palace` + `Palace-noDRM` (production) and `PalaceTests`
  (test) targets via `scripts/pbxproj_add_swift.rb`.

## Anti-claims (out of scope)

- Does NOT modify the `ios-audiobooktoolkit` submodule. The HYBRID toolkit option (adding
  `561015905` to the toolkit's recoverable set in `OpenAccessPlayer`) is a separate
  submodule pass; this changeset is app-side only.
- Does NOT change the `MPRemoteCommandCenter` command handlers, the play/pause/skip
  routing, or `handlePlay`/`handlePause`/etc. semantics.
- Does NOT change the F-011 first-open `PlaybackReadinessGate` path
  (`openAudiobook` → `awaitReadinessAndIssueFirstPlay`); that gate already guards the
  first `play(at:)`. This changeset closes the distinct audio-session-not-active seam.
- Does NOT touch `CarPlayAudiobookBridge`, `CarPlayTemplateManager`, or the
  `AudiobookSessionManager` play/openAudiobook paths.
- Does NOT change `configureAudioSession()` (category/mode setup) or the public
  signatures of `ensureInitialized()` / `ensureInitializedForCarPlay()`.
- Does NOT address the OverDrive expired-URL or LCP-load deferrals (separate WS items).
- No new user-facing copy.

## Files in scope

- `Palace/Audiobooks/AudioSessionActivator.swift` (new)
- `Palace/Audiobooks/PlaybackBootstrapper.swift` (modified — `activateAudioSession` →
  async retry; `ensureInitializedForCarPlay` invocation site)
- `PalaceTests/Audiobooks/AudioSessionActivatorTests.swift` (new)
- `Palace.xcodeproj/project.pbxproj` (new-file registration, via helper)
