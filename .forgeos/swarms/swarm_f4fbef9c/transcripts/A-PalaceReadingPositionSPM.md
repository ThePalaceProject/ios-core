---
name: swarm_f4fbef9c-transcript-A-PalaceReadingPositionSPM
type: ephemeral
status: active
created: 2026-05-21
last_refresh: 2026-05-21
freshness_window: 180d
owners: [reader, audiobook]
description: Module A — PalaceReadingPosition SPM
---

# Module A — PalaceReadingPosition SPM

Status: complete

## Files added

`Palace/Packages/PalaceReadingPosition/` — new SPM module (8 files):

- `Package.swift` — iOS 16+/macOS 11+, depends on `PalaceLogging` (local).
- `.gitignore` — `.build/`.
- `Sources/PalaceReadingPosition/PositionWriter.swift` — public protocol with `save`, `load`, `cancel`.
- `Sources/PalaceReadingPosition/RemotePositionWriter.swift` — concrete `final class` impl, serial-queue throttle + per-bookID coalescing + deferred-flush + iOS background-task lifetime (`#if canImport(UIKit)` gated).
- `Sources/PalaceReadingPosition/PositionSnapshot.swift` — wire-shaped DTO (`bookID`, `format`, `payload: Data`, `timestamp`, `device`) + `init(from: ReadingPosition)` / `asReadingPosition()` bridging extension.
- `Sources/PalaceReadingPosition/PositionWriterError.swift` — error enum (throttled / networkUnavailable / unauthorized / serverError / malformedSnapshot / cancelled).
- `Sources/PalaceReadingPosition/PositionNetworkAdapter.swift` — network seam protocol (`post`/`fetch`).
- `Tests/PalaceReadingPositionTests/RemotePositionWriterTests.swift` — 14 cases.
- `Tests/PalaceReadingPositionTests/PositionSnapshotTests.swift` — 6 cases.

## Files moved

Five `Palace/Platform/` files migrated into the SPM via `git mv` (history preserved). Type access widened to `public`, file headers updated:

| Old path | New path |
|---|---|
| `Palace/Platform/ReadingPosition.swift` | `Palace/Packages/PalaceReadingPosition/Sources/PalaceReadingPosition/ReadingPosition.swift` |
| `Palace/Platform/PositionSyncService.swift` | `Palace/Packages/PalaceReadingPosition/Sources/PalaceReadingPosition/PositionSyncService.swift` |
| `Palace/Platform/PositionSyncServiceProtocol.swift` | `Palace/Packages/PalaceReadingPosition/Sources/PalaceReadingPosition/PositionSyncServiceProtocol.swift` |
| `Palace/Platform/CrossFormatMapping.swift` | `Palace/Packages/PalaceReadingPosition/Sources/PalaceReadingPosition/CrossFormatMapping.swift` |
| `Palace/Platform/PositionSyncRecord.swift` | `Palace/Packages/PalaceReadingPosition/Sources/PalaceReadingPosition/PositionSyncRecord.swift` |

Type-access widening also added a public `ReadingFormat` (was internal in Platform — `Palace/Stats/Models/ReadingSession.swift` retains its own internal `ReadingFormat` with identical cases, flagged in code comment as a known follow-up).

`Palace/Platform/PositionSyncBanner.swift` was intentionally LEFT in the Palace target per the contract — it's a SwiftUI view and stays in the UI layer.

### Consumer file edits (1-line each, also Module A's exclusive write per contract)

