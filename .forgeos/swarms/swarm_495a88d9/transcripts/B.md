# Module B — FeatureFlag (sideLoadingEnabled) — READY

**Swarm:** swarm_495a88d9 · **Branch:** swarm/495a88d9-B · **Worktree:** `ios-core-sl-B`

## Summary
Added the `sideLoadingEnabled` remote feature flag with DEBUG-on local-override
precedence (mirrors `isTriageBotEnabled` per locked decision #2). All flag
plumbing only — no Settings UI, no lane (owned by C/D). Contract fully satisfied.

## Files changed
- `Palace/FeatureFlags/RemoteFeatureFlags.swift` (modify)
  - `FeatureFlag.sideLoadingEnabled = "side_loading_enabled"` (new case)
  - `managerKey` arm `.sideLoadingEnabled → .sideLoadingEnabled`
  - `static let sideLoadingLocalOverrideKey = "RemoteFeatureFlags.sideLoadingLocalOverride"`
  - `var isSideLoadingEnabled: Bool` — precedence: local override > `#if DEBUG` true > `isFeatureEnabled(.sideLoadingEnabled)` (Firebase)
  - `defaultValue` unchanged (falls into `default` arm → false, as contract specifies)
- `Palace/AppInfrastructure/FirebaseManager.swift` (modify)
  - `RemoteConfigKey.sideLoadingEnabled = "side_loading_enabled"` (new case)
  - `setDefaultValues()` entry `RemoteConfigKey.sideLoadingEnabled.rawValue: NSNumber(value: false)`
- `PalaceTests/FeatureFlags/RemoteFeatureFlagsSideLoadingTests.swift` (NEW, registered via `pbxproj_add_swift.rb`)
- `Palace.xcodeproj/project.pbxproj` (test file entry, via helper — not hand-edited)

## Tests (5, all behavior/precedence — no default-value fluff)
1. `testIsSideLoadingEnabled_whenLocalOverrideTrue_returnsTrue`
2. `testIsSideLoadingEnabled_whenLocalOverrideFalse_returnsFalse_overridingDebugDefault` — precedence proof (override beats DEBUG-on)
3. `testIsSideLoadingEnabled_overrideRoundTrip_true_false_true` — round-trip through the production seam
4. `testIsSideLoadingEnabled_noOverride_followsSameDebugOnPrecedenceAsTriageBot` — DEBUG-on parity (see gotcha below)
5. `testSideLoadingFeatureFlag_mapsToRemoteConfigKey` — managerKey wiring (release path resolves to Remote Config, not silent default)

## KEY GOTCHA for the orchestrator / other modules
The **PalaceTests target does NOT define `DEBUG`** in its compilation conditions
(`SWIFT_ACTIVE_COMPILATION_CONDITIONS = LCP FEATURE_OVERDRIVE`), while the
**Palace module DOES** under Debug config (`DEBUG SIMPLYE FEATURE_DRM_CONNECTOR …`).
The contract's suggested "guard the assertion in `#if DEBUG`" approach is WRONG
for this repo: a test-side `#if DEBUG` always compiles the release branch and
diverges from the production `isSideLoadingEnabled` value (which was compiled WITH
DEBUG). My initial contract-literal test failed for exactly this reason. Fixed by
asserting **parity with `isTriageBotEnabled`** — both accessors are compiled in the
production module under identical flags and share the DEBUG-on precedence, so they
resolve identically with no override regardless of build config, and the assertion
fails if the `#if DEBUG return true` arm is dropped from `isSideLoadingEnabled`.
Modules C/D writing any DEBUG-dependent test should use the same parity pattern,
not a test-side `#if DEBUG`.

## DoD evidence
1. **SUT instantiation:** `grep -c "RemoteFeatureFlags(" …SideLoadingTests.swift` = **5** (≥2 required).
2. **Build clean:** `** BUILD SUCCEEDED **` (Palace scheme, iPhone 16 Pro).
3. **Test run:** `Executed 5 tests, with 0 failures` — `** TEST SUCCEEDED **`.
   xcresult: `/tmp/harness-palace-ios-141BD227-…/Logs/Test/Test-Palace-2026.07.01_10-22-45--0400.xcresult`
4. **Mutation** (`palace_mutate.py`, whole-file with coverage-gating; `--diff-only`
   sees nothing because changes are uncommitted per swarm rules):
   - **killed 2, survived 1, uncovered 14 → 66.7% covered kill rate (≥50%).**
   - My accessor's only mutation point, **L377 `#if DEBUG return true` → KILLED**.
     So **added-line (diff-scoped) kill rate = 100%**.
   - The lone survivor is **L120 `default: return false`** in `defaultValue` —
     pre-existing shared line. The contract explicitly bans testing it
     ("asserting a flag's default value … is fluff; test the RESOLUTION
     precedence instead"), and `sideLoadingEnabled` has a non-nil `managerKey`
     so its `defaultValue` is never consulted in resolution anyway. Not killed
     by design.
5. **check-test-name-vs-body.py:** `0 fake-wiring tests found` — exit 0.
6. **Scope-coverage audit:** all contract "Public surface added" items present
   (verified via the contract's grep-able criteria — all pass). No off-limits
   files touched. No dev-menu UI (contract assigns flag plumbing only).
7. **check-blast-radius.py --quiet:** exit 0.
8. **check-superpartner-spectrum.py --quiet:** exit 0.

## Grep-able contract criteria (all pass)
- `RemoteFeatureFlags(` in test = 5 (≥2) ✓
- `case sideLoadingEnabled = "side_loading_enabled"` in RemoteFeatureFlags.swift = 1 ✓
- `case sideLoadingEnabled = "side_loading_enabled"` in FirebaseManager.swift = 1 ✓
- `RemoteConfigKey.sideLoadingEnabled.rawValue` in FirebaseManager.swift = 1 (≥1) ✓
- test sets override `set(true` ×3 and `set(false` ×2 ✓
- superpartner exit 0 ✓

## Gaps / deferred
None. Full contract scope landed. Did NOT commit/push (per swarm rules — left in
working tree for orchestrator integration). `verify-pr.sh --quick` (full-suite
parity) deferred to the orchestrator integrate step per the plan.
