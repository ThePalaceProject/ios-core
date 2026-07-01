# CarPlay implementer transcript — swarm_afec67f0

Swift 6 `targeted` Phase A.5 Chunk 2. Fix-by-isolation only. Files in scope
(exclusively): `Palace/CarPlay/CarPlayImageProvider.swift`,
`Palace/CarPlay/CarPlayTemplateManager.swift`.

---

## Site 1 — `CarPlayImageProvider.swift` : `artwork(for:completion:)` — FIXED

**file:symbol:** `Palace/CarPlay/CarPlayImageProvider.swift` →
`CarPlayImageProvider.artwork(for:completion:)` (the async `Task { … await
MainActor.run { completion(processed) } }` tail).

**Warning:** `capture of 'completion'` — the non-`Sendable` `@escaping (UIImage?)
-> Void` completion handler is captured into the `@Sendable` `Task` closure.

**Fix (isolation — mirror `ImageCompletionBox`):** added a file-private
`private final class CarPlayImageCompletionBox: @unchecked Sendable` carrier
(exact mirror of `ImageCompletionBox` in
`Palace/Utilities/ImageCache/ImageLoaderImpl.swift:11`), with the documented
invariant: the boxed closure is only ever invoked inside `await MainActor.run`,
never off-main and never concurrently. In `artwork(for:completion:)` the box is
constructed *before* the `Task`, the box is captured instead of the raw
closure, and the final `MainActor.run` calls `completionBox.call(processed)`.

**Preserved exactly:**
- The two early-return synchronous paths (cache hit; `book.coverImage ??
  book.thumbnailImage` existing-image path) still call `completion(...)`
  directly — no boxing needed, they never cross a Task boundary.
- Cache-set-before-completion ordering (`imageLoader.set(processed, for:
  cacheKey)` before the boxed call) is unchanged.

**Behavior risk:** none. Documented `@unchecked Sendable` carrier with stated
invariant is explicitly allowed by the contract (Global rules). No public
signature change; no `@Sendable` ripple to call sites.

---

## Site 2 — `CarPlayTemplateManager.swift` deinit (`nowPlayingTemplate.remove(self)`) — SCOPE-DEFERRAL (BLOCKED), left as-is

**file:symbol:** `Palace/CarPlay/CarPlayTemplateManager.swift` → `deinit`,
`nowPlayingTemplate.remove(self)`.

**Warning:** `CPNowPlayingTemplate.remove(_:)` is `@MainActor`-isolated but is
called from the nonisolated `deinit`.

### Resolution path taken: **scope-deferral** (neither path 1 nor path 2 yields a behavior-preserving, self-capture-free, `assumeIsolated`-free fix within my 2-file scope).

### Evidence gathered

**Observer registration** (`configureNowPlayingTemplateIfNeeded()`, line ~490–502):
```swift
nowPlayingTemplate = CPNowPlayingTemplate.shared   // process-lifetime singleton
...
nowPlayingTemplate.add(self)                       // the observer object IS self
```
The observer identity is `self` (the `CarPlayTemplateManager`, which conforms to
`CPNowPlayingTemplateObserver`). There is **no separate observer token** — the
thing `remove(_:)` must be handed is `self`.

**Ownership / lifecycle** (`Palace/CarPlay/CarPlaySceneDelegate.swift`):
- `CarPlaySceneDelegate` holds the only strong ref: `private var templateManager:
  CarPlayTemplateManager?`, created in `didConnect` (line 45).
- `templateApplicationScene(_:didDisconnect:)` (line 56–70) is a `@MainActor`
  CarPlay scene callback that sets `templateManager = nil`. Because
  `CPNowPlayingTemplate.shared` is a process-lifetime singleton, if it retained
  `self` strongly the manager could never dealloc while registered and the deinit
  removal would be dead/unreachable — the fact that the removal exists (and is
  described as crash-preventing) implies the template does **not** strongly retain
  the observer. So dropping to `templateManager = nil` in `didDisconnect` is the
  release site, and in the normal path the deinit runs on main synchronously
  inside `didDisconnect`.

