# Investigator E: Xcode 26.3 Actor-Isolation Tightening

## Mode
INVESTIGATION ONLY. No production-code or test-file edits.

## Hypothesis
Xcode 26.3 enforces stricter `@MainActor` / Sendable rules. `@MainActor`-isolated
methods can no longer satisfy nonisolated protocol requirements without
`@preconcurrency` annotation. These produce `note:` lines in build output that
admin-merge of PRs #1020-#1025 had to accept. The notes are NOT yet errors but:
(a) they pollute test-failure triage, (b) when Swift 6 mode lands they become
errors, and (c) the underlying concurrency violations can race in tests.

## Evidence the category exists (from CI run 26593379677)
- `Palace/CarPlay/CarPlayTemplateManager.swift:754:35`:
  "conformance of 'CarPlayTemplateManager' to protocol 'CPNowPlayingTemplateObserver'
  crosses into main actor-isolated code and can cause data races; this is an
  error in the Swift 6 language mode"
  - notes 755:10 `nowPlayingTemplateUpNextButtonTapped` cannot satisfy nonisolated requirement
  - notes 760:10 `nowPlayingTemplateAlbumArtistButtonTapped` cannot satisfy nonisolated requirement
- `Palace/Holds/HoldsViewModel.swift:7:51`:
  "conformance of 'HoldsBookViewModel' to protocol 'Identifiable' crosses into main actor"
  - note 10:9 `id` cannot satisfy nonisolated requirement
- `Palace/Settings/AccountDetailViewModel.swift:729:35`:
  "conformance ... to protocol 'NYPLUserAccountInputProvider' crosses into main actor"
  - note 730:9 `usernameTextField`
  - note 735:9 `PINTextField`
  - note 60:9  `forceEditability`
- `Palace/Settings/AccountDetailViewModel.swift:743:35`:
  "conformance ... to protocol 'TPPSignInOutBusinessLogicUIDelegate' crosses into main actor"
- (LCPStreamingPlayer, LCPResourceLoaderDelegate, DownloadWatchdog: Sendable
  capture warnings in audiobook toolkit — same family.)
- `Palace/Logging/ErrorLogExporter.swift:469` — `MailComposerDelegate` is
  `@MainActor` and conforms to `MFMailComposeViewControllerDelegate` (nonisolated
  Apple protocol). Same shape.

## What to look for

### Grep set 1 — class-level @MainActor conformances to known nonisolated protocols
Apple protocols whose methods are nonisolated:
- `MFMailComposeViewControllerDelegate` (MessageUI)
- `Identifiable` (SwiftUI) when on a class
- `CPNowPlayingTemplateObserver`, `CPTemplateApplicationSceneDelegate` (CarPlay)
- `URLSessionDelegate`, `URLSessionDownloadDelegate`, `URLSessionDataDelegate`
- `UNUserNotificationCenterDelegate`
- `AVAudioPlayerDelegate`, `AVPlayerItemMetadataOutputPushDelegate`
- Internal Palace protocols: `TPPSignInBusinessLogicUIDelegate`,
  `TPPSignInOutBusinessLogicUIDelegate`, `NYPLUserAccountInputProvider`,
  `NYPLBasicAuthCredentialsProvider`

For each: find every class marked `@MainActor` that conforms.

### Grep set 2 — Sendable warnings in build log
Per recent CI runs, `LCPStreamingPlayer`, `LCPResourceLoaderDelegate`,
`DownloadWatchdog` all warn about non-Sendable self capture. Audit the
audiobook-toolkit submodule (`ios-audiobooktoolkit/PalaceAudiobookToolkit/Player/`)
for matching shape.

### Grep set 3 — async-mainactor.run wrappers (workaround anti-pattern)
```
grep -rn "await MainActor.run" Palace/ ios-audiobooktoolkit/
```
Excessive `MainActor.run` in delegate methods is a sign the conformance is
already actor-mismatched.

### Grep set 4 — protocols Palace defines that ought to be @MainActor
If an internal protocol is conformed-to ONLY by `@MainActor` types (e.g.
`TPPSignInBusinessLogicUIDelegate`), the fix is to annotate the protocol
itself `@MainActor` rather than each conformer with `@preconcurrency`. Find
candidates.

## Where to look
- `Palace/CarPlay/` — confirmed hit
- `Palace/Holds/HoldsViewModel.swift` — confirmed hit
- `Palace/Settings/AccountDetailViewModel.swift` — confirmed hit
- `Palace/Logging/ErrorLogExporter.swift` — confirmed hit
- `Palace/SignInLogic/` — TPPSignInBusinessLogicUIDelegate is the protocol
- `Palace/Network/` — URLSessionDelegate conformances
- `Palace/AppInfrastructure/AppDelegate*.swift`,
  `Palace/AppInfrastructure/SceneDelegate*.swift` — UN* delegates
- `Palace/Audiobooks/`, `ios-audiobooktoolkit/PalaceAudiobookToolkit/Player/`

## Evidence to collect
```
file:line | conforming_class | protocol | actor_mismatch_type | swift_6_blocker? | fix_shape
```
fix_shape ∈ {ANNOTATE_PROTOCOL_MAINACTOR, ADD_PRECONCURRENCY,
SPLIT_NONISOLATED_FACADE, ISOLATE_TO_MAINACTOR}

## Proposed fix SHAPE (NO code — investigator must NOT write the actual fix)
1. For internal Palace protocols only conformed to by `@MainActor` types:
   annotate the **protocol** `@MainActor`. Single-point structural fix.
2. For Apple-framework protocols (MFMailCompose, URLSession, Identifiable on a
   class): the conforming type splits into a nonisolated facade (the delegate)
   that hops to a `@MainActor` worker. SHAPE only — investigator does not write
   the split.
3. Build-warning CI gate: `verify-pr.sh` fails on NEW `main actor-isolated ...
   cannot satisfy nonisolated requirement` notes (diff-scoped — pre-existing
   findings stay on the baseline; only new regressions block).
4. A periodic Xcode-version-rev audit checklist: every Xcode release notes-line
   about Sendable/actor isolation triggers a re-run of grep sets 1-3.

## NOT in scope
- No `Palace/**` or `ios-audiobooktoolkit/**` code edits.
- No `@preconcurrency` insertions. Enumerate, don't fix.
- Do not block on Swift 6 enablement debate — the warnings are real today even
  in Swift 5 mode.

## Output contract
Same shape as Investigator A, with extra column `swift_6_blocker?` (Y/N) since
this category has a known future deadline.
```

---
