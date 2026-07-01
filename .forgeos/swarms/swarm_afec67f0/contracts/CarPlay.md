# Contract — CarPlay (swarm_afec67f0)

Swift 6 `targeted` Phase A.5 Chunk 2. **Fix by ISOLATION only. No behavior
changes.** Line numbers are the A.4 snapshot — **locate by symbol** and verify.

## Files IN scope (yours, exclusively)
- `Palace/CarPlay/CarPlayImageProvider.swift`
- `Palace/CarPlay/CarPlayTemplateManager.swift`

## OFF-LIMITS
Everything else. Do not modify Accounts / AppInfrastructure / OPDS / Reader2 /
Book/Models files.

## Global rules
- NEVER `nonisolated(unsafe)`. NO **bare** `@unchecked Sendable`. **Documented**
  `@unchecked Sendable` carrier with a stated invariant IS allowed (mirror
  `ImageCompletionBox`).
- Do NOT run verify-pr / palace_mutate / xcresult (no DRM build).

---

## Site 1 — `CarPlayImageProvider.swift` ~67: capture of `completion`
**Warning:** `capture of 'completion'` — in the `image(for:completion:)`-style
method, `Task { … await MainActor.run { completion(processed) } }` captures the
non-Sendable `completion` closure into the `@Sendable` `Task` closure.

**Fix (isolation):** **mirror `ImageCompletionBox`**
(`Palace/Utilities/ImageCache/ImageLoaderImpl.swift:11`). Wrap `completion` in a
`private final class` box `@unchecked Sendable` before the `Task`, capture the
box, and call `box.call(processed)` inside the final `MainActor.run`. Invariant
comment: the boxed closure is only ever invoked inside `MainActor.run`, never
off-main, never concurrently. Preserve the cache-set ordering
(`imageLoader.set(processed, …)` before completion) and the early-return
cached / existing-image paths exactly. **Behavior risk:** none.

---

## Site 2 — `CarPlayTemplateManager.swift` ~96 (deinit) — ⚠️ HIGHEST RISK
**Warning:** `CPNowPlayingTemplate.remove(_:)` is `@MainActor`-isolated but is
called from the nonisolated `deinit` (`nowPlayingTemplate.remove(self)`). The
existing code has a comment already acknowledging this and leaving it as-is.

**Constraints (hard):**
- `MainActor.assumeIsolated` is **BANNED here** — a `deinit` is not guaranteed to
  run on the main thread, so `assumeIsolated` risks a `fatalError`.
- `nonisolated(unsafe)` is banned.
- Capturing `self` in an escaping `Task` from `deinit` is a **resurrection
  hazard** (self is deallocating) — do NOT do it.

**Preferred fix (isolation, no behavior change) — a MainActor hop that does NOT
capture `self`:** determine what identity `remove(_:)` actually needs. It
unregisters an observer object. Two acceptable resolutions, in priority order:

1. **If a self-capture-free hop is achievable** — e.g. the observer can be
   referenced without extending `self`'s lifetime (a separately-stored observer
   token / helper object that is NOT `self`), hop it:
   ```swift
   if hasConfiguredNowPlaying, let template = nowPlayingTemplate {
     Task { @MainActor in template.remove(observerToken) }
   }
   ```
   Only valid if `observerToken` is a stored property distinct from `self` and
   its lifetime is independent of `self`'s deinit.

2. **If `CPNowPlayingTemplate` holds its observers weakly** (verify against the
   CarPlay framework docs / current registration in `configureNowPlayingTemplate…`):
   the explicit deinit removal is defensive and the weak reference auto-nils on
   dealloc. In that case the isolation-clean resolution is to move the removal to
   a `@MainActor` teardown that runs BEFORE deinit (e.g. on CarPlay
   disconnect / `interfaceControllerDidDisconnect`) so deinit no longer performs
   a main-actor call. **This is a structural move — treat it as a behavior
   question and flag it for integration review** (does teardown always fire
   before dealloc?).

**If NEITHER (1) nor (2) yields a behavior-preserving, self-capture-free,
assumeIsolated-free fix, STOP and file a scope-deferral** (per CLAUDE.md
scope-deferral protocol) rather than shipping an unsafe hop. Propose:
- (a) extend this pass with budget to move removal into a MainActor teardown, or
- (b) accept the reduction; defer CarPlayTemplateManager:96 to the CarPlay
  critical-path slice the existing comment already references.

Do NOT weaken the constraint to land the diff.

---

## Deliverable (paste in your report — NO mutation/xcresult)
Site 1: file:symbol + warning, the `ImageCompletionBox`-mirror fix, behavior risk
(none). Site 2: state which resolution path (1 / 2 / scope-deferral) you took and
WHY, the observer-lifetime / weak-observer evidence, and any behavior-review flag.
Confirm you touched ONLY the 2 files above.
