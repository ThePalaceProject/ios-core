# Module B — FeatureFlag (sideLoadingEnabled gate)

**Swarm:** swarm_495a88d9 (side-loading)
**Risk:** standard
**Depends on:** none (foundational — A/C/D consume the flag)
**Ticket:** PP-2679 ("test mode" gate), PP-2677

## Purpose
Add ONE remote feature flag, `sideLoadingEnabled`, that gates every side-loading
surface (Settings entry, catalog lane). Mirrors the `inAppPlaybackNavEnabled`
wiring pattern **but with the DEBUG-on precedence of `isTriageBotEnabled`**
(per locked decision #2: "Firebase remote default + local override, DEBUG-on").

This module owns the flag exclusively. Modules C (Settings + Manager) and D
(Lane) call `RemoteFeatureFlags.shared.isSideLoadingEnabled` (production) or an
injected `RemoteFeatureFlags` instance (tests) — they do NOT add flag plumbing.

## Public surface added
- `RemoteFeatureFlags.FeatureFlag.sideLoadingEnabled = "side_loading_enabled"`
  (new enum case).
- `RemoteFeatureFlags.FeatureFlag.managerKey` — add mapping
  `.sideLoadingEnabled → .sideLoadingEnabled`.
- `RemoteFeatureFlags.FeatureFlag.defaultValue` — `.sideLoadingEnabled` returns
  `false` (falls into the `default` arm; no edit needed unless you special-case).
- `static let sideLoadingLocalOverrideKey = "RemoteFeatureFlags.sideLoadingLocalOverride"`.
- `var isSideLoadingEnabled: Bool` — computed accessor. Precedence EXACTLY:
  1. UserDefaults local override (`defaults.object(forKey: Self.sideLoadingLocalOverrideKey) as? Bool`)
  2. `#if DEBUG` → `true`
  3. `isFeatureEnabled(.sideLoadingEnabled)` (Firebase)
- `FirebaseManager.RemoteConfigKey.sideLoadingEnabled = "side_loading_enabled"`
  (new enum case) + a default entry `NSNumber(value: false)` in
  `setDefaultValues()`.

## Files IN scope
- `Palace/FeatureFlags/RemoteFeatureFlags.swift` (modify — add case, managerKey
  arm, override key, accessor). Model on `isTriageBotEnabled` (:249-258) for the
  DEBUG-on precedence and `inAppPlaybackNavLocalOverrideKey` (:320) for naming.
- `Palace/AppInfrastructure/FirebaseManager.swift` (modify — add
  `RemoteConfigKey.sideLoadingEnabled` at :65-ish and its `setDefaults` entry at
  :112-ish). REQUIRED for remote gating to resolve; without it `managerKey`
  returns nil and the flag silently falls back to `defaultValue`.
- `PalaceTests/FeatureFlags/RemoteFeatureFlagsSideLoadingTests.swift` (NEW).

## Files OFF-LIMITS
- Any `Palace/MyBooks/Sideload/*` (Modules A/C).
- `Palace/CatalogUI/*` (Module D).
- `Palace/AppInfrastructure/AppContainer.swift` (Modules A/C + orchestrator).
- Do NOT remove or renumber existing FeatureFlag / RemoteConfigKey cases.

## Test contract
`RemoteFeatureFlagsSideLoadingTests` MUST construct
`RemoteFeatureFlags(defaults: UserDefaults(suiteName:)!)` (never `.shared`) and
prove:
1. `isSideLoadingEnabled` returns the local override when set to `true`, and to
   `false` (both directions — not just the on case).
2. Local override takes precedence over the DEBUG/Firebase fallback (set override
   `false`, assert `false` even though DEBUG would return `true`).
3. With no override set, DEBUG builds return `true` (guard the assertion in
   `#if DEBUG` so the release config test still compiles/passes).
Use a fresh suite per test; `removePersistentDomain(forName:)` in tearDown.

## Verification criteria (grep-able)
- SUT instantiation: `grep -c "RemoteFeatureFlags(" PalaceTests/FeatureFlags/RemoteFeatureFlagsSideLoadingTests.swift` ≥ 2.
- Flag case present: `grep -c 'case sideLoadingEnabled = "side_loading_enabled"' Palace/FeatureFlags/RemoteFeatureFlags.swift` == 1.
- RemoteConfigKey present: `grep -c 'case sideLoadingEnabled = "side_loading_enabled"' Palace/AppInfrastructure/FirebaseManager.swift` == 1.
- setDefaults entry: `grep -c 'RemoteConfigKey.sideLoadingEnabled.rawValue' Palace/AppInfrastructure/FirebaseManager.swift` ≥ 1.
- Override-precedence test body actually sets override to BOTH values:
  `grep -c 'sideLoadingLocalOverride' PalaceTests/FeatureFlags/RemoteFeatureFlagsSideLoadingTests.swift` ≥ 1
  AND the test asserts `false` outcome (multi-step-body check #3): grep the test
  for both `set(true` and `set(false` (or equivalent) on the override key.
- `check-superpartner-spectrum.py --quiet` exit 0 (new accessor `isSideLoadingEnabled`
  and enum case must have a referencing test).
- Build clean; `scripts/verify-pr.sh --quick` PASS.
