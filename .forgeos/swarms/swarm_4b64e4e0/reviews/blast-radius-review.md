# Blast-radius review — swarm_4b64e4e0 Wave 1

**Reviewer:** forge-blast-radius-reviewer
**Date:** 2026-05-29
**Scope:** Wave 1 implementation diff (12 files, 1529 lines) per `/tmp/wave1-diff.patch`
**Verdict:** **APPROVE**

---

## Universal script evidence

| Script | Exit | Note |
|---|---|---|
| `check-blast-radius.py --quiet` | 0 | Single BR-2 medium on `Palace/AppInfrastructure/AppContainer.swift:343` — explicitly demoted by the in-diff XCTest env-gate (see Finding 1) |
| `check-contract-reconciliation.py --quiet` | 0 | All claims reconcile |
| `check-adjacency-staleness.py --quiet` | 0 | No stale adjacency |
| `check-intent-recorded.py --quiet` | 0 | Intent recorded |

All four universal checks clean.

---

## Findings by concern

### Concern 1 — `#if DEBUG _resetForTesting()` at AppContainer.swift:343, env-gated against TestFlight

**Verdict:** PASS (deliberate, defense-in-depth).

**Evidence:**
- Compile-time gate: `#if DEBUG` at line 343 with matching `#endif` at line 399. Production (Release) builds do not see the symbol at all — `_resetForTesting`, `_cached` mutation under this arm, and the `_buildCachedAppContainer()` re-assignment are all elided by the preprocessor.
- Runtime gate: line 391 — `guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil else { return }`. Per CLAUDE.md context: `#if DEBUG` IS on in TestFlight + dev-sim builds. This second gate refuses to fire in those scenarios because `XCTestConfigurationFilePath` is only set when xctest is the host process. The function early-returns before mutating `_cached`, so a misplaced call from a non-test DEBUG build is structurally inert.
- The `check-blast-radius.py` BR-2 finding was demoted from "high" to "medium" because the script detected the env-gate co-located in the same diff — exactly the policy the harness encodes.

No production state mutation is reachable from this function outside of an XCTest host process. **No concern.**

### Concern 2 — `static let _cached` → `static var _cached` + extraction to `_buildCachedAppContainer()`

**Verdict:** PASS (byte-for-byte production-path equivalence).

