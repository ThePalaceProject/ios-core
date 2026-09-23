---
name: palaceauth-swift6-modernization
created: 2026-06-30
author: claude
---

# palaceauth-swift6-modernization

Final per-package module of the Swift 6 modernization fan-out (#1129 playbook).
PalaceAuth is **critical-path** (AuthCoordinator actor, AuthErrorClassifier,
TokenRequest, the auth-error decision seams) and is gated behind PalaceCatalog
(consumes its Sendable types) — so this branches off `feat/swift6-palacecatalog`
and merges after it. PR + architect/qa SoD (critical path).

## Measured scope (2026-06-30, `swift build -Xswiftc -strict-concurrency=complete`)

Only **3** concurrency warnings (#1129 sizing estimated "trivial / 1"). All fixed
by isolation, never `nonisolated(unsafe)`:

1. `AuthDecisionPayload.iso8601Formatter` (static ISO8601DateFormatter,
   #MutableGlobalVariable) → localized per-call via `makeISO8601Formatter()`
   (telemetry path, called once per payload — not hot). Behavior-identical.
2. `AuthCoordinator.swift:160` Task capture: the actor spawns a `@Sendable`
   refresh Task capturing `userAccount: TPPUserAccountWriting & TPPUserAccountReading`
   — the only non-Sendable capture (siblings `Reauthenticating` /
   `SignInModalPresenting` / `AuthDecisionRecording` were ALREADY `Sendable`).
   Fixed by adding `Sendable` to `TPPUserAccountReading`/`TPPUserAccountWriting`
   in AuthCoordinatorSeams.swift — completes the established seam pattern (these
   deps cross into the refresh Task by design; this is the existing contract
   made type-honest, not new concurrency).
3. `TokenRequest.execute(completion:)` Task: `completion` param → `@Sendable`,
   and `TokenRequest` → `final ... Sendable` (immutable `let`-only storage; no
   subclasses; self is captured by the Task to drive the async POST).

## Manifest

- macOS host floor 12 → 13 (PalaceLogging dep; host-only; iOS stays 16).
- `swift-tools-version` 5.9 → 6.0; source target `.swiftLanguageMode(.v6)`, the
  REAL test target `PalaceAuthTests` stays `.v5` (XCTestCase isn't Sendable) —
  the Keychain/TriageBot pattern (NOT the dropped-phantom-testTarget pattern,
  since PalaceAuth has a genuine `Tests/` dir).

## Anti-claims

- does NOT use `nonisolated(unsafe)`.
- does NOT change AuthCoordinator's refresh logic / AuthErrorClassifier decisions
  — only Sendable annotations + per-call formatter + closure isolation.
- App-target Sendable ripple: `TPPUserAccount+TPPUserAccountReadingWriting.swift`
  conformer gets a Swift-5 Sendable WARNING (not error). Verify TPPUserAccount is
  genuinely thread-safe (it's already captured into the refresh Task in
  production) — proper Sendable annotation is the app-target module's job. No app
  callers of `TokenRequest.execute(completion:)` (grep-clean), so that change has
  no app ripple.

## Files in scope

- Palace/Packages/PalaceAuth/Package.swift (floor, tools 6.0, source v6 / tests v5)
- Palace/Packages/PalaceAuth/Sources/PalaceAuth/AuthDecisionPayload.swift (formatter)
- Palace/Packages/PalaceAuth/Sources/PalaceAuth/AuthCoordinatorSeams.swift (2 protocols → Sendable)
- Palace/Packages/PalaceAuth/Sources/PalaceAuth/TokenRequest.swift (final+Sendable, @Sendable completion)

## Verification

`swift build` (v6) 0/0; `swift test` (in-package) **110 tests, 0 failures**;
full-app iOS CI build-and-test is the app-ripple gate; architect + qa SoD.
