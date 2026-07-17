# Contract B — Effect Unification / Boundary Formalization (WS2) · Transcript

**Status: READY** (TODAY tier). Decision taken: **formalize the boundary** (the
contract's preferred "OR" branch), NOT collapse-to-one (that stays a gated
follow-up needing a shared SPM module).

## Summary
- Added the missing `Environment: Sendable` bound to `PalaceAuth.Effect` and
  mirrored the canonical `Store.Effect` exactly — `@Sendable` `run`/`init`,
  `@Sendable` `task` closure, and `Action: Sendable` on `.send`. The two copies
  are now **semantically identical**, closing the drift the review flagged.
- Documented **why** the duplicate exists in a header on `Effect.swift`: PalaceAuth
  is a standalone SPM package that must not import the app module (`Palace`);
  cites `Palace/Packages/PalaceCatalog` as the package-local-mirror precedent and
  names the finish-line (shared SPM module) as the gated follow-up.
- `AuthEnvironment` gained an explicit `Sendable` conformance (required by the new
  bound; the compiler does not synthesize `Sendable` for public types). It is
  trivially safe — the struct is stateless.
- Count is pinned at exactly **2** `struct Effect<Action, Environment` decls, both
  `Sendable`-constrained (AC1/AC2 pass locally). Contract F owns encoding this as
  the machine-checked probe.
- `TriageBot`'s different-shape reducer was not touched (AC4 pass).

## Files
**Modified**
- `Palace/Packages/PalaceAuth/Sources/PalaceAuth/Effect.swift` — `Sendable` bound,
  `@Sendable` closures, `Action: Sendable` on `.send`, boundary-reason doc header.
- `Palace/Packages/PalaceAuth/Sources/PalaceAuth/AuthReducer.swift` — one change:
  `AuthEnvironment` now conforms to `Sendable` (declaration line + doc note). No
  reducer-body / effect-authoring changes (those are off-limits per the contract).
- `Palace.xcodeproj/project.pbxproj` — registered the new app-bundle test file via
  `scripts/pbxproj_add_swift.rb` (idempotent). NOTE: this file is also touched by
  sibling implementers' staged additions in the shared worktree.

**Added**
- `Palace/Packages/PalaceAuth/Tests/PalaceAuthTests/EffectBoundaryTests.swift` —
  package test target (standalone `swift test` path; contract-sanctioned).