**Evidence:**
- `Palace/AppInfrastructure/AppContainer.swift:237` — `private static var _cached: AppContainer = Self._buildCachedAppContainer()`. The initializer expression is a single function call, which Swift evaluates under the same dispatch_once one-time guarantee that `static let` provided previously (Swift's static-property thread-safety applies to both `let` and `var` initial values).
- `_buildCachedAppContainer()` (lines 245–341) is the prior lambda body, verbatim — same hand-threading of `executor`, `reachability`, `accountsManager`, etc., same `AccessibilityAnnouncer` + `DownloadAnnouncementService` build, same `MyBooksDownloadCenter` construction.
- `production()` (lines 219–221) is unchanged: still returns `_cached`. No new init parameter; no new public API; no new caller behavior. Diff line `258:` shows the only AppContainer.swift modifications are the static-let→static-var swap, the extracted builder, the new DEBUG reset seam, and doc comments.
- No `public` / `open` declarations were introduced in either modified file (`grep -nE "public |open " Palace/AppInfrastructure/AppContainer.swift Palace/Accounts/Library/AccountsManager.swift` — no output).

Production callers observe identical behavior on first read and on every subsequent read. **No concern.**

### Concern 3 — New `#if DEBUG backgroundFetchTask: Task<Void, Never>?` field on AccountsManager

**Verdict:** PASS (compile-time gated; zero production footprint).

**Evidence:**
- `Palace/Accounts/Library/AccountsManager.swift:156-182` — the entire field declaration including `deferInitialLoadCatalogsForTesting` and `backgroundFetchTask` is bracketed by `#if DEBUG` / `#endif`. Storage cost is elided in Release builds.
- The `cancelBackgroundWork()` method (lines 1193-1239) and the `_backgroundFetchTaskIsCancelledOrCleared` observation surface are also inside `#if DEBUG`. Release `AccountsManager` instances do not pay the storage cost AND do not expose the methods.
- The doc comment on line 175-178 explicitly claims production parity: "production does NOT pay the storage cost in release builds because the whole field is `#if DEBUG`-gated." Verified by direct read.

**No concern.**

### Concern 4 — Init `#if DEBUG Task.detached { … }` arm vs production `DispatchQueue.global().async { … }` arm

**Verdict:** PASS (production arm byte-identical to pre-change).

**Evidence:**
- Lines 212-234 of `AccountsManager.swift`:
  - DEBUG arm: `if Self.deferInitialLoadCatalogsForTesting { return }` then `backgroundFetchTask = Task.detached(priority: .background) { [weak self] in self?.loadCatalogs(completion: nil) }`.
  - **Production arm (line 230-234, `#else`):** `DispatchQueue.global(qos: .background).async { [weak self] in self?.loadCatalogs(completion: nil) }`.
- The production arm is the same dispatch + same `[weak self]` capture + same `loadCatalogs(completion: nil)` call as before. The diff at `/tmp/wave1-diff.patch` lines 187-194 confirms only the DEBUG arm is added; the existing `DispatchQueue.global` line is preserved verbatim under `#else`.
- Production instances continue to spawn the background load via GCD — same QoS, same closure body, same retain semantics. The Swift Concurrency runtime is never invoked on the production path.

**No concern.**

### Concern 5 — `PalaceTests/PalaceTestSetup.swift` XCTestObservation side effects

**Verdict:** PASS (read-only observation; no notification posts, no UserDefaults writes, no keychain access).

**Evidence:**
- `grep -n "post\|UserDefaults\|Keychain\|TPPKeychain" PalaceTests/PalaceTestSetup.swift` — the only matches are local `post`/`postCount` variable names inside the NotificationCenter observer-count audit (lines 137-149). No `NotificationCenter.default.post(…)`, no `UserDefaults.standard.set(…)`, no `Keychain` / `TPPKeychain` calls.
- The observer methods do exactly two things:
  1. `testCaseWillStart`: sample `NotificationCenter.default.debugDescription` via a regex parse (read-only) → store in `preCount`.
  2. `testCaseDidFinish`: call `SingletonResetRegistry.shared.invokeAll()` and resample the observer count. If `delta > 0`, emits `XCTContext.runActivity` warning with an `XCTAttachment` — XCTest-internal, not user-observable.
- The registry's per-resetter closures are owned by `PalaceTestSetup.registerBuiltInResetters()`. The five built-in resetters touch `AppContainer._resetForTesting()`, `AccountStateStore.shared._resetAllForTesting()`, `TPPUserAccountMock.resetShared()`, `HTTPStubURLProtocol.removeAllHandlers()`, and `URLSession._resetStubbedSession()` — none of which post notifications, mutate `UserDefaults`, or touch the keychain.
- `NoNetworkURLProtocol.enable()` at line 44 is a pre-existing behavior preserved through bootstrap.

**No concern.**

### Concern 6 — Closure-capture ARC release of old `_cached` graph

**Verdict:** PASS (no captures prevent release).

**Evidence:**
- `PalaceTests/PalaceTestSetup.swift:69-83` — the registered closure body is:
  ```swift
  registry.register("AppContainer._resetForTesting") {
      #if DEBUG
      MainActor.assumeIsolated {
          AppContainer._resetForTesting()
      }
      #endif
  }
  ```
  The closure captures **nothing** from outer scope — no `AppContainer` reference, no `_cached` reference, no `self`. It calls a static function via type-qualified name. ARC cannot retain anything because no symbol is captured.
- Inside `_resetForTesting()` (AppContainer.swift:383-398): the prior `_cached` is read once (`_cached.accountsManager.cancelBackgroundWork()`), then `_cached` is reassigned (`_cached = Self._buildCachedAppContainer()`). The reassignment drops the prior struct value; its transitive class references (`bookRegistry`, `networkExecutor`, etc.) follow standard ARC release semantics. Any consumer holding a strong reference to those class instances (e.g. a still-running test) keeps them alive, but the static `_cached` slot itself releases the prior struct.
- No new `static let` retains were introduced. The `SingletonResetRegistry.shared` retains the closure (it's stored in the resetters array), but the closure has no captured graph.

**No concern.**

---

## Summary

Wave 1 implements a tightly scoped, defense-in-depth test seam. The two production-file changes (`AppContainer.swift`, `AccountsManager.swift`) preserve byte-for-byte production behavior:

- `static var _cached` lazy-init = same one-time semantics as `static let _cached`.
- All new test seams are dual-gated (compile-time `#if DEBUG` + runtime `XCTestConfigurationFilePath` env check at the reset entry point).
- Production AccountsManager continues to use `DispatchQueue.global(qos: .background).async`.
- New `backgroundFetchTask` storage is `#if DEBUG`-only; Release builds pay zero cost.
- PalaceTestSetup observer is read-only against NotificationCenter, mutates no UserDefaults, touches no keychain.
- The registered reset closure captures no production graph references.

The single `check-blast-radius.py` finding (BR-2 medium on AppContainer.swift:343) was deliberately demoted because the script detected the co-located XCTest env-gate — that's the harness's documented "defense-in-depth accepted" path.

**APPROVE.** Promote review gate.