**Weak-observer question (path 2, sub-option "removal is purely defensive"):**
the in-code comment states the removal is there "to prevent crashes during CarPlay
disconnect/reconnect cycles." A *zeroing-weak* observer store would auto-nil on
dealloc and could not crash — so the crash-prevention rationale is evidence the
store is **unsafe-unretained / non-zeroing**, i.e. the removal is **load-bearing,
not defensive**. I could not find framework documentation proving weak semantics,
and the code's own stated rationale contradicts the "defensive, safe to drop"
premise. Therefore path 2's "drop the removal, let weak auto-nil" sub-option is
**not behavior-preserving** and is rejected.

### Why each contract path fails

- **Path 1 (self-capture-free hop to a distinct observer token):** the observer
  is `self`; there is no separately-stored token distinct from `self` whose
  lifetime is independent of the deinit. A self-capture-free hop is impossible
  without first restructuring registration to use a separate observer object —
  that is a behavior/structure change, not an isolation-only fix. `remove(_:)`
  fundamentally needs `self`, and capturing `self` in an escaping `Task` from
  `deinit` is the banned resurrection hazard. Rejected.

- **Path 2 (move removal to a `@MainActor` teardown before deinit):** the correct
  teardown seam **does exist** — `CarPlaySceneDelegate.didDisconnect` (already
  `@MainActor`, already the release site). The clean fix is: add a `@MainActor
  func` teardown to `CarPlayTemplateManager` that performs `remove(self)`, drop
  the removal from `deinit`, and **call that teardown from
  `CarPlaySceneDelegate.didDisconnect` before `templateManager = nil`.** BUT
  wiring the call requires editing `CarPlaySceneDelegate.swift`, which is **OUT OF
  MY 2-FILE SCOPE**. Landing only the in-scope half (add teardown + strip deinit
  removal) with no caller would ship the observer *never* being removed →
  reintroduces exactly the disconnect/reconnect crash the removal guards against.
  That is shipping broken to make a warning disappear — forbidden. And even wired,
  it is a flagged **behavior question** (does `didDisconnect` always fire before
  dealloc? termination / non-disconnect release paths) requiring integration
  review. Rejected within scope.

- `MainActor.assumeIsolated` in deinit: BANNED (deinit not guaranteed on main →
  `fatalError` risk). `nonisolated(unsafe)`: BANNED. Not used.

### BLOCKED: scope reduction proposal

```
Original scope: 2 sites (CarPlayImageProvider capture, CarPlayTemplateManager deinit).
I can land cleanly: 1 (Site 1 — CarPlayImageProvider, done).
Remaining 1 (Site 2 — CarPlayTemplateManager deinit): the only behavior-preserving,
assumeIsolated-free, self-capture-free fix (move remove(self) into a @MainActor
teardown called from CarPlaySceneDelegate.didDisconnect BEFORE templateManager = nil)
requires editing CarPlaySceneDelegate.swift, which is OUT OF my 2-file contract scope,
AND is a flagged behavior question (teardown-before-dealloc guarantee) for integration
review.

Options for the orchestrator:
  (a) extend this pass to also touch CarPlaySceneDelegate.swift: add
      `@MainActor func tearDownNowPlayingObserver()` to CarPlayTemplateManager,
      strip the removal from deinit, and call the teardown from
      didDisconnect before `templateManager = nil`. Requires integration review
      of the teardown-always-fires-before-dealloc invariant.
  (b) accept the reduction; defer CarPlayTemplateManager deinit to the CarPlay
      critical-path slice the existing in-code comment already references
      ("Deferred to the CarPlay critical-path slice"). deinit left byte-for-byte
      as-is; the strict-concurrency warning remains (as it is today).

I did NOT weaken the constraint to land the diff. deinit is unchanged.
```

**Behavior-review flag:** any path-2 implementation must prove
`CarPlaySceneDelegate.didDisconnect` (or another `@MainActor` teardown) fires
before every dealloc of `CarPlayTemplateManager`, including app-termination and
any non-disconnect release path. If that cannot be guaranteed, the deinit removal
must stay (option b).

---

## Scope confirmation

Touched ONLY the 2 in-scope files:
- `Palace/CarPlay/CarPlayImageProvider.swift` — Site 1 fix (box added + used).
- `Palace/CarPlay/CarPlayTemplateManager.swift` — **NOT modified** (Site 2 deferred; deinit left as-is).

Read-only evidence (not edited): `Palace/CarPlay/CarPlaySceneDelegate.swift`,
`Palace/Utilities/ImageCache/ImageLoaderImpl.swift`.

No `git`, no build, no verify-pr/mutation/xcresult run (per environment rules).