- `PalaceTests/SignInLogic/EffectBoundaryTests.swift` — app test bundle (the
  `-only-testing:PalaceTests/EffectBoundaryTests` evidence path for Monday; see
  the blocker in Gaps — the bundle can't compile on the branch tip today).

## Tests
Both `EffectBoundaryTests` classes (identical intent, two compilation domains):
- `test_none_resolvesToNoFollowUpAction` — `.none` → nil.
- `test_send_deliversExactlyThatAction_regardlessOfEnvironment` — `.send(x)` → x.
- `test_task_runsClosureAndThreadsTheCallersEnvironment` — `.task` runs the closure
  against the *passed* environment (uses a `Sendable` probe env carrying a marker,
  since `AuthEnvironment` is empty and can't witness threading).
- `test_task_returningNil_endsTheChain` — `.task { nil }` → nil.
- `test_customInit_runsTheProvidedClosure` — `init(run:)` stores/invokes the closure.
- `test_authEnvironment_satisfiesSendableBound_andEffectResolvesOverIt` — the
  **compile-time boundary witness**: `assertSendable<T: Sendable>(AuthEnvironment.self)`
  fails to COMPILE if the conformance regresses (a stronger guard than a runtime
  mutant), paired with a runtime assertion that `.none` over `AuthEnvironment`
  resolves.

## Gaps (for the integrator / Monday gate)
1. **PRE-EXISTING BLOCKER — the `PalaceTests` app bundle does not compile on the
   branch tip.** Commit `dd6b73ee0` ("[EXPERIMENT] chore(test): ratchet PalaceTests
   to Swift 6") makes `PalaceTests/MetaTests/RuntimeQuiescenceGateTests.swift:208`
   a hard error (`DispatchSemaphore.wait()` is unavailable from async contexts under
   Swift 6, inside a `Task.detached`). This is unmodified by me (`git diff HEAD` on
   that file is empty) and is entirely outside Contract B's scope (MetaTests). It
   blocks **every** `-only-testing:PalaceTests/*` run for the whole swarm — so the
   orchestrator's app-bundle test path and `palace_mutate.py` (which drives that
   bundle) cannot run until it is fixed (fix the meta test's semaphore usage or
   revert the experiment). My app-bundle `EffectBoundaryTests.swift` is correct and
   will run once the bundle compiles — it's the same code that compiles+passes in the
   package target today. **I did not edit the out-of-scope file; reporting per the
   READ-ONLY rule.**
2. **Contract-F count-probe.** I verified locally (AC1/AC2) that the count is 2 and
   both are `Sendable`-constrained; F owns turning this into the committed
   architecture probe / `arch-drift-check.py` assertion.
3. **`AuthAction` / `AuthMethodType` are intentionally NOT `Sendable`.** Not required:
   `Effect` only bounds `Environment`, and `AuthReducer.reduce` returns only `.none`.
   If impl-4 later wires `AuthAction` through the app `Store`'s `.send` (which is
   `where Action: Sendable`), that conformance becomes needed then — flagged, not done
   here (effect-authoring is off-limits for this contract).

## Definition-of-Done evidence (TODAY tier)

### (1) Changed files COMPILE clean
App target build (isolated derivedDataPath `/tmp/dd-B-12017`):
```
xcodebuild -project Palace.xcodeproj -scheme Palace \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/dd-B-12017 build
...
** BUILD SUCCEEDED **
```
Standalone package build (Swift 6 race-checked source target):
```
cd Palace/Packages/PalaceAuth && swift build
...
[63/63] Compiling PalaceAuth Effect.swift
Build complete! (6.98s)
```

### (2) Diff-scoped mutation
```
python3 scripts/palace_mutate.py \
  --file Palace/Packages/PalaceAuth/Sources/PalaceAuth/Effect.swift \
  --tests PalaceTests/EffectBoundaryTests --diff-only --dry-run
->
No mutation points found in .../Effect.swift
This file has no testable mutations (no comparison/boolean/return-flip operators).
```
Kill rate: **0/0 = 100% (vacuous)** — the diff is a type-constraint + closure-attribute
+ doc change with no mutable operators. The regression guard is COMPILE-TIME (the
`Sendable`-witness test fails to build if the conformance/bound regresses), which is
strictly stronger than a runtime mutant.

Because the tool's operator set generates nothing here, I ran a **manual mutation** to
prove the behavior tests aren't fluff — broke `.send` (`{ _ in action }` → `{ _ in nil }`)
and `.task` (`Effect(run: work)` → `{ _ in nil }`), ran `swift test --filter EffectBoundaryTests`:
```
test_send_deliversExactlyThatAction... FAILED: ("nil") is not equal to ("Optional(42)")
test_task_runsClosureAndThreadsTheCallersEnvironment FAILED: ("nil") is not equal to ("Optional(42)")
Executed 6 tests, with 2 failures
```
Both mutants killed; original restored (verified `Effect { _ in action }` / `Effect(run: work)` intact).

### (3) Targeted tests pass
App-bundle `-only-testing:PalaceTests/EffectBoundaryTests` is BLOCKED by the
pre-existing Swift-6 bundle-compile error (Gap #1). Ran the contract-sanctioned
**PalaceAuth test target** path instead:
```
cd Palace/Packages/PalaceAuth && swift test --filter EffectBoundaryTests
-> Executed 6 tests, with 0 failures (0 unexpected)

# Full package suite (proves no regression to existing auth tests):
cd Palace/Packages/PalaceAuth && swift test
-> Test Suite 'All tests' passed — Executed 116 tests, with 0 failures (0 unexpected)
```
(SPM `swift test` does not emit an `.xcresult` bundle; the app-bundle `.xcresult`
path is available once Gap #1 is resolved. Last app-bundle attempt wrote
`/tmp/dd-Bt-12047/Logs/Test/Test-Palace-2026.07.17_15-29-48--0400.xcresult`, which
captures the pre-existing MetaTests compile failure, not a Contract-B failure.)

### AC verification block (Phase 4.5) — all PASS
```
AC1 (exactly 2 struct Effect decls): PASS (2)
AC2a (Store.swift Sendable bound):   PASS
AC2b (PalaceAuth Environment: Sendable): PASS
AC3 (boundary reason documented):    PASS
AC4 (TriageBot untouched):           PASS
```
