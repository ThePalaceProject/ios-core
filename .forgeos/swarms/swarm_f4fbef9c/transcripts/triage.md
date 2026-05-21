# Swarm 2 (swarm_f4fbef9c) — Architect Triage

**Architect:** Opus 4.7 (1M)
**Date:** 2026-05-21
**Branch:** `swarm/swarm_5c8ddbd5-scaffold` (orchestrator worktree)
**Phase:** Phase 2 of audiobook systemic overhaul — PositionWriter unification
**Wallclock:** ~30 min (within budget)

---

## 1. Material deviations from plan/ADR

The plan/contract skeletons were drafted from the ADR without grounding against current code. After auditing, 7 material structural deviations surfaced. Two are blockers if uncorrected; the rest reshape implementer scopes but are tractable.

### Deviation 1 — `AudiobookDataManager.swift` is **not** a position writer. It's a time-tracker.

The contract claims `AudiobookDataManager` (345 LOC) does "Network sync of position data." False. Read of `Palace/Audiobooks/Tracker/AudiobookDataManager.swift` (full file) shows it posts **time-tracking entries** (`AudiobookTimeEntry` — minute + secondsPlayed) to a `timeTrackingUrl` endpoint. The struct `RequestData` carries `[TimeEntry]` (id/duringMinute/secondsPlayed), not positions. The endpoint is per-book time analytics, not the annotation endpoint.

**Implication:** Module B's premise — "delete network sync; delegate to PositionWriter" — does not apply to `AudiobookDataManager`. Nothing in `AudiobookDataManager` is a position writer. It stays as-is.

### Deviation 2 — The **actual** audiobook position writer is `Palace/Reader2/Bookmarks/AudiobookBookmarkBusinessLogic.swift:37-110`.

`AudiobookBookmarkBusinessLogic.saveListeningPosition(at:completion:)` is the toolkit's `AudiobookBookmarkDelegate.saveListeningPosition` conformance (`Palace/Reader2/Bookmarks/AudiobookBookmarkBusinessLogic.swift:535`). It:
1. Saves locally via `registry.setLocation(...)` (line 43)
2. `debounce { ... syncListeningPositionToServer(...) }` (line 48)
3. Inside the sync: calls `annotationsManager.postListeningPosition(forBook:selectorValue:)` (line 67)
4. Conflict-resolution: timestamp-newer race check + "isAtBeginning" guard (lines 76-96) — both hardened by swarm_f3b9b087 commit `520573305`

`AudiobookBookmarkBusinessLogic` is owned by `Palace/Audiobooks/AudiobookLoader.swift:531` — Swarm 1's territory and on the don't-touch list. The instantiation is `let bookmarkLogic = AudiobookBookmarkBusinessLogic(book: book); manager.bookmarkDelegate = bookmarkLogic`.

**Implication:** Module B must be re-scoped. The audiobook migration target is `AudiobookBookmarkBusinessLogic.swift` (under `Palace/Reader2/Bookmarks/`, despite the name), not `AudiobookDataManager.swift` / `AudiobookTimeTracker.swift`. The Tracker files stay untouched.

### Deviation 3 — `LatestAudiobookLocation.swift` is **dead code**.

`git grep "latestAudiobookLocation\|LatestAudiobookLocation" Palace --include="*.swift"` returns ONLY references in `LatestAudiobookLocation.swift` itself and its dedicated test file `PalaceTests/Audiobook/AudiobookTimeEntryTests.swift:96-141` (which has 3 fluff tests setting then asserting the global). No production code reads or writes it.

**Implication:** Module B can delete `Palace/Audiobooks/LatestAudiobookLocation.swift` (19 LOC) AND delete the `LatestAudiobookLocationTests` class in `AudiobookTimeEntryTests.swift` (lines 94-141). It does NOT need to fold into `PositionSnapshot.payload` — there's no caller. Zero risk delete.

### Deviation 4 — `Palace/Platform/ReadingPosition.swift` + `PositionSyncService.swift` already exist as cross-format scaffolding.

`Palace/Platform/ReadingPosition.swift` (150 LOC) defines `struct ReadingPosition` (bookID + format + timestamp + format-specific fields). `Palace/Platform/PositionSyncService.swift` (155 LOC) is an `actor` with `static let shared` that records and offers cross-format sync. `Palace/Platform/PositionSyncServiceProtocol.swift` defines `protocol PositionSyncServiceProtocol`. `Palace/Platform/CrossFormatMapping.swift` + `Palace/Platform/PositionSyncBanner.swift` + `Palace/Platform/PositionSyncRecord.swift` round out the surface.

