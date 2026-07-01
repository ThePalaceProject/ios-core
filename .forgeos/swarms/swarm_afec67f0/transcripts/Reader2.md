# Transcript — Reader2 (swarm_afec67f0)

Swift 6 `targeted` Phase A.5 Chunk 2 — fix by ISOLATION only, no behavior changes.
`TPPReadiumBookmark.swift` NOT modified (verified). Three in-scope files only.

---

## Site 1 — `TPPReaderBookmarksBusinessLogic.swift` : `postBookmark(_:)`

- **file:symbol** — `Palace/Reader2/BusinessLogic/TPPReaderBookmarksBusinessLogic.swift`,
  `private func postBookmark(_ bookmark: TPPReadiumBookmark)`.
- **Warning** — `capture of 'bookmark' in a `@Sendable` closure`: the
  `Task { [weak self] … }` closure captures `bookmark` (`TPPReadiumBookmark`,
  non-Sendable — 10 mutable `var`s), referenced in the two `await MainActor.run`
  local-only fallback blocks and in the `TPPAnnotations.postBookmark` completion
  (`bookmark.annotationId = response?.serverId` / `bookRegistry.add`).
- **Fix + mirror pattern** — added a `private final class ReadiumBookmarkBox:
  @unchecked Sendable` carrier (mirrors `ImageCompletionBox` in
  `ImageLoaderImpl.swift`) created BEFORE the `Task`; the `Task` captures the
  box, and all three in-Task sites now reference `bookmarkBox.bookmark`. The
  no-`currentAccount` immediate-add fallback (outside the `Task`) still uses the
  raw `bookmark` — it never crosses a concurrency boundary, so no boxing needed.
  All three fallback branches and their ordering are preserved.
- **Where does `TPPAnnotations.postBookmark`'s completion run?** OFF the main
  actor. `postBookmark` → `postAnnotation` → `currentExecutor.POST(...)`
  completion, i.e. a `TPPNetworkExecutor` URLSession network-completion thread —
  not main. **Per contract, I preserved current threading and did NOT wrap the
  `annotationId` mutation in a new `MainActor.run`.** The box's soundness rests
  on non-concurrency, not main-actor confinement: within one `Task`, exactly one
  of the three terminal paths executes (two mutually-exclusive `MainActor.run`
  early returns, or the postBookmark completion which fires at most once), so the
  boxed bookmark is never touched concurrently. The invariant comment states this
  precisely.
- **Behavior risk** — none. No threading change; the annotation completion still
  runs where it did; the two local-only fallbacks still hop to main via
  `MainActor.run` exactly as before.

## Site 2 — `AudiobookBookmarkBusinessLogic.swift` : `saveBookmark(at:completion:)`

- **file:symbol** — `Palace/Reader2/Bookmarks/AudiobookBookmarkBusinessLogic.swift`,
  `public func saveBookmark(at position: TrackPosition, completion: ((TrackPosition?) -> Void)? = nil)`.
- **Warning** — `capture of 'completion' in a `@Sendable` closure`: the
  `debounce { Task { [weak self] … } }` body captures the non-Sendable optional
  `completion` closure, invoked in the `defer` success path
  (`DispatchQueue.main.async { completion?(updatedPosition) }`) and the
  encode-failure early return (`DispatchQueue.main.async { completion?(nil) }`).
- **Fix + mirror pattern** — added a `private final class TrackPositionCompletionBox:
  @unchecked Sendable` carrier (mirrors `ImageCompletionBox`) created BEFORE the
  `debounce`; both `DispatchQueue.main.async` blocks now call
  `completionBox.call?(...)`. Optionality is preserved (`call` is optional,
  invoked with `?`). The `debounce` wrapper, `defer` ordering (registry
  `addOrReplaceGenericBookmark` then main-async completion), the encode-failure
  early return, and the `annotationsManager.postAudiobookBookmark` await are all
  untouched.
- **Behavior risk** — none. Boxed completion is only ever called inside the two
  existing `DispatchQueue.main.async` blocks (main queue), never concurrently.

## Site 3 — `TPPEPUBViewController.swift` : `DecorableNavigator.applyDecorationsAsync(_:in:)`

- **file:symbol** — `Palace/Reader2/UI/TPPEPUBViewController.swift`,
  `public extension DecorableNavigator { func applyDecorationsAsync(_:in:) async }`.
- **Warning** — `capture of 'self' in a `@Sendable` closure`: `self`
  (`Self: DecorableNavigator`, a non-Sendable Readium protocol) captured in the
  `await MainActor.run { self.apply(decorations:in:) }` closure.
- **Fix + mirror pattern** — annotated the method `@MainActor` and call
  `apply(decorations:in:)` directly (dropped the `MainActor.run`), exactly as the
  contract prescribes. `apply(decorations:in:)` is main-actor-callable on
  `DecorableNavigator`; the method remains `async` and awaitable from any context;
  all callers already `await` it.
- **Behavior risk** — none. The body already did only main-actor work inside a
  `MainActor.run`; `@MainActor` runs it on main just the same and removes the
  non-Sendable capture. No caller relies on off-main execution (there was none).

---

## Scope confirmation

- Files modified (exactly 3, all in-scope):
  1. `Palace/Reader2/BusinessLogic/TPPReaderBookmarksBusinessLogic.swift`
  2. `Palace/Reader2/Bookmarks/AudiobookBookmarkBusinessLogic.swift`
  3. `Palace/Reader2/UI/TPPEPUBViewController.swift`
- `Palace/Reader2/Bookmarks/TPPReadiumBookmark.swift` — **NOT modified** (off-limits, Decision 3).
- No `nonisolated(unsafe)`. No bare `@unchecked Sendable` — both new carriers
  (`ReadiumBookmarkBox`, `TrackPositionCompletionBox`) carry a stated invariant,
  mirroring `ImageCompletionBox`. No behavior changes; no build / verify-pr /
  mutation run (no DRM build available), per contract.
