# Contract — Reader2 (swarm_afec67f0)

Swift 6 `targeted` Phase A.5 Chunk 2. **Fix by ISOLATION only. No behavior
changes.** Line numbers are the A.4 snapshot — **locate by symbol** and verify.

## Files IN scope (yours, exclusively)
- `Palace/Reader2/BusinessLogic/TPPReaderBookmarksBusinessLogic.swift`
- `Palace/Reader2/Bookmarks/AudiobookBookmarkBusinessLogic.swift`
- `Palace/Reader2/UI/TPPEPUBViewController.swift`

## OFF-LIMITS
`Palace/Reader2/Bookmarks/TPPReadiumBookmark.swift` — do NOT make it Sendable and
do NOT edit it (see Decision 3). All Book/Models, Accounts, AppInfrastructure,
CarPlay, OPDS files.

## Global rules
- NEVER `nonisolated(unsafe)`. NO **bare** `@unchecked Sendable`. **Documented**
  `@unchecked Sendable` carrier with a stated invariant IS allowed (mirror
  `ImageCompletionBox`).
- Do NOT run verify-pr / palace_mutate / xcresult (no DRM build).

---

## CASCADE DECISION 3 — `TPPReadiumBookmark` → do NOT make Sendable; carrier at site
`TPPReadiumBookmark` (`@objcMembers final class … : NSObject`) has 10 genuinely
mutable `var` properties AND is mutated across a concurrency boundary
(`bookmark.annotationId = response?.serverId` in `TPPAnnotations.postBookmark`'s
completion, `TPPReaderBookmarksBusinessLogic.swift:158`) while instances also
live in the `bookmarks` array. It is real shared mutable state — a type-level
`@unchecked Sendable` would waive a genuine race and ripple `Sendable` onto every
bookmark call site. **Do NOT touch TPPReadiumBookmark.swift.**

## Site 1 — `TPPReaderBookmarksBusinessLogic.swift` ~144/151: capture of `bookmark`
**Warning:** in `postBookmark(_:)`, the `Task { [weak self] … }` closure captures
`bookmark` (`TPPReadiumBookmark`, non-Sendable); the two
`await MainActor.run { self.bookRegistry.add(bookmark, forIdentifier: …) }` blocks
(at ~144 local-only fallback and ~151 sync-not-granted fallback) trip the capture
diagnostic.

**Fix (isolation):** **mirror `ImageCompletionBox`** — wrap `bookmark` in a
`private final class` box `@unchecked Sendable` created before the `Task`, capture
the box, and reference `box.bookmark` inside the `MainActor.run` blocks (and the
`TPPAnnotations.postBookmark` completion at ~156–159). Invariant comment:
> the boxed `TPPReadiumBookmark` is only read / added-to-registry / mutated
> (`annotationId`) on the main actor inside the `MainActor.run` and
> annotation-completion blocks — never concurrently.

**Verify** where `TPPAnnotations.postBookmark`'s completion runs; if it is NOT
guaranteed main-actor, keep the `bookmark.annotationId = …; self.bookRegistry.add`
side effects on the main actor exactly as the surrounding code already funnels
them (do not change threading). Preserve all three fallback branches
(no-currentAccount immediate add, awaitReady-failure local-only add,
sync-not-granted local-only add) and their ordering. **Behavior risk:** none if
the main-actor confinement of the annotationId mutation is preserved; if you find
the completion runs off-main today, note it and preserve current behavior (do not
"fix" threading in this pass).

---

## Site 2 — `AudiobookBookmarkBusinessLogic.swift` ~193/198: capture of `completion`
**Warning:** in `saveBookmark(at:completion:)`, the `debounce { Task { [weak self]
… } }` body's `defer` and error path call
`DispatchQueue.main.async { completion?(updatedPosition) }` /
`DispatchQueue.main.async { completion?(nil) }` — the non-Sendable `completion`
closure is captured in the `@Sendable` `Task` closure.

**Fix (isolation):** **mirror `ImageCompletionBox`** — wrap `completion` in a
`private final class` box `@unchecked Sendable` before entering the `Task`,
capture the box, and call `box.call?(...)` inside the two `DispatchQueue.main.async`
blocks. Invariant: the boxed completion is only ever invoked on the main queue.
Preserve the `debounce` wrapper, the `defer` block ordering (registry
`addOrReplaceGenericBookmark` then main-async completion), the encode-failure
early return, and the `annotationsManager.postAudiobookBookmark` await exactly.
**Behavior risk:** none.

---

## Site 3 — `TPPEPUBViewController.swift` ~926: capture of `self` (Self)
**Warning:** `public extension DecorableNavigator { func applyDecorationsAsync(_:
in:) async { await MainActor.run { self.apply(decorations:in:) } } }` — `self`
(`Self: DecorableNavigator`, a Readium protocol, non-Sendable) is captured in the
`@Sendable` `MainActor.run` closure.

**Fix (isolation):** annotate the method `@MainActor` and call `apply(...)`
**directly** (drop the `MainActor.run`):
```swift
public extension DecorableNavigator {
  @MainActor
  func applyDecorationsAsync(_ decorations: [Decoration], in group: String) async {
    apply(decorations: decorations, in: group)
  }
}
```
The body already only did main-actor work, so `@MainActor` is behavior-preserving
(still runs on main; still `async`, awaitable from any context). **Verify**
`apply(decorations:in:)` is main-actor-callable (it is on `DecorableNavigator`)
and that callers await this method (they do — it's `async`). If any caller relies
on this running off-main (it doesn't — the body was already a `MainActor.run`),
note it. **Behavior risk:** none.

---

## Deliverable (paste in your report — NO mutation/xcresult)
For each site: (a) file:symbol + warning, (b) applied fix + mirror pattern,
(c) behavior risk. For Site 1: state where `TPPAnnotations.postBookmark`'s
completion runs and confirm the annotationId-mutation confinement is preserved.
Confirm `TPPReadiumBookmark.swift` was NOT modified and you touched ONLY the 3
files above.