These exist and have **comprehensive tests** (`PalaceTests/Platform/ReadingPositionTests.swift`, `PalaceTests/Platform/PositionSyncServiceTests.swift`, `PalaceTests/Platform/CrossFormatMappingTests.swift`). `git grep "PositionSyncService\.shared|recordPosition|PositionSyncServiceProtocol"` outside `Palace/Platform` returns **zero production callers** — the scaffolding is test-only / not yet wired.

**Direct naming/concept collision:** the contract proposed `PositionWriter` + `PositionSnapshot` + `CanonicalPositionWriter` in a new SPM. `ReadingPosition` (existing) maps closely to the proposed `PositionSnapshot`. `PositionSyncService` (existing) is conceptually related but its responsibility is the cross-format sync layer (record-from-anywhere, offer-when-opening-other-format) — **not** the network-write throttle layer.

**Implication:** Avoid collision and rework:
- Lock SPM module name as `PalaceReadingPosition` (matches `ReadingPosition` already in `Palace/Platform/`).
- Migrate `Palace/Platform/ReadingPosition.swift` + the cross-format types **into the SPM module** as part of Module A. The existing tests under `PalaceTests/Platform/` continue to pass (they reuse the type via `@testable import Palace` — change to `import PalaceReadingPosition`).
- Rename the network-write impl from `CanonicalPositionWriter` to `RemotePositionWriter` to keep it semantically distinct from the existing `PositionSyncService` (which is the **local-record** sync layer).
- Keep `PositionWriter` as the protocol name (no existing collision; `TPPLastReadPositionPoster` is named differently).
- Use `PositionSnapshot` as the in-flight DTO type **distinct from** `ReadingPosition` — the latter is the persisted cross-format-mappable model; the former is the wire-shaped, write-path DTO. Module A's `Sources/PalaceReadingPosition/PositionSnapshot.swift` carries `bookID + format + payload (Data) + timestamp + device` and is transparently convertible from/to `ReadingPosition`.

This is a non-trivial scope addition for Module A (migrating ~5 existing Platform files into the SPM). It is **necessary** — leaving two parallel `ReadingPosition` types in the codebase reproduces exactly the duplication pattern Pattern 4 exists to eliminate.

### Deviation 5 — `AudiobookSessionManager.swift` does NOT need editing. Delegate wiring is in `AudiobookLoader.swift` (Swarm 1 territory).

The plan and Module B contract repeatedly hedge "FLAG to integrator if you need to edit `AudiobookSessionManager.swift`." Verified: `grep` for `AudiobookBookmarkDelegate|bookmarkDelegate|AudiobookBookmarkBusinessLogic` in `Palace/Audiobooks/AudiobookSessionManager.swift` returns no matches. The delegate is instantiated at `Palace/Audiobooks/AudiobookLoader.swift:531`.