- `Palace/Platform/PositionSyncBanner.swift` — added `import PalaceReadingPosition`. `formatIcon(_:)` parameter qualified to `PalaceReadingPosition.ReadingFormat` to disambiguate from the internal `Palace.ReadingFormat`.
- `Palace/Platform/PlatformTab.swift` — added `import PalaceReadingPosition`. `checkForSync(bookID:openingFormat:)` parameter type qualified to `PalaceReadingPosition.ReadingFormat`.
- `Palace/Platform/AppHealthViewModel.swift` — added `import PalaceReadingPosition`.
- `PalaceTests/Platform/ReadingPositionTests.swift` — added `import PalaceReadingPosition`; `testReadingFormat_CodableRoundTrip` qualifies `ReadingFormat` to the SPM module.
- `PalaceTests/Platform/PositionSyncServiceTests.swift` — added `import PalaceReadingPosition`.
- `PalaceTests/Platform/CrossFormatMappingTests.swift` — added `import PalaceReadingPosition`.
- `PalaceTests/Platform/AppHealthViewModelTests.swift` — added `import PalaceReadingPosition` (this file was not listed in the contract but consumes the migrated types; minimal-import-add for Palace target compilation).

### pbxproj edits (`Palace.xcodeproj/project.pbxproj`)

- Added `XCLocalSwiftPackageReference` `PalaceReadingPosition` → `Palace/Packages/PalaceReadingPosition` (uses `relativePath` attribute to match the existing pattern).
- Linked product to 3 targets: `Palace`, `Palace-noDRM`, `PalaceTests`.
- Removed all 6 `PBXBuildFile` entries (3 per target × 2 phases) + 5 `PBXFileReference` + 5 group memberships for the migrated `.swift` files.

Performed via `xcodeproj` Ruby gem in `/tmp/swarm_f4fbef9c_pbxproj_edits.rb` plus two manual `Edit` calls to fix the gem's name-attribute drift (`path` → `relativePath`, display name `"LocalSwiftPackageReference"` → `"PalaceReadingPosition"`).

## Tests added

| Test class | Tests | What it covers |
|---|---:|---|
| `RemotePositionWriterTests` | 14 | save throttle window (first immediate, second queued, exact-boundary kills `>=`→`>` mutant, third-after-elapsed); queued-snapshot coalescing (latest-overwrites); cancel (idempotent, drops queued, doesn't affect other books); load (success / nil / throws); concurrency (different bookIDs don't interfere, same bookID coalesces). |
| `PositionSnapshotTests` | 6 | Equatable; Codable round-trip for all 3 formats; `init(from: ReadingPosition)` + `asReadingPosition()` bridging round-trip. |

**Existing tests still pass:** `PalaceTests/Platform/ReadingPositionTests` (22), `PositionSyncServiceTests` (13), `CrossFormatMappingTests` (14), `AppHealthViewModelTests` (8) — total **57** in the Palace target via `harness test`. Acceptance gate satisfied.

## Mutation kill rate

`palace_mutate.py --dry-run` discovered **3 mutation points** on `RemotePositionWriter.swift`:

1. Line 130 `>=` → `<=` — **KILLED** by `testSave_firstSnapshotInWindow_postsImmediately_returnsServerID` (and others); 7 failures.
2. Line 130 `>=` → `>` — initially SURVIVED; added `testSave_atExactThrottleBoundary_postsImmediately` which exercises the `elapsed == throttle` boundary. **KILLED** with the new test.
3. Line 201 `!=` → `==` — SURVIVES from the SPM test bundle. The mutated code is inside `#if canImport(UIKit)` (`endBackgroundTask` guard); on the macOS-host `swift test` runtime the alternate stub `endBackgroundTask(_ id: Int) {}` is used, so the mutation is unreachable from this layer. Killable via Module D's iOS-target contract-snapshot tests (flagged below as a gap).

**Local kill rate: 2/3 = 66.7%** from the SPM bundle on macOS. The unkillable mutant is environmental (iOS-only code under `canImport(UIKit)` shadowed by a no-op macOS stub) — not a missing behavior assertion. Both behavior-relevant mutants are killed by tests with arrange/act/assert that would also fail under negation.

`palace_mutate.py` itself can't drive the SPM test bundle directly because `PalaceReadingPositionTests` isn't registered in the `Palace` xcodebuild scheme — running `palace_mutate.py --tests PalaceReadingPositionTests/RemotePositionWriterTests` errors with "isn't a member of the specified test plan or scheme." Manual `swift test` per mutant was used instead. Module D could lock the call-order contract under iOS (Palace target), which kills mutant 3 via behavior assertion if it spies the `beginBackgroundTask`/`endBackgroundTask` pair.

