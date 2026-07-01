# Transcript — AppInfrastructure (swarm_afec67f0)

Swift 6 `targeted` concurrency, Chunk 2 non-critical sweep. Fix-by-isolation
only, no behavior changes. Touched EXACTLY the 3 in-scope files:
- `Palace/AppInfrastructure/AppContainer.swift`
- `Palace/AppInfrastructure/DLNavigator.swift`
- `Palace/AppInfrastructure/FirebaseManager.swift`

No `nonisolated(unsafe)` used. No **bare** `@unchecked Sendable`; the two
`@unchecked Sendable` uses are documented with a stated invariant (mirroring the
established `ObserverTokenBox` / `TPPAgeCheck` precedents).

---

## Site 1 — `AppContainer.swift`: `_buildCachedAppContainer()` → `userAccountPublisher: .shared`

**(a) file:symbol + warning**
`AppContainer.swift`, `static func _buildCachedAppContainer() -> AppContainer`
(the builder behind `production()` / `_cached`). The `userAccountPublisher: .shared`
argument reads `UserAccountPublisher.shared`, which is `@MainActor`-isolated
(`UserAccountPublisher.swift:14 @MainActor`, `:164 static let shared`), from the
nonisolated builder → *main-actor-isolated property read from a nonisolated
context*.

**(b) applied fix + pattern mirrored**
Hoisted the single main-actor read behind `MainActor.assumeIsolated` and passed
the local into the `AppContainer(...)` init instead of `.shared`:

```swift
let userAccountPublisher = MainActor.assumeIsolated { UserAccountPublisher.shared }
// ...
userAccountPublisher: userAccountPublisher,
```

Mirrors the **existing in-file precedent**: `_buildCachedAppContainer()` already
constructs `authCoordinator` inside a `MainActor.assumeIsolated { ... }` block
(same function, ~30 lines above), and `_resetForTesting()` uses the same
assertion to nil the `@MainActor` session statics. No `production()` signature
change — it stays `nonisolated`, so the ripple to its ~150 call sites is avoided.
A one-line comment states the main-thread precondition.

**(c) behavior risk:** none. `assumeIsolated` is a compile-time isolation
bridge that fatalErrors only if actually off-main; the precondition already holds
(see audit) and is already relied upon by the sibling `authCoordinator` block.

**(d) `production()` call-site audit (REQUIRED)**
`production()` returns `_cached`; the first read triggers Swift's lazy-static
`_cached` initializer, which runs `_buildCachedAppContainer()` once. The relevant
question is only: *on what thread does the FIRST `production()` call land?*

- Grepped all `AppContainer.production()` sites (`grep -rn`, ~150 hits). The
  earliest-in-lifecycle callers are UIKit app-launch entry points, all main-thread:
  - `TPPAppDelegate.swift:64` `application(_:didFinishLaunchingWithOptions:)` →
    `playbackBootstrapper.ensureInitialized()` (and :115/:118/:119/:124/:144/:200…).
  - `SceneDelegate.swift:52` `let container = AppContainer.production()`.
  - `AppContainerKey.defaultValue` (`:604`) — SwiftUI environment default, resolved on main.
- No first-caller is inside a `Task.detached`, `DispatchQueue.global`, or a
  background queue. Test-path rebuilds (`_resetForTesting`, `_rebuildCachedForTestProtocols`)
  run from main-thread XCTest setup (`PalaceTestSetup`), and `_resetForTesting()`
  already wraps its `@MainActor` static resets in `MainActor.assumeIsolated`.
- **Decisive structural evidence:** `_buildCachedAppContainer()` *already*
  contains `let authCoordinator = MainActor.assumeIsolated { AuthCoordinator(...) }`.
  That shipped assertion means the entire builder is already required to run on
  main; if any first-caller were off-main, the app would already crash there. The
  new `userAccountPublisher` read introduces **no new precondition** — it is
  strictly covered by the invariant the codebase already ships and depends on.

Conclusion: no off-main call site found. Precondition holds. Not BLOCKED.

---

## Site 2 — `DLNavigator.swift`: `callOnce(on:block:)` `var token`

**(a) file:symbol + warning**
`DLNavigator.callOnce(on:block:)`. Warning: *'token' mutated after capture by
sendable closure* — `var token` is assigned (`token = addObserver(...)`) after
the `@Sendable` `queue: .main` observer block is formed, and the block reads it
(`if let token = token { removeObserver }`).

**(b) applied fix + pattern mirrored**
Mirrored **`ObserverTokenBox`** (`TPPBookRegistry.swift:58`). Introduced a
`private final class ObserverTokenBox: @unchecked Sendable` holding
`var token: NSObjectProtocol?`, written exactly once right after `addObserver`
returns; the observer block calls `box.removeObserver(name:)`. Preserved the
existing `removeObserver(token, name: name, object: nil)` call shape exactly
(the box method takes `name:` and forwards `object: nil`) and the
`block(notification)` ordering (remove, then `block`). Documented invariant:
token is write-once-then-read confined — no race.

```swift
let box = ObserverTokenBox()
box.token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { notification in
    box.removeObserver(name: name)
    block(notification)
}
```

**(c) behavior risk:** none. Same observer registration, same one-shot
self-removal semantics (`removeObserver(_:name:object:)` with identical args),
same `block` invocation order. Only the storage of the token moved from a
captured `var` to a heap box.

---

## Site 3 — `FirebaseManager.swift`: capture of `self` in `withTimeout` closure

**(a) file:symbol + warning**
`FirebaseManager.fetchAndActivateRemoteConfig()` — the operation closure passed
to `Self.withTimeout(seconds:_:)` (`func withTimeout<T: Sendable>(_ … @escaping
@Sendable () async throws -> T`, `:182`) captures `self`
(`try await self.remoteConfig.fetchAndActivate()`), but `FirebaseManager`
(`final class`, `:23`) was not `Sendable`. Warning: *capture of 'self'
(FirebaseManager)* in a `@Sendable` closure.

**(b) applied fix + pattern mirrored**
Made `FirebaseManager` conform to **documented `@unchecked Sendable`**, mirroring
the `TPPAgeCheck: @unchecked Sendable` precedent (lock-guarded mutable state +
immutable `let`s). No closure signature change needed. Invariant comment added:
all stored properties are `let` (`deviceID`, `sanitizedDeviceID`, `remoteConfig`);
the only mutable state (`isFetching`) is guarded by `OSAllocatedUnfairLock`
(itself `Sendable`); `remoteConfig` is Firebase's internally-thread-safe
`RemoteConfig` (why plain `Sendable` isn't derivable — `RemoteConfig` isn't
marked `Sendable`, hence `@unchecked`).

**(c) behavior risk:** none. Conformance-only; no property, method, or control
flow changed.

---

## Confirmation
- Edited ONLY the 3 in-scope files. No Accounts/CarPlay/OPDS/Reader2/Book-Models
  file touched. No `TPPBookRegistry`/`BookRegistrySync`/`TPPBookCoverRegistry` edit.
- No `nonisolated(unsafe)`. Both `@unchecked Sendable` uses carry a stated invariant.
- No build / verify-pr / mutation run performed (per contract — no DRM build here;
  CI "Unit Tests" is the gate).