`AudiobookLoader.swift` is on Swarm 1's don't-touch list (PR #979). Module B will need to inject the new `PositionWriter` into `AudiobookBookmarkBusinessLogic` via its initializer; the wire-up at `AudiobookLoader.swift:531` then needs the writer passed through. **This is a one-line edit in Swarm 1's territory.** Two options:

1. **(Preferred)** — Land Swarm 2 with `AudiobookBookmarkBusinessLogic` taking the writer via an optional default-initialized parameter, and update the `AudiobookLoader.swift:531` constructor in a Swarm 3 follow-up commit. The default falls back to a `RemotePositionWriter` that wraps `TPPAnnotations.postReadingPosition`, preserving the current behavior bit-for-bit.
2. Edit `AudiobookLoader.swift:531` as a one-line exception, document it explicitly in this triage. This is what the contract anticipates.

**Recommendation: option 1.** Adding the new dep with a sensible default does NOT cross Swarm 1's territory (the line stays unchanged); Swarm 3 takes ownership of the wiring change.

### Deviation 6 — Throttle window: audiobook side uses a `debounce` (no fixed window value); EPUB side uses 15s. They differ.

`TPPLastReadPositionPoster.throttlingInterval = 15.0` (line 15) — locked.

`AudiobookBookmarkBusinessLogic.saveListeningPosition` calls `debounce { ... }` (line 48). The `debounce` helper is local to that file; let me check the implementation — it's a per-instance debounce on every save call. Implementation is **not** a 15s window; it coalesces rapid calls. The user-observed effect is similar (one POST per quiet period), but the semantics differ.

**Implication:** Module A's `RemotePositionWriter` ships with a default throttle of 15s (matches EPUB). Audiobook side will inherit that. This is **a behavior change for audiobooks**, but in the safer direction — the current audiobook debounce will post on every settle of a long pause-resume sequence; a 15s throttle posts at most once per 15s. Document this in the contract; if regression testing shows a problem we revisit. The conflict-resolution logic (timestamp-newer check, isAtBeginning guard) stays in `AudiobookBookmarkBusinessLogic` because it's audiobook-specific and not part of the writer's responsibility.

### Deviation 7 — `TPPLastReadPositionSynchronizer.sync(...)` does NOT use `await` on a future-returning network call; it uses `await TPPAnnotations.syncReadingPosition(...)` async helper. It already takes an async path.

Reading `TPPLastReadPositionSynchronizer.swift:67-99`, the load + conflict-merge logic uses `await TPPAnnotations.syncReadingPosition(...)` and compares `deviceID == drmDeviceID && localLocation != nil || localLocation?.locationString == serverLocationString`. The merge rule is: **return server location only if it differs AND comes from a different device OR client has no local location**.

This is the EPUB conflict-resolution rule. It is **NOT** the rule the audiobook side uses (audiobook uses timestamp-newer-by-5s plus isAtBeginning guard). These rules are format-specific and stay format-specific. Module A's `PositionWriter.load(for:)` MUST NOT bake in a conflict-resolution rule; it returns the raw remote snapshot and the caller decides.

**Implication:** Tighten `PositionWriter.load(for:)` signature in the contract: "Returns the remote snapshot as-stored on the server. Caller is responsible for conflict resolution." Strip any "prefer newer" logic from `RemotePositionWriter`.

---

## 2. Contract refinements

### Updated module partition

| Module | Owner files (exclusive write) | Status |
|---|---|---|
| **A** — `PalaceReadingPosition` SPM | NEW SPM package files + **MIGRATE** `Palace/Platform/ReadingPosition.swift`, `PositionSyncService.swift`, `PositionSyncServiceProtocol.swift`, `CrossFormatMapping.swift` into the SPM | scope ↑ (5 file migration) |
| **B** — Audiobook position-write migration | MOD `Palace/Reader2/Bookmarks/AudiobookBookmarkBusinessLogic.swift`; DELETE `Palace/Audiobooks/LatestAudiobookLocation.swift`; DELETE `LatestAudiobookLocationTests` class block in `PalaceTests/Audiobook/AudiobookTimeEntryTests.swift` | scope ↑/= (different file than planned, equivalent net effort) |
| **C** — Reader2 + PDF position-write migration | MOD `Palace/Reader2/BusinessLogic/TPPLastReadPositionPoster.swift`, `TPPLastReadPositionSynchronizer.swift`; MOD `Palace/PDF/Model/TPPPDFDocumentMetadata.swift` (line 95 PDF position-write); MOD `Palace/Reader2/UI/TPPBaseReaderViewController.swift:92` (one-line edit) | scope = + PDF locked IN |
| **D** — Contract-snapshot tests | unchanged | scope = |

### Updated don't-touch (additions noted)

- `Palace/Audiobooks/Tracker/AudiobookDataManager.swift` — **MOVED TO DON'T-TOUCH.** It is NOT a position writer; touching it widens scope unnecessarily.
- `Palace/Audiobooks/Tracker/AudiobookTimeTracker.swift` — **MOVED TO DON'T-TOUCH.** Same reason.
- `PalaceTests/Audiobook/AudiobookDataManagerSyncTests.swift` — **MOVED TO DON'T-TOUCH.**
- `PalaceTests/Audiobooks/AudiobookEventsTests.swift` — **MOVED TO DON'T-TOUCH.** The syncQueue these tests touch is the time-tracker's, not the position-writer's; they survive untouched.

### Contract A — locked details

- SPM package layout matches `Palace/Packages/PalaceKeychain/` (iOS 16+, Package.swift v5.9).
- Public types: `PositionWriter` protocol, `RemotePositionWriter` final class (renamed from `CanonicalPositionWriter`), `PositionSnapshot` struct, `PositionWriterError` enum, `PositionNetworkAdapter` protocol.
- **Migrated public types** (formerly in `Palace/Platform/`): `ReadingPosition`, `ReadingFormat`, `PositionSyncService` actor (rename internal type if collides with `PositionSyncServiceProtocol` — keep both), `PositionSyncServiceProtocol`, `CrossFormatMapping`, `PositionSyncEvent`.
- Throttle window default: `15.0` seconds (`Duration.seconds(15)`), matching `TPPLastReadPositionPoster.throttlingInterval`.
- Concurrency model: `RemotePositionWriter` is a `final class` with serial `DispatchQueue` (matches `TPPLastReadPositionPoster` pattern), not an `actor` — iOS 16 actor + clock injection adds complexity for marginal benefit on a network-bound write path. `PositionSyncService` already-existing actor stays an actor.
- `PositionWriter.load(for:)` returns raw remote snapshot. Caller owns conflict-resolution.
- Dependencies: `PalaceLogging` (Logger), nothing else from project; **no dependency on `PalaceNetwork`** (the adapter protocol injects the network seam — keeps the SPM dep-free).

### Contract B — locked details

- Target file: `Palace/Reader2/Bookmarks/AudiobookBookmarkBusinessLogic.swift` (NOT `AudiobookDataManager.swift`).
- Inject `PositionWriter` via initializer with `RemotePositionWriter` default constructed lazily.
- `saveListeningPosition(at:completion:)` body: keep local-save-first; replace `debounce { syncListeningPositionToServer(...) }` with `Task { try? await positionWriter.save(snapshot) }` where snapshot encodes the audiobook locator string in `PositionSnapshot.payload`.
- Keep conflict-resolution (timestamp-newer + isAtBeginning) **in `AudiobookBookmarkBusinessLogic`** — these are audiobook-specific, not the writer's contract.
- Delete `Palace/Audiobooks/LatestAudiobookLocation.swift` (dead).
- Delete `LatestAudiobookLocationTests` class block (lines 94-141 of `PalaceTests/Audiobook/AudiobookTimeEntryTests.swift`).
- **NO edit to `AudiobookSessionManager.swift`. NO edit to `AudiobookLoader.swift` if Module A's default-constructed writer is used (recommended).**

### Contract C — locked details

- `TPPLastReadPositionPoster.swift`: replace `postQueuedReadPosition` body (line 80) with `try? await positionWriter.save(snapshot)`. Constructor takes new `positionWriter: PositionWriter` parameter with default-built instance. Throttle bookkeeping (`lastReadPositionUploadDate`, `queuedReadPosition`) moves to the writer; this class becomes a thin EPUB-locator-serializer plus a delegate to the writer.
- `TPPLastReadPositionSynchronizer.swift`: `syncReadPosition(...)` (line 67) load path calls `await positionWriter.load(for: book.identifier)`. Conflict-resolution logic (lines 86-91 — `deviceID == drmDeviceID && localLocation != nil || localLocation?.locationString == serverLocationString`) stays in this class. Net LOC: -10 (the load helper line goes; the merge stays).
- `TPPBaseReaderViewController.swift:92`: **one-line edit** — add `positionWriter: AppContainer.production().positionWriter` (or accept default-constructed). The class field name stays `lastReadPositionPoster`. Field line at 35 unchanged. Call sites at lines 316 and 581 (NOT 118/353/618 as the contract claimed — verified by grep) recompile unchanged.
- **PDF migration LOCKED IN:** `Palace/PDF/Model/TPPPDFDocumentMetadata.swift:95` — replace the bare `TPPAnnotations.postReadingPosition(...)` call with a `RemotePositionWriter.save(...)` via injection. PDF currently has NO throttle on writes, so migration is a behavior improvement (15s throttle inherited from the writer). The `canSync` check and local `bookRegistry.setLocation` (line 93) stay.
- Throttle window value LOCKED at 15.0 seconds.

### Contract D — locked details

- Scenario count: target **13** named scenarios (up from 11+).
  - `PositionWriterContractTests`: 6 scenarios (canonical writer call order: save-first-snapshot, save-within-throttle, throttle-elapsed, load-cache-miss, load-cache-hit, cancel-clears-state).
  - `AudiobookPositionAdapterContractTests`: 3 scenarios (audiobook-save delegates to writer, audiobook-save preserves isAtBeginning guard, audiobook-save preserves timestamp-newer race check).
  - `Reader2PositionAdapterContractTests`: 4 scenarios (poster-save serializes locator + delegates, synchronizer-sync server-newer returns remote, synchronizer-sync same-device returns nil, PDF-save delegates to writer).
- Snapshot directory structure: `PalaceTests/Contract/__Snapshots__/<TestClass>/<scenario>.json` (matches existing `BorrowReducerContractTests` pattern at `PalaceTests/Contract/__Snapshots__/BorrowReducerContractTests/`).

---

## 3. Disjointness check

After re-partition, files touched by each module:

| File | A | B | C | D |
|---|:-:|:-:|:-:|:-:|
| `Palace/Packages/PalaceReadingPosition/*` (NEW) | ✓ | | | |
| `Palace/Platform/ReadingPosition.swift` (move into SPM) | ✓ | | | |
| `Palace/Platform/PositionSyncService.swift` (move into SPM) | ✓ | | | |
| `Palace/Platform/PositionSyncServiceProtocol.swift` (move into SPM) | ✓ | | | |
| `Palace/Platform/CrossFormatMapping.swift` (move into SPM) | ✓ | | | |
| `Palace/Reader2/Bookmarks/AudiobookBookmarkBusinessLogic.swift` | | ✓ | | |
| `Palace/Audiobooks/LatestAudiobookLocation.swift` (DELETE) | | ✓ | | |
| `PalaceTests/Audiobook/AudiobookTimeEntryTests.swift` (partial delete) | | ✓ | | |
| `Palace/Reader2/BusinessLogic/TPPLastReadPositionPoster.swift` | | | ✓ | |
| `Palace/Reader2/BusinessLogic/TPPLastReadPositionSynchronizer.swift` | | | ✓ | |
| `Palace/PDF/Model/TPPPDFDocumentMetadata.swift` | | | ✓ | |
| `Palace/Reader2/UI/TPPBaseReaderViewController.swift` | | | ✓ | |
| `PalaceTests/Reader2/TPPLastReadPositionPosterTests.swift` | | | ✓ | |
| `PalaceTests/Reader2/TPPLastReadPositionSynchronizerTests.swift` | | | ✓ | |
| `PalaceTests/Contract/*` (NEW) | | | | ✓ |
| `Palace.xcodeproj/project.pbxproj` (SPM dep add) | ✓ | | | |

**No file overlap.** A's migration of `Palace/Platform/` types and B's `AudiobookBookmarkBusinessLogic.swift` edit are disjoint. C's `TPPBaseReaderViewController.swift` one-line edit may cause a merge race with A's pbxproj edit — recommend integrator merges A first, then B+C in parallel, then D.

`PalaceTests/Platform/{ReadingPositionTests,PositionSyncServiceTests,CrossFormatMappingTests}.swift` — these tests survive **unmodified**. Their `@testable import Palace` becomes `@testable import Palace` + `import PalaceReadingPosition` (a 1-line per-file edit). **Assign these one-line import edits to Module A** to keep them with the SPM migration.

---

## 4. Open questions / blockers

- **None blocking dispatch.** The 7 deviations are addressed in the contract refinements above.
- Module A's scope is larger than originally planned (migrates 5 existing Platform files into the SPM). This is unavoidable given Deviation 4. Time budget likely +30 min vs original A estimate (60-90 → 90-120 min).
- The behavior change of imposing a 15s throttle on audiobook writes (Deviation 6) needs a regression note for QA — the user-visible difference would be in resume-after-pause scenarios with rapid track-skip cycles. Document in the implementer transcript for Module B; QA can cover via simdrive replay.

---

## 5. Dispatch verdict

**OK to dispatch — all 4 contracts refined, no human decision required.**

Sequencing recommendation:
1. **Module A first**, alone (the SPM + Platform migration is the foundation). ~90-120 min.
2. **Modules B + C in parallel** after A's protocol surface is on disk (they only need `PositionWriter.swift` + `PositionSnapshot.swift` headers, not full impl). ~60-90 min.
3. **Module D after B + C** (needs production code to compile against spies). ~30-45 min.
4. **Integrator** runs verify-pr.sh + commits + opens PR. ~30-45 min.

Total: ~3.5-5 hr wallclock. The Platform migration in A widens the original estimate.

Mutation kill rate target on `RemotePositionWriter`: ≥80% (load-bearing throttle + cancel + cache logic). The existing `Palace/Platform/PositionSyncService.swift` actor will have its own mutation surface; reuse its existing test coverage as the baseline.