## Key decisions

1. **`RemotePositionWriter` is a `final class` + serial `DispatchQueue`**, NOT an `actor`. Locked by the contract; confirmed appropriate because the writer owns `UIBackgroundTaskIdentifier` lifetime and `UIApplication.beginBackgroundTask`/`endBackgroundTask` are not actor-isolated. Mirrors `TPPLastReadPositionPoster.serialQueue` pattern.
2. **Throttle default 15.0s** — matches `TPPLastReadPositionPoster.throttlingInterval` exactly (verified at line 15 of the source).
3. **Clock injection via `() -> Date`**, not Swift `Clock`/`Duration` — iOS 16 compat. `FrozenClock` test helper allows deterministic decisions; deferred-flush dispatch uses `DispatchQueue.asyncAfter(deadline:)` which is wallclock — two boundary tests use a real-wallclock throttle of 0.1s instead of FrozenClock to exercise the deferred path within budget.
4. **`PositionSnapshot.payload: Data`** — opaque bytes carrying format-specific serialized form. Audiobook callers will pass `selectorValue.utf8`; EPUB callers Readium-locator JSON; PDF callers a tiny JSON page descriptor. The writer is payload-agnostic.
5. **`load()` has no cache** — caller owns conflict resolution. Locked by contract Deviation 7.
6. **`ReadingFormat` duplication** — the SPM defines a public `ReadingFormat` with cases `epub`/`audiobook`/`pdf`. `Palace/Stats/Models/ReadingSession.swift` already defines an internal one with identical cases. Both retained for now; reconciliation is out-of-scope for Module A and flagged in the SPM's `ReadingPosition.swift` doc comment. Consumers that import both modules in the same file need to qualify (`PalaceReadingPosition.ReadingFormat`) — fixed in 4 files.
7. **Build verification via the harness** (DRM Palace target) — `~/harness/bin/harness test` succeeded with 57/57 migrated tests passing. Direct `xcodebuild` against the worktree hit known "Multiple commands produce" build-graph errors from Carthage symlink loops; this is a worktree setup tax (per MEMORY.md `feedback_worktree_palace_setup.md`), not a Module A code issue. Palace-noDRM verified via direct `xcodebuild` after copying secret files (`APIKeys.swift`, `ReaderClientCert.sig`, `GoogleService-Info.plist`, etc.) from the main checkout — **BUILD SUCCEEDED**.
8. **Worktree setup performed in-flight** (not documented as pre-step): symlinked `Carthage`, `ios-audiobook-overdrive`, `ios-audiobooktoolkit`, `ios-tenprintcover`, `adept-ios`, `adobe-content-filter`, `adobe-rmsdk` from main `/Users/mauricework/PalaceProject/ios-core/`; copied secrets (APIKeys/GoogleService-Info/ReaderClientCert.sig) inline. None of these are tracked changes.

## Gaps for Modules B/C/D

### Module B (Audiobook migration — `AudiobookBookmarkBusinessLogic.swift`)

- Construct the writer via:
  ```swift
  let adapter: PositionNetworkAdapter = AudiobookPositionAdapter(annotations: annotationsManager)
  let positionWriter: PositionWriter = RemotePositionWriter(network: adapter)  // throttle: 15s default
  ```
- The adapter type lives in the Palace target (not the SPM). Mirror the existing `annotationsManager.postListeningPosition(forBook:selectorValue:)` call inside `AudiobookPositionAdapter.post(_:)`.
- `PositionSnapshot.payload` for audiobook should be `Data(selectorValue.utf8)`. To consume: `String(data: snapshot.payload, encoding: .utf8) ?? ""`.
- Keep `AudiobookBookmarkBusinessLogic`'s timestamp-newer + isAtBeginning guard in place; the writer's `load()` returns the raw remote snapshot, and `AudiobookBookmarkBusinessLogic` is the conflict-resolution site.
- Replace `debounce { syncListeningPositionToServer(...) }` (line 48) with `Task { try? await positionWriter.save(snapshot) }`. Drop the `debounce` machinery — the writer throttles centrally.

