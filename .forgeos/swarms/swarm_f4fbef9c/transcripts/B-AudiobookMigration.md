# Module B — Audiobook Migration Transcript

Implementer: Module B
Swarm: swarm_f4fbef9c
Status: complete (staged, not committed — integrator owns the commit)

## Files modified

| Path | LOC before → after | Δ |
|---|---|---|
| `Palace/Reader2/Bookmarks/AudiobookBookmarkBusinessLogic.swift` | 535 → 568 | **+33** |
| `PalaceTests/Audiobook/AudiobookTimeEntryTests.swift` | 291 → 239 | **−52** |
| `Palace.xcodeproj/project.pbxproj` | (registers new files; drops `LatestAudiobookLocation.swift`) | — |

LOC note: the contract estimate was −10 to −20 on `AudiobookBookmarkBusinessLogic.swift`. Actual is +33. The "shrink" estimate assumed deleting `syncListeningPositionToServer` (58 LOC) and inlining a short `Task { try? await positionWriter.save(...) }`. Reality: preserving the swarm_f3b9b087 P0 #4/#5 conflict-resolution predicates inside the new `Task` body (timestamp-newer race check + isAtBeginning guard) plus the async `do/try/guard let` boilerplate plus extensive comments produced a ~85 LOC body that net-grew the file. The conflict-resolution logic is now in one async path instead of two methods, but the per-line cost of `try await` + comments is real. This is acceptable: the behavior is correct and the predicates are intact.

## Files added

| Path | LOC |
|---|---|
| `Palace/Reader2/Bookmarks/AudiobookPositionAdapter.swift` | 60 |
| `PalaceTests/Audiobook/AudiobookBookmarkBusinessLogicPositionWriteTests.swift` | 413 |

## Files deleted

| Path | LOC |
|---|---|
| `Palace/Audiobooks/LatestAudiobookLocation.swift` | 19 (confirmed dead code per Deviation 3) |
| `PalaceTests/Audiobook/AudiobookTimeEntryTests.swift` lines 94-141 (the `LatestAudiobookLocationTests` class block, 3 fluff tests) | 48 |
| Header comment line 5 of `AudiobookTimeEntryTests.swift` (dropped the dead reference) | (in-place edit) |

`git grep "LatestAudiobookLocation\|latestAudiobookLocation" -- Palace PalaceTests '*.swift'` returns 0 — acceptance criterion satisfied.

## Tests added

6 new tests in `PalaceTests/Audiobook/AudiobookBookmarkBusinessLogicPositionWriteTests.swift` matching the locked contract scenario list:

1. `testSaveListeningPosition_savesLocallyImmediately` — pins the swarm_f3b9b087 P0 #4 "local-save-first" invariant. Asserts `registry.location(forIdentifier:)` is populated **before** the async Task hop.
2. `testSaveListeningPosition_delegatesNetworkSaveToPositionWriter` — spy `PositionWriter` records `save(_:)` invocation. Asserts snapshot `bookID`, `format == .audiobook`, payload non-empty + contains `@type` (the AudioBookmark JSON marker), and `completion` receives the server ID.
3. `testSaveListeningPosition_writerThrottled_localStillCommitted` — writer returns `nil` (throttled/queued path). Asserts local registry is still committed and completion is called with `nil`.
4. `testSaveListeningPosition_writerError_doesNotCrash_completionCalledWithError` — writer throws. Asserts local registry preserved, completion called with `nil` (no crash, error surfaced through completion, log emitted).
5. `testIsAtBeginning_preservedAfterMigration_doesNotOverwriteValidPosition` — pre-seeds a later-track bookmark, drives a `track 0, time=5s` save with a successful server response, asserts the **annotationId is NOT overwritten** and the chapter survives. This is the mutation-killer for the swarm_f3b9b087 P0 #4 `(trackIndex == 0 && playbackTime < 30.0)` predicate.
6. `testTimestampNewerRace_preservedAfterMigration_keepsLocal` — installs a custom `PositionWriter` that swaps the registry to a fresher bookmark inside `save(...)` (between the SUT's synchronous local save and its post-save guard). Asserts the fresh-local annotationId survives a stale upload result. Mutation-killer for the timestamp-newer race-check predicate (`String.isDate(..., moreRecentThan:, with: 1.0)`).

A custom inline `SpyPositionWriter` class lives in the test file (33 LOC) — thread-safe, configurable `saveResult` outcome (`.success(id)` / `.throttled` / `.failure(error)`).

## Behavior changes flagged for QA

**15s throttle window on audiobook position writes** (Deviation 6 trade-off): the previous implementation used a per-instance 1-second `debounce` that coalesced rapid saves. The new `RemotePositionWriter` (Module A) uses a **15-second per-book throttle** matching `TPPLastReadPositionPoster.throttlingInterval`.

User-visible effect:
- **Most playback paths: no observable change.** A reader who pauses, scrubs, and resumes within seconds still posts at most once.
- **Rapid track-skip cycles in resume-after-pause**: the new path posts ≤1 per 15s; the old path posted on every settle of the debounce. In the failure-mode where the user immediately skips to chapter end while the writer is throttled, the queued snapshot reflects the latest scrub — same end-state as old code, but the intermediate states aren't on the wire.

QA verification path: drive the audiobook player via simdrive, exercise a rapid `forward → back → forward → forward → settle` flow on a 30-track audiobook, watch the network log for `/annotations/` POSTs. Expectation: one POST during the active flow, with the final-settle position. (`AudiobookBookmarkBusinessLogic.flushPendingOperations()` is still wired for `willTerminate` / `didEnterBackground` — `Task`s don't queue inside a `DispatchWorkItem` anymore, but the writer's deferred-flush handles equivalently.)

## Key decisions

1. **AudiobookPositionAdapter lives in `Palace/Reader2/Bookmarks/`** (alongside `TPPAnnotations.swift` / `AudiobookBookmarkBusinessLogic.swift`), not in `Palace/Audiobooks/`. Justification: the adapter wraps an `AnnotationsManager` (defined in `TPPAnnotations.swift`), and the entire audiobook-bookmark surface already lives under `Reader2/Bookmarks/`. Keeps the cluster cohesive.
2. **PositionSnapshot.payload = `Data(tppLocation.locationString.utf8)`** — the audiobook's full `AudioBookmark` JSON serialization (the same string previously passed to `annotationsManager.postListeningPosition(selectorValue:)`). On the server side, the wire format is unchanged. Module D contract tests can pin this by examining the snapshot.payload bytes against a canonical AudioBookmark JSON.
3. **PositionSnapshot.device = `AnnotationDevice.currentID()`** — uses the existing device-ID resolution (Adobe DRM ID → fallback Firebase device ID) already shared with EPUB writes. No new device-resolution code.
4. **Default writer construction uses the locally-injected `AnnotationsManager`**, not `AppContainer.production().positionWriter` — `AppContainer` does NOT have a `positionWriter` field, and Module A's transcript explicitly chose not to add one. We wire the adapter from the AnnotationsManager that's already in this constructor. The `positionWriter:` parameter is `nil`-defaulted, so the existing `AudiobookBookmarkBusinessLogic(book:)` `@objc convenience init` still works — `Palace/Audiobooks/AudiobookLoader.swift:303` is **NOT touched**.
5. **Conflict-resolution lives in the SUT, not the writer.** The swarm_f3b9b087 P0 predicates — timestamp-newer race-check (1-second grace window via `String.isDate(_:moreRecentThan:with:1.0)`), isAtBeginning guard `(trackIndex == 0 && playbackTime < 30.0)` — are **audiobook-specific**, not part of `PositionWriter`'s contract. They run AFTER `try await positionWriter.save(snapshot)` returns a server ID, gating whether to commit the server-assigned `annotationId` to the local registry. Exact-text preservation: the predicates were copy-paste-moved into the new `Task` body, comment block added.
6. **AudiobookPositionAdapter.fetch(bookID:) returns nil.** The audiobook write path does not load from the server; conflict resolution reads `registry.location(forIdentifier:)` for the current local state, never a fresh remote fetch. The writer's `load(for:)` is implemented but is a no-op — documented inline. If a future feature needs remote audiobook position fetch, the adapter is the seam to extend.
7. **`@unchecked Sendable` on `AudiobookPositionAdapter`** — the adapter wraps an `AnnotationsManager` (a non-`Sendable` `class`-based protocol). The adapter is stateless beyond the immutable wrap; thread-safety is the underlying `AnnotationsManager`'s responsibility (which uses TPPNetworkExecutor internally). Mirrors the pattern Module A used on `RemotePositionWriter`.

## Validation

- **SPM (`PalaceReadingPosition`) `swift build`**: clean (verified — `.build/.../Modules/PalaceReadingPosition.swiftmodule` produced).
- **`xcodebuild Palace`**: **NOT verifiable from this worktree.** The `Carthage` symlink in the worktree resolves to another worktree (`ios-core-carplay-crash`), causing "Multiple commands produce" for `AudioEngine.framework` (50+ errors). This is the same worktree-tax Module A's transcript flagged ("the worktree setup tax, not a code issue"). The harness build path runs against the main checkout — which doesn't have Module B's changes yet — so the integrator must re-run validation from the main checkout after picking up this branch.
- **pbxproj cleanliness**: confirmed.
  - `grep -c "LatestAudiobookLocation" Palace.xcodeproj/project.pbxproj` → `0`.
  - `grep AudiobookPositionAdapter Palace.xcodeproj/project.pbxproj` shows entries in BOTH Palace and Palace-noDRM Sources phases plus a PBXFileReference.
  - `grep AudiobookBookmarkBusinessLogicPositionWriteTests Palace.xcodeproj/project.pbxproj` shows a single PalaceTests Sources entry plus a PBXFileReference.
- **`git grep "LatestAudiobookLocation\|latestAudiobookLocation" -- Palace PalaceTests '*.swift'`** → empty. Acceptance criterion satisfied.

## Gaps for Module D (contract tests)

The audiobook-side contract test should pin the **post-save commit order** when the SUT receives a successful writer response with no conflict:

1. `registry.setLocation(...)` is called once (the synchronous local-save-first).
2. `positionWriter.save(...)` is called once with the snapshot whose `bookID` matches and `format == .audiobook`.
3. On `.success`, `registry.setLocation(...)` is called a SECOND time (committing `audioBookmark.annotationId = serverID`).
4. `completion(serverID)` fires.

For the **isAtBeginning guard** scenario: after step 2, step 3 is **SUPPRESSED** (no second registry write) — the contract diff between the happy-path and the guarded-path is one missing setLocation call. Same shape for the timestamp-race guard.

For the **throttled** scenario: `positionWriter.save(...)` returns `nil`, so step 3 + completion fires with `nil`. No second registry write.

This is a cleaner-than-mutation-test shape because the predicates collapse into "did the second setLocation happen?" rather than "what was the predicate value?" — Module D's `ContractSnapshot.assert(log, named: ...)` against a `CallLog` of `[registry.setLocation, writer.save, registry.setLocation?, completion]` would catch any future regressions on these guards.

Also unkillable from Module A's SPM bundle: the `endBackgroundTask` `!= .invalid` guard at `RemotePositionWriter.swift:201`. The audiobook side is not the right test surface for that (the adapter doesn't see UIBackgroundTask) — Module D's iOS-target contract tests should spy `beginBackgroundTask` / `endBackgroundTask` directly via a `RemotePositionWriter` with a custom adapter, not via `AudiobookBookmarkBusinessLogic`.

