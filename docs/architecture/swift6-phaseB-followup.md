<!-- audit-verified -->
# Swift 6 Phase B — follow-up map (post Wave 1)

**Status as of Wave 1 (PR #1167):** `complete`-mode distinct app-target concurrency
warnings **738 → 473** (265 cleared), build green. This doc maps the remaining 473 so
the next waves and the critical-path PRs are dispatchable without re-deriving the
analysis. Companion: `app-target-swift6-modernization-plan.md` (phase ladder),
`swift6-modernization-handoff-2026-07-02.md` (env + gotchas).

Measurement: build the DRM `Palace` scheme with `SWIFT_STRICT_CONCURRENCY=complete`
(`ruby scripts/set_strict_concurrency.rb complete`) and grep the log for concurrency
warnings — see the handoff doc §1 for the exact grep. Revert with
`set_strict_concurrency.rb targeted` before committing (Wave 1 did NOT flip the level).

## 1. Residual by module (473 distinct)

| Module | Residual | Track |
|---|---|---|
| MyBooks | 95 | **critical-path** — own rigorous PR (architect+SoD) |
| Reader2 | 79 | structural clusters (reader-VC / TTS / DRM-cert) |
| SignInLogic | 62 | **critical-path** — own rigorous PR |
| ErrorHandling | 47 | `TPPAlertUtils` cross-module `@MainActor` pass |
| Audiobooks | 39 | **critical-path** — own rigorous PR (toolkit fragile) |
| AppInfrastructure | 37 | DI-root global state (AppContainer / Store) |
| Book | 31 | `TPPBookRegistry`/`BookRegistryStore` mutation core |
| Utilities | 16 | `TPPBackgroundExecutor` ObjC lifecycle; VoiceOver timing |
| Accounts | 14 | `AccountsManager` load-timing paths |
| Samples/PDF/CarPlay/Notifications/Settings/Network/OPDS2/CatalogUI | ~53 | mixed; several tied to shared types below |

Critical-path subtotal (MyBooks + SignInLogic + Audiobooks) = **196** — these must NOT
be blind-swarmed; each is money/access and gets architect + SoD + tests + mutation.

## 2. The 4 shared-type decisions that unblock the most (~104 warning-lines)

Multiple Wave-1 agents independently converged on these. Deciding each one clears
warnings across *many* modules at once — do these FIRST, before the per-module waves,
because a per-line fix in a consumer is wasted if the shared type later becomes Sendable.

1. **`TPPBookRegistry` / `TPPBookRegistryProvider` (~42 lines)** — the book-state
   single-source-of-truth. Non-Sendable stateful facade (`var state`, `BoolWithDelay`);
   `BookRegistryStore` mutation core is queue-synchronized. Decision: make the store a
   documented lock/queue-backed `@unchecked Sendable` and the provider protocol
   `Sendable`, OR isolate to `@MainActor`. Touches Book, MyBooks, CatalogUI, Accounts.
   **Critical-path-adjacent — rigorous, not swarm.**
2. **`AccountsManager` (~30 lines)** — known concurrency/test-pollution hazard (memory).
   Background `loadCatalogs` `Task.detached` + account-switch paths capture `self`.
   Decision: isolate-at-site (snapshot inside `MainActor.run`) where possible; a
   type-level `@unchecked Sendable` needs a deliberate mutable-state audit of
   `accountSets`/`accountByUUID`/loading queues. Touches Accounts, AppInfrastructure,
   TriageBotFactory. **Rigorous — do not blind-fix.**
3. **Readium `Publication` (~24 lines)** — non-Sendable Readium type crossing task
   boundaries in Reader2 (`EPUBSearchViewModel`, `ReaderModule`, `ReaderService`) and
   PDF. Decision: module-wide `@preconcurrency import ReadiumShared/ReadiumNavigator`
   policy, or wait on a Readium-side Sendable audit. This is upstream — likely
   `@preconcurrency` is the honest ceiling until Readium annotates.
4. **`Account` (~8 lines)** — large `@objcMembers final class`; `awaitReady()` sends it
   across isolation in `UnifiedOPDSService`/`OPDSFeedService`. Decision: audit for a
   documented `@unchecked Sendable` (mostly config + lock-guarded logo/auth state) vs.
   snapshotting the needed fields. Touches OPDS2, Accounts, SignInLogic.

`Store.Environment` (AppInfrastructure `Store.swift:72`) is a 5th, smaller one: a
`<Environment: Sendable>` constraint ripples to every ViewModel `Store` instantiation —
mechanical but wide; do it as its own atomic change.

## 3. Recommended sequencing

1. **Shared-type decisions first** (§2, items 1–4) — each its own rigorous PR
   (1 & 2 & 4 are critical-path-adjacent). Re-measure after each; expect large drops.
2. **Critical-path module PRs** — MyBooks, SignInLogic, Audiobooks (architect + SoD +
   tests + mutation per the CLAUDE.md rigor bar). Partly unblocked by step 1.
3. **Structural-cluster waves** — Reader2 reader-VC/TTS isolation; ErrorHandling
   `TPPAlertUtils` `@MainActor` cross-module pass; AppInfrastructure DI-root. Each is a
   coherent per-subsystem `@MainActor`/Sendable decision, buildable-verified.
4. **Re-measure → 0**, then Phase C (`SWIFT_VERSION 6.0`) per the plan doc.

## 4. Deferred specifics worth not re-deriving

- `MainActor.assumeIsolated`-in-`deinit` is BANNED (deinit not guaranteed on-main). One
  such Wave-1 fix (`BundledHTMLViewController`) was reverted; its warning is deferred.
- `TPPAlertUtils` (ErrorHandling, 47) carries load-bearing CA-commit-race / transition
  timing fixes (fe741015, HelpSpot 17716) — its ~40 mixed-isolation callers make a naive
  `@MainActor` unsafe; needs a buildable cross-module pass, not annotate-only.
- `TPPBackgroundExecutor` (Utilities) — ObjC background-task lifecycle captures a
  by-ref `bgTask` across `@Sendable` closures; needs a lifecycle restructure.
- A few Wave-1 `@Sendable`/`Sendable` additions redistribute warnings INTO deferred
  critical-path modules (MyBooks 84→95) — harmless under `SWIFT_VERSION=5.0`, resolved
  in those modules' own passes.