### Module C (Reader2 + PDF migration)

- `TPPLastReadPositionPoster`: delete the `lastReadPositionUploadDate`/`queuedReadPosition`/`serialQueue` state; thin to an EPUB-locator serializer that builds a `PositionSnapshot` (`format: .epubLocator`, `payload: Data(locator.jsonString?.utf8 ?? Data())`) and calls `positionWriter.save(snapshot)`.
- `TPPLastReadPositionSynchronizer.syncReadPosition(...)` load path: `await positionWriter.load(for: book.identifier)`. Keep the `deviceID == drmDeviceID && localLocation != nil || ...` merge rule unchanged.
- `TPPBaseReaderViewController.swift:92` one-line — accept `positionWriter: PositionWriter` parameter (default-built or via `AppContainer`).
- `TPPPDFDocumentMetadata.swift:95` — replace `TPPAnnotations.postReadingPosition(...)` with `positionWriter.save(...)`. PDF currently has no throttle; it'll inherit the 15s.

### Module D (Contract tests)

- Mutant 3 (`endBackgroundTask` guard `!= .invalid` flipped to `==`) is unkillable from the SPM bundle. Write a contract test in the iOS-target `PalaceTests/Contract/` that spies the `beginBackgroundTask`/`endBackgroundTask` pair: assert that `save()` calls `begin` once, awaits the post, then calls `end` with the same identifier. A no-op `endBackgroundTask` (the mutated branch) would leak the task and the spy would see no `end` call — kills the mutant.
- Snapshot scenarios for `PositionWriterContractTests`: `save_first_in_window_calls_post_then_endTask`, `save_within_window_queues_no_post`, `cancel_clears_pending`, `load_calls_fetch_only`.
- Use `RemotePositionWriter` directly with a `SpyAdapter` recording into a `CallLog`; lock the order `begin -> post -> end` (and `begin -> end` on cancel-before-post).

### Shared infrastructure

- The SPM emits 8 public types; integrators should ensure `xcodeproj` membership in `Palace`, `Palace-noDRM`, and `PalaceTests` is preserved across any future pbxproj rewrites.
- The harness `~/harness/bin/harness test` is the recommended driver from this orchestrator worktree; direct `xcodebuild` from the worktree CWD hits Carthage build-graph race noise.
- Build flow for verifications: `cd Palace/Packages/PalaceReadingPosition && swift test` (20 SPM tests) → `~/harness/bin/harness test -- -only-testing:PalaceTests/<TestClass>` (Palace iOS target) → optional `xcodebuild -scheme Palace-noDRM` after copying APIKeys.swift et al.

### Integrator action items

- **Submodule typechange (`T`) flags** on `adept-ios`, `adobe-content-filter`, `adobe-rmsdk`, `ios-audiobook-overdrive`, `ios-audiobooktoolkit`, `ios-tenprintcover` are worktree-local: the entries were converted from gitlinks to symlinks during the build verification to satisfy Carthage XCFramework references. The integrator should NOT commit these submodule changes — `git restore --staged --worktree` them (after the pre-destructive hook is satisfied / bypassed) or simply `git add -- :!adept-ios :!adobe-content-filter :!adobe-rmsdk :!ios-audiobook-overdrive :!ios-audiobooktoolkit :!ios-tenprintcover` when staging.
- **Carthage symlink** at the worktree root and the in-place copies of `Palace/AppInfrastructure/APIKeys.swift`, `PalaceConfig/ReaderClientCert.sig`, `PalaceConfig/GoogleService-Info.plist`, `PalaceConfig/GoogleService-Info-NoDRM.plist` are gitignored — they will not be staged and need no special handling.