## Integrator notes

- **Don't commit Palace.xcodeproj/project.pbxproj changes from the worktree if a Module C branch also has them.** Pbxproj merges are messy. The pbxproj surgery script I used is at `/tmp/swarm_f4fbef9c_module_b_pbxproj.rb` — idempotent, runs `remove_file_everywhere('LatestAudiobookLocation.swift') + add_file_to_targets(AudiobookPositionAdapter.swift, [Palace, Palace-noDRM]) + add_file_to_targets(test file, [PalaceTests])`. Re-run if Module C's pbxproj edits land first.
- **Submodule `T` typechange flags** (adept-ios, adobe-content-filter, ios-audiobook-overdrive, ios-audiobooktoolkit, ios-tenprintcover) are worktree-local symlink-conversions — Module A's transcript already noted these. Don't stage them.
- **Carthage symlink** at worktree root is gitignored. Same for in-place secret copies (`Palace/AppInfrastructure/APIKeys.swift`, `PalaceConfig/GoogleService-Info.plist`, `PalaceConfig/ReaderClientCert.sig`).
- **Tests to re-run from main checkout after picking up this branch** (acceptance gate):
  - `xcodebuild -only-testing:PalaceTests/AudiobookBookmarkBusinessLogicPositionWriteTests test` (6 new tests must pass).
  - `xcodebuild -only-testing:PalaceTests/AudiobookPositionPolicyTests -only-testing:PalaceTests/AudiobookTimeEntryTests -only-testing:PalaceTests/AudiobookDataManagerSyncTests -only-testing:PalaceTests/AudiobookEventsTests test` — regression gates per the contract.
  - `xcodebuild -only-testing:PalaceTests/AudiobookBookmarkBusinessLogicTests test` — existing audiobook bookmark test class. The migration changed the init signature with an optional `positionWriter: nil` default — these tests pass `book:registry:annotationsManager:` and should compile unchanged.
- **Palace-noDRM target**: needs the same secret-file copy treatment as Palace if validated from a fresh checkout (per Module A's transcript). pbxproj entries are in both Sources phases.
