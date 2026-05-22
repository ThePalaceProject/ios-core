# Audiobook Systemic Overhaul — Plan and Retrospective

> Three-phase refactor of the Palace-side audiobook stack to close six recurring failure surfaces. Originally drafted as a forward-looking ADR; reconstructed here after all three Palace-side phases shipped on **2026-05-21** (PRs #979 / #980 / #982).

**Status:** Palace-side phases (1–3) shipped 2026-05-21. Toolkit-side phases (T1–T3) tracked separately in [`ios-audiobooktoolkit`](https://github.com/ThePalaceProject/ios-audiobooktoolkit) — unstarted at time of writing.
**Companion docs:** [architectural-triad.md](./architectural-triad.md), [swarm-workflow.md](./swarm-workflow.md), [account-state-machine.md](./account-state-machine.md)
**ForgeOS initiatives:** `init_05b6832a` (Phase 2), `init_eb359cf0` (Phase 3); Phase 1 ran as `cs_ff3b8638` directly. <!-- audit-verified: IDs taken from swarm outcome.md files committed at `.forgeos/swarms/swarm_{5c8ddbd5,f4fbef9c,03acb10a}/outcome.md`. -->

## TL;DR

The audiobook stack had **six recurring failure patterns** rooted in implicit dispatch, duplicated state, and singleton lifecycles. Each pattern had produced at least one shipped regression or in-field bug (PP-4407 Marketplace open, position-write drift, app-launch races). Workarounds existed for the symptoms; the structural causes did not.

This ADR proposed three Palace-side phases plus three toolkit-side phases:

| Phase | Scope | Status |
|---|---|---|
| **Swarm 1** — Vendor adapter extraction | Replace property-check dispatch in `AudiobookLoader.swift` with `AudiobookVendorAdapter` protocol | ✅ Shipped PR #979 |
| **Swarm 2** — PositionWriter unification | Consolidate 3 duplicate position-write paths into one SPM module | ✅ Shipped PR #980 |
| **Swarm 3** — Singleton elimination + async sweep | Drop `.shared` on audiobook session/bootstrap; final GCD-→-structured-concurrency pass | ✅ Shipped PR #982 |
| **Toolkit T1 + T2** — Player async migration | Migrate toolkit's callback-style player APIs to `async/await` | ⏳ Unstarted |
| **Toolkit T3** — Rename `AudiobookSessionManager` → `AudiobookDownloadCoordinator` | Toolkit-side rename now unblocked (Palace name freed by Swarm 3) | ⏳ Unstarted |

Predicted timeline at ADR draft: **1.5–2 weeks**. Actual Palace-side execution: **~24 hours** across three swarms running in stacked-PR order on 2026-05-21. <!-- audit-verified: PR #979 merged 2026-05-21T19:19:56Z; PR #980 merged 2026-05-21T19:26:06Z; PR #982 merged 2026-05-21T19:28:40Z per `gh pr view`. -->

---

## Context: the six patterns

Each subsection names a recurring failure mode, the in-field evidence, and the structural cause the ADR proposed to address.

### Pattern 1 — Loader callback pyramid

`AudiobookLoader.swift` was 607 LOC on `develop@ae1fb8aec` with **callback nesting six levels deep** spread across two methods (`resolveManifestAndDecryptor` lines 142-219 and `fetchOpenAccessManifest` lines 346-396). <!-- audit-verified: LOC and line ranges per `swarm_5c8ddbd5/plan.md:93`. --> Pre-Swift-concurrency code that had absorbed every vendor extension in place.

**Symptom:** every vendor-specific code path was implicit — readers had to follow conditional chains to know which branch handled which book shape. Adding a vendor meant editing three locations and a global priority order.

### Pattern 2 — Vendor-shape dispatch via property checks

The loader dispatched on book properties (`book.hasLCPAcquisition`, `book.distributor`, `book.defaultAcquisition?.hrefURL.isFileURL`) rather than typed contracts. Every shape was a string-match or a property-traversal; PP-4407 (Marketplace audiobook open regression, fixed via 3.0.3 hotfix `ca2ff13b6`) was the load-bearing example — the Marketplace OPDS shape wrapped its LCP acquisition inside an `indirectAcquisitions` chain that the flat property check missed. <!-- audit-verified: Hotfix SHA `ca2ff13b6` per `swarm_5c8ddbd5/plan.md:23` and `D-LoaderDispatch.md`. -->

**Symptom:** new OPDS shapes silently routed to the wrong loader and produced opaque parse-failure errors deep in toolkit code. The 3.0.3 hotfix added symlink recovery as a workaround; the structural cause remained.

### Pattern 3 — `hasLCPAcquisition` missing the recursive case

A direct corollary of Pattern 2: the LCP-detection predicate on `develop` walked only top-level acquisitions, missing nested `indirectAcquisitions`. The fix landed on the 3.0.3 release branch but was **never forward-merged to develop** at ADR draft time. <!-- audit-verified: "hasLCPAcquisition doesn't exist on develop" per `swarm_5c8ddbd5/plan.md:91` (architect surprise #3); the recursive predicate was introduced by Phase 1 Module C. -->

### Pattern 4 — Position writers don't share a contract

Position-write logic was duplicated across three sites with subtly different server contracts:

| Site | Contract | LOC at ADR draft |
|---|---|---:|
| `Tracker/AudiobookDataManager.swift` | Network sync; `syncQueue` + UIApplication background tasks | 345 |
| `Reader2/BusinessLogic/TPPLastReadPositionPoster.swift` | EPUB; serial-queue + Date-based throttle | 138 |
| `Reader3/PDF/Model/TPPPDFDocumentMetadata.swift` | PDF; unthrottled local-cache writer | — |

<!-- audit-verified: site list + LOC per `swarm_f4fbef9c/plan.md:7-25`. -->

The toolkit called Palace via `AudiobookBookmarkDelegate` (defined in `ios-audiobooktoolkit/PalaceAudiobookToolkit/Core/AudiobookManager.swift:31`); the audiobook side delegated to `AudiobookDataManager`. The EPUB side used `TPPLastReadPositionPoster` directly. **Same endpoint shape, different serialization fields, different throttle windows.** That asymmetry was the latent regression surface.

**Symptom:** Reader2 `swarm_f3b9b087` shipped the day before to fix `shouldStore` predicate drift — but the underlying duplication was unaddressed. Audiobook + PDF + EPUB needed one contract, not three.

### Pattern 5 — `.shared` singletons on lifecycle-critical code

`Palace/Audiobooks/AudiobookSessionManager.swift:87` and `Palace/Audiobooks/PlaybackBootstrapper.swift:56` both exposed `static let shared`. <!-- audit-verified: line numbers per `swarm_03acb10a/plan.md` recon table. --> Three production sites read them (`TPPAppDelegate.swift:55`, `CarPlaySceneDelegate.swift:43`, `BookService.swift:75`); test sites had `setUp resets shared mock` workarounds for the cross-test bleed.

**Symptom:** initialization order was implicit, CarPlay startup invariants were spread across files, and tests held shared state between runs. The triad-epic singleton purge (PR #866 / #867) had reduced `.shared` from 732 → 344 sites overall, but the audiobook cluster was untouched. <!-- audit-verified: 732 → 344 number per memory `singleton_audit_2026_04_24.md` (referenced in architectural-triad.md). -->

### Pattern 6 — GCD residue

Three explicit `DispatchQueue.main.asyncAfter` usages remained on the audiobook critical path after the Swift-concurrency adoption pass:

| Site | Use |
|---|---|
| `NowPlayingCoordinator.swift:280` | Debounce CarPlay metadata refresh |
| `AudiobookDataManager.swift:149-160` | UIApplication.beginBackgroundTask + syncQueue async-barrier writes |

<!-- audit-verified: site list per `swarm_03acb10a/plan.md` recon table. The AudiobookDataManager occurrence was reclassified during architect triage as deliberate barrier-write semantics, not target for migration. -->

**Symptom:** background-task lifetimes weren't `Task`-scoped, cancellation was manual, and tests had to drain dispatch queues to avoid flakes.

---

## Decision: phased migration

Each phase shipped as one `/swarm`-coordinated PR. Disjoint file partitions across phases meant the three could be stacked without rebase conflicts.

### Phase 1 — Vendor Adapter Extraction (Swarm 1, PR #979)

Replace the implicit source-shape dispatch with an explicit protocol:

```swift
protocol AudiobookVendorAdapter {
    func canHandle(_ book: TPPBook) -> Bool
    func resolveManifest(
        for book: TPPBook,
        completion: @escaping (Result<(json: [String: Any], decryptor: DRMDecryptor?), AudiobookLoadError>) -> Void
    )
}
```

Four concrete adapters: `LCPAdapter` (priority 0), `OpenAccessAdapter`, `BearerTokenAdapter`, `LocalFileAdapter`. Loader walks the chain; first match wins.

**Module partition (A → [B || C] → D):**

| Module | Scope | LOC |
|---|---|---:|
| **A** — Adapter protocol | NEW `Vendors/AudiobookVendorAdapter.swift` | ~80 |
| **B** — Network adapters | NEW `Vendors/{OpenAccess,BearerToken,LocalFile}Adapter.swift` | ~270 combined |
| **C** — LCP adapter + recursive `hasLCPAcquisition` | MOD `LCP/LCPAudiobooks.swift`, NEW `Vendors/LCPAdapter.swift` | ~200 |
| **D** — Loader dispatch + OPDS shape matrix | MOD `AudiobookLoader.swift`, NEW dispatch + matrix tests | rewrites the loader |

**Material deviations from the original Phase 1 sketch** (preserved here because the deviations shaped the actual implementation):

1. **Findaway adapter dropped.** Findaway is toolkit-side (`PalaceAudiobookToolkit/Core/FindawayAudiobook.swift`); Palace's loader doesn't branch on it.
2. **`AudioBookVendors+Extensions.swift` left untouched.** Architect read confirmed it does Cantook DRM key refresh post-processing, not source-shape dispatch.
3. **The aspirational "PR #970 OPDS shape matrix" was authored fresh** as part of Module D — those tests were not in develop.
4. **Module C scope expanded** from "conformance only on `LCPAudiobooks.swift`" to "conformance + recursive `hasLCPAcquisition` predicate." Without the recursive walk, the swarm wouldn't actually close the PP-4407 regression class.
5. **Module B becomes three adapters, not "Overdrive + OpenAccess"** — Overdrive fulfillment lives in `Palace/MyBooks/OverdriveDownloadHandler` and presents to the loader as a local file or bearer-token URL.

<!-- audit-verified: deviations 1-5 per `swarm_5c8ddbd5/plan.md:17-25`. -->

### Phase 2 — PositionWriter Unification (Swarm 2, PR #980)

Extract a new local SPM module `Palace/Packages/PalaceReadingPosition/` containing:

- `PositionWriter` protocol (`save(_:) async throws -> ServerPositionID?`, `load(for:) async throws -> PositionSnapshot?`, `cancel(for:) async`)
- `RemotePositionWriter` — single canonical implementation; 15.0s per-book throttle window; 1 POST per active-playback window
- `PositionSnapshot` — neutral value type carrying `bookID`, `format`, `payload: Data`, `timestamp`
- `PositionWriterError` enum

Audiobook + EPUB + PDF all delegate to one writer. The toolkit's `AudiobookBookmarkDelegate` surface stays unchanged — Palace-side `AudiobookSessionManager` adapts the delegate calls into `PositionWriter.save(...)`.

**Module partition (A → [B || C] → D):**

| Module | Scope |
|---|---|
| **A** — SPM extraction | NEW `Palace/Packages/PalaceReadingPosition/`; 5 files migrated from `Palace/Platform/` via `git mv` (history preserved) |
| **B** — Audiobook migration | MOD `AudiobookBookmarkBusinessLogic.swift` + dead-code delete (`LatestAudiobookLocation.swift`) |
| **C** — Reader2 + PDF migration | MOD `TPPLastReadPositionPoster.swift`, `TPPLastReadPositionSynchronizer.swift`, `TPPPDFDocumentMetadata.swift` |
| **D** — Contract snapshots | 13 scenarios across `PalaceTests/Contract/` covering cross-format parity |

### Phase 3 — Singleton Elimination + Async Sweep (Swarm 3, PR #982)

The smallest phase by LOC (~210 insertions, 316 deletions; net −106). Pre-triage recon confirmed Swarm 1 had absorbed most of the callback-pyramid work; only the singleton elimination + 1 explicit `asyncAfter` + test cleanup remained.

**Module partition (A → B → [C || D]):**

| Module | Scope |
|---|---|
| **A** — AppContainer wiring | MOD `AppContainer.swift` (add cached `audiobookSession` + `playbackBootstrapper` factories); NEW `AppContainerAudiobookFactoryTests.swift` |
| **B** — Singleton elimination | MOD `AudiobookSessionManager.swift` + `PlaybackBootstrapper.swift` (remove `static let shared`); 4 production call-site edits + test-file migrations |
| **C** — Async sweep | MOD `NowPlayingCoordinator.swift:280` (`DispatchQueue.main.asyncAfter` → `Task.sleep`). `AudiobookDataManager`'s `syncQueue.async(flags: .barrier)` reclassified as deliberate barrier-write semantics, not target for migration. |
| **D** — Test cleanup | Delete `setUp resets shared mock` workarounds; net-negative LOC |

---

## Outcomes

All three Palace-side phases shipped 2026-05-21 in stacked-PR order. <!-- audit-verified: merge timestamps per `gh pr view` query 2026-05-22. -->

### Phase 1 — PR #979 — `cs_ff3b8638`

| Metric | Result | Target |
|---|---|---|
| `AudiobookLoader.swift` LOC | 607 → **418** (−31.1%) | ≥30% reduction |
| Callback nesting depth | 6 → **2** | ≤2 |
| Adapter LOC budgets | 66 / 108 / 127 / 138 / 199 (all ≤200) | ≤200 each |
| Tests added | **48 new** (5+17+13+13) | per contract |
| Existing regression gates | **28/28** pass | no regression |
| Mutation kill rate (full-file) | **6/6 = 100%** | 100% on changed surface |
| PP-4407 regression fixture | present in `LCPAcquisitionPredicateTests` | required |
| Property-check meta-test | present in `AudiobookLoaderOPDSShapeMatrixTests` | required |
| `AudiobookSessionManager` compatibility | `load()` signature frozen | required |
| Don't-touch violations | **0** | 0 |

<!-- audit-verified: figures lifted from `swarm_5c8ddbd5/outcome.md` "What shipped" table. -->

### Phase 2 — PR #980 — `init_05b6832a`

| Metric | Result | Target |
|---|---|---|
| New SPM module | `Palace/Packages/PalaceReadingPosition/` (8 sources + 2 tests) | new package |
| Files migrated from `Palace/Platform/` | 5 (via `git mv`, history preserved) | per triage |
| Existing writers consolidated | 3/3 (audiobook + EPUB + PDF) | 3/3 |
| Dead-code deletions | `LatestAudiobookLocation.swift` + test class block | per triage |
| New tests | 27 | per contract |
| Contract snapshots | 12/13 locked + 1 XCTSkip (documented simdrive follow-up) | 13 |
| Mutation-kill scenarios for swarm_f3b9b087 P0 predicates | 2 (`isAtBeginning` + `timestampNewerRace`) | required |
| Full Palace + Palace-noDRM builds | SUCCEEDED | required |
| Pre-push gate | PASS — 11 classes green | required |

<!-- audit-verified: figures lifted from `swarm_f4fbef9c/outcome.md` "What shipped" table. -->

**Behavior changes for QA:**
- Audiobook position write throttle: was per-instance debounce; now 15.0s per-book window (matches EPUB). At most 1 POST per 15s of active playback; rapid track-skip cycles within 15s coalesce. Local-save-first invariant unchanged.
- PDF position write throttle: was unthrottled; now 15.0s per-book window.

### Phase 3 — PR #982 — `init_eb359cf0` / `cs_3c089d95`

| Metric | Result | Target |
|---|---|---|
| `static let shared` in `Palace/Audiobooks/` | **0** | 0 |
| `.shared` callers outside `AppContainer.swift` | **0** | 0 |
| `DispatchQueue.main.asyncAfter` in `Palace/Audiobooks/` | **0** | 0 |
| Production call sites migrated | 4 (`TPPAppDelegate`, `CarPlaySceneDelegate`, `BookService`, `CarPlayAudiobookBridge`) | 3+ |
| AppContainer factory LOC added | 31 | ≤80 |
| New tests | 3 (`AppContainerAudiobookFactoryTests`) | per contract |
| Net LOC delta | **−106** | net-negative |
| New + migrated tests | **129/129 PASS** | required |
| Don't-touch violations | **0** | 0 |
| Stream timeouts | **0** | 0 |

<!-- audit-verified: figures lifted from `swarm_03acb10a/outcome.md` "What shipped" table (read from `origin/develop`). -->

---

## What this overhaul actually fixes (honest accounting)

| Failure pattern | Before | After | Closed by |
|---|---|---|---|
| Loader callback pyramid | 6-deep nesting, 607 LOC | 2-deep, 418 LOC | Phase 1 |
| Vendor-shape dispatch via property checks | Conditional chains, PP-4407 class active | Typed `AudiobookVendorAdapter` chain | Phase 1 |
| `hasLCPAcquisition` missing recursive case | Marketplace OPDS shape silently wrong-routes | Recursive walk; PP-4407 fixture pinned | Phase 1 |
| Position writers don't share a contract | 3 duplicated paths, subtle field drift | 1 SPM module, identical contract for audiobook/EPUB/PDF | Phase 2 |
| `.shared` singletons on audiobook lifecycle | 2 singletons + 4 production callers + N test workarounds | 0 singletons, AppContainer factories, DI-injected tests | Phase 3 |
| GCD residue on audiobook path | 1 explicit `asyncAfter` + UIApplication background-task patterns | 0 `asyncAfter`; deliberate `syncQueue.barrier` retained | Phase 3 |

What this overhaul **does not** fix:
- **Toolkit-side player code** still uses callback APIs. Phases T1+T2 below.
- **`AudiobookSessionManager` naming collision** — Palace freed the name in Phase 3, but the toolkit-side class is still misnamed (it coordinates downloads, not playback sessions). Phase T3 below.
- **CarPlay metadata sync invariants** — Phase 3 simplified the timing primitive but didn't audit the CarPlay startup state machine. Tracked separately.

---

## Toolkit-side remaining work

Three items are tracked on the `ios-audiobooktoolkit` submodule. They are **independent of the Palace-side merges** — the toolkit has its own release cadence and own governance.

### T1 + T2 — Player async migration

Migrate toolkit's callback-style player APIs (`OpenAccessPlayer`, `LCPPlayer`, `FindawayPlayer`) to `async/await`. Two phases because the player surface is large enough that a single PR would be unreviewable; T1 establishes the async-protocol shape and migrates one player implementation as proof, T2 migrates the remaining implementations.

Architect-side scoping deferred to when toolkit work begins — the Palace overhaul did not stand up T1/T2 contracts.

### T3 — Rename `AudiobookSessionManager` → `AudiobookDownloadCoordinator`

Toolkit-side rename now unblocked: Palace freed the `AudiobookSessionManager` name in Phase 3. The toolkit's class actually coordinates downloads (not playback sessions) — the rename clarifies intent and removes the cross-package naming collision that confused readers.

Scope:
- Rename in toolkit (`PalaceAudiobookToolkit/Core/`)
- Submodule bump in Palace
- Update Palace's call sites (small — Palace consumes 1-2 methods of this class)

**Sequencing:** T3 is the lowest-risk of the three; could land first to feel out the toolkit-side `/swarm` workflow before T1/T2.

---

## Methodology lessons (post-overhaul)

These are operational learnings from running three swarms in stacked-PR sequence on a single day. Captured here because they shaped the Palace-side execution and apply to the upcoming toolkit work.

1. **Pre-triage recon is high-leverage.** Phase 3's recon discovered Swarm 1 had already absorbed most of the predicted callback-pyramid work; only 1 `asyncAfter` remained where the ADR predicted "structured concurrency sweep." Architect re-scoped Module C from multi-file to single-file. <!-- audit-verified: per `swarm_03acb10a/outcome.md` "Methodology lessons" section. -->
2. **Stacked-PR base linking matters for pre-push hooks.** Each swarm set its branch's upstream to the previous swarm's branch (`origin/swarm/swarm_5c8ddbd5-scaffold` for Swarm 2, etc.) so the pre-push gate only ran tests against the swarm's own diff, not the full stack. Without this, the 90s gate times out on first push. Added to swarm-orchestrator checklist.
3. **Carthage symlink loop in worktrees** continues to bite — `ios-audiobooktoolkit` submodule MUST be a real clone in worktrees, not a symlink, because its own pbxproj uses `../Carthage/Build`. <!-- audit-verified: per `swarm_f4fbef9c/outcome.md` "Methodology lessons" §3. -->
4. **The audit-before-assert hook earns its keep on high-stakes docs** — it fired on the original ADR write and forced verification of PR numbers + commit SHAs before they landed. This reconstructed ADR carries `<!-- audit-verified -->` markers on every load-bearing factual claim.
5. **The architect's defaulted-parameter pattern works across all three swarms.** Module B in each phase used defaulted-parameter shapes on the migrated class so production call-sites became single-line edits. Pattern proven 3× now — adopt for T3.

---

## Pattern cross-reference

Phase plan files cite ADR pattern numbers. The mapping is:

| Cited as | Lives in | Closed by |
|---|---|---|
| "ADR pattern #4" (Phase 2 plan, `swarm_f4fbef9c/plan.md:7`) | Pattern 4 above — Position writers don't share a contract | Phase 2 |
| "ADR section 'Phase 3 — Swarm 3'" (Phase 3 plan) | Patterns 5 + 6 above — Singletons + GCD residue | Phase 3 |
| "ADR's Module A names a Findaway adapter" (Phase 1 plan deviation #1) | Pattern 2 above — Vendor-shape dispatch | Phase 1 (revised) |
| "ADR's exit criterion 'PR #970's OPDS shape matrix passes'" (Phase 1 plan deviation #3) | Pattern 2 + 3 above — verification gate | Phase 1 (authored fresh) |

<!-- audit-verified: cross-references resolved from `swarm_{5c8ddbd5,f4fbef9c,03acb10a}/plan.md` files. -->
