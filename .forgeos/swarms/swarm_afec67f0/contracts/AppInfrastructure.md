# Contract — AppInfrastructure (swarm_afec67f0)

Swift 6 `targeted` Phase A.5 Chunk 2. **Fix by ISOLATION only. No behavior
changes.** Line numbers are the A.4 snapshot — **locate by symbol**, verify each
still warrants a fix, and clear every capture-of-non-Sendable in the touched
functions (not only the cited lines).

## Files IN scope (yours, exclusively)
- `Palace/AppInfrastructure/AppContainer.swift`
- `Palace/AppInfrastructure/DLNavigator.swift`
- `Palace/AppInfrastructure/FirebaseManager.swift`

## OFF-LIMITS
Everything else — especially `Palace/Book/Models/{BookRegistrySync,
TPPBookRegistry,TPPBookCoverRegistry}.swift`. Do not modify any Accounts /
CarPlay / OPDS / Reader2 file.

## Global rules
- NEVER `nonisolated(unsafe)`. NO **bare** `@unchecked Sendable`. A **documented**
  `@unchecked Sendable` with a stated invariant (mirror `ImageCompletionBox` /
  `TPPAgeCheck: @unchecked Sendable`) IS allowed.
- Do NOT run verify-pr / palace_mutate / xcresult (no DRM build). You cannot
  build the DRM app locally; CI "Unit Tests" is the gate.

---

## Site 1 — `AppContainer.swift` ~481: `userAccountPublisher: .shared`
**Warning:** `UserAccountPublisher.shared` is `@MainActor`-isolated
(`UserAccountPublisher.swift:14 @MainActor`, `:164 static let shared`) but
`static func production() -> AppContainer` (`:327`) is **nonisolated** →
main-actor property read from a nonisolated context.

**Fix (isolation):** hoist the single main-actor read behind
`MainActor.assumeIsolated`, which is **legal here** — `production()` is the app
composition root, only ever invoked on the main thread (app launch +
main-thread XCTest setup). Do NOT make `production()` `@MainActor` unless you
first confirm every call site is already `@MainActor`/main-thread (it ripples).

```swift
let userAccountPublisher = MainActor.assumeIsolated { UserAccountPublisher.shared }
// ... pass `userAccountPublisher` into the AppContainer(...) init instead of `.shared`
```
- `assumeIsolated` is acceptable OUTSIDE deinit when the caller is known-on-main
  (this is NOT the CarPlay deinit case). Add a one-line comment stating the
  main-thread precondition.
- **Verification required:** grep call sites of `AppContainer.production()` and
  confirm they are main-thread (launch + `_resetForTesting`). Note the result in
  your report.
- **Behavior risk:** none if the precondition holds. If any call site is proven
  off-main, STOP and file a scope-deferral (do not silently ship).

## Site 2 — `DLNavigator.swift` ~107: `callOnce(on:block:)` `var token`
**Warning:** `'token' mutated after capture by sendable closure` — `var token`
is assigned after the `@Sendable` `addObserver` block is formed and referenced
inside it (`if let token = token { removeObserver }`).

**Fix (isolation):** **mirror `ObserverTokenBox`** (`TPPBookRegistry.swift:58`).
Introduce a `private final class` box `@unchecked Sendable` holding
`var token: NSObjectProtocol?`, write it once right after `addObserver` returns,
and have the block call `box.removeObserver()`. Invariant comment: token is
written exactly once, read thereafter — write-once-then-read confinement, no
race. Preserve the existing `removeObserver(_:name:object:)` call shape and the
`block(notification)` ordering exactly.

## Site 3 — `FirebaseManager.swift` ~147: capture of `self` in withTimeout closure
**Warning:** `capture of 'self' (FirebaseManager)` — the operation closure
passed to `Self.withTimeout(...)` (`func withTimeout<T: Sendable>(_ …
@escaping @Sendable () async throws -> T`, `:182`) captures `self`, and
`FirebaseManager` (`final class`, `:23`) is not Sendable.

**Fix (isolation):** make `FirebaseManager` conform to **`Sendable`**. Its stored
properties are all `let`: `deviceID: String`, `sanitizedDeviceID: String`,
`private let remoteConfig: RemoteConfig`, `private let isFetching =
OSAllocatedUnfairLock(initialState: false)`. `OSAllocatedUnfairLock` is Sendable
and guards the only mutable fetch state; `String`s are Sendable; `RemoteConfig`
is Firebase's internally-thread-safe config object. Because `RemoteConfig` is not
itself marked Sendable, use **documented `@unchecked Sendable`** on
`FirebaseManager` (mirror the `TPPAgeCheck: @unchecked Sendable` precedent —
lock-guarded mutable state + immutable `let`s). Add the invariant comment:
> all stored properties are `let`; the only mutable state (`isFetching`) is
> guarded by `OSAllocatedUnfairLock`; `remoteConfig` is Firebase's
> internally-thread-safe `RemoteConfig`.

Then the `self`-capturing `@Sendable` closure compiles clean with no signature
change. **Behavior risk:** none.

---

## Deliverable (paste in your report — NO mutation/xcresult)
For each of the 3 sites: (a) file:symbol + the exact warning, (b) the applied fix
and which established pattern it mirrors, (c) behavior risk (expected: none),
(d) for Site 1: the `production()` call-site audit result. Confirm you touched
ONLY the 3 files above.
