## Contract B — `.forgeos/swarms/swarm_d8f11437/contracts/B-AppContainer-testability-seam.md`

````markdown
# Module B — AppContainer testability seam (wave 4)

**Critical-path module.** Risk: AppContainer is the single composition root for the entire app. Any regression here breaks every production path. Architect + SoD (qa_test + clean_code) review required.

**Tiny scope.** ~25 LOC production + ~50 LOC tests. Lives in a SINGLE production file. The discipline is in the surface design, not the LOC count.

## Goal

Add a `withSignInModalSheetPresenter(_:)` modifier on `AppContainer` that returns a copy with an instance-local override field. The modifier enables Module A's required wiring test (and any future test that needs to inject a spy presenter without rewiring the production `_cached` singleton). Match SwiftUI modifier style for forward-compat with future test seams (auth coordinator, accounts manager, etc.).

## Resolved decision: Option (c) — `withSignInModalSheetPresenter(_:)` modifier

Justification (full reasoning in the architect output):
1. `AppContainer` is a `struct`. Modifier returns a new value with the override field set.
2. Existing init has 18 params. Option (a) bloats it; Option (b) duplicates the entire `_cached` composition (which has delicate dispatch_once re-entry hazards).
3. Modifier composes for future seams.
4. SwiftUI-idiomatic.

## Public types/protocols changing

**ADD to `AppContainer`:**
```swift
/// Instance-local override for `signInModalSheetPresenter`. Production
/// `_cached` value has this as `nil` — the computed property falls
/// through to the static cache. Tests set this via
/// `withSignInModalSheetPresenter(_:)` to inject a spy without
/// disturbing the global `_signInModalSheetPresenter` cache.
private let _signInModalSheetPresenterOverride: SignInModalSheetPresenter?

/// Returns a copy of this container with `signInModalSheetPresenter`
/// resolved from `presenter` instead of the static cache.
///
/// **Test-only seam.** Production code MUST NOT call this — the default
/// `signInModalSheetPresenter` resolved from `AppContainer.production()`
/// is the single composition-root instance. This modifier exists so
/// tests can inject a spy presenter via:
///     let testContainer = AppContainer.production().withSignInModalSheetPresenter(spy)
/// then pass `testContainer` (or rely on the override being preferred)
/// to the system-under-test.
///
/// Modifies a struct copy — does NOT mutate `self` or the static cache.
@MainActor
func withSignInModalSheetPresenter(_ presenter: SignInModalSheetPresenter) -> AppContainer
```

**MODIFY the existing computed property (line 40-45):**
```swift
@MainActor
var signInModalSheetPresenter: SignInModalSheetPresenter {
    if let override = _signInModalSheetPresenterOverride { return override }  // NEW
    if let cached = AppContainer._signInModalSheetPresenter { return cached }
    let presenter = SignInModalSheetPresenter(appContainer: self)
    AppContainer._signInModalSheetPresenter = presenter
    return presenter
}
```

**MODIFY the existing init (line 110):**
- Add an optional `signInModalSheetPresenterOverride: SignInModalSheetPresenter? = nil` param (defaults to nil so existing call sites are unchanged).
- Store it: `self._signInModalSheetPresenterOverride = signInModalSheetPresenterOverride`.

**ADD a private helper init (optional, implementer choice):**
- A package-private init `init(_replacing other: AppContainer, signInModalSheetPresenterOverride: SignInModalSheetPresenter?)` that copies every field from `other` and replaces the override. This keeps `withSignInModalSheetPresenter` to ~10 lines.

**UNCHANGED:**
- `AppContainer.production()` — returns the same `_cached` value as today; the new override field is nil in the cached instance.
- All 18 existing struct fields.
- The static `_signInModalSheetPresenter` cache — still primes from the same path; the override mechanism is independent.
- The `AppContainerKey: EnvironmentKey` — `defaultValue = AppContainer.production()` unchanged.

## Internal seams

- The instance-local `_signInModalSheetPresenterOverride` is a `let` (immutable per struct value). Modifier creates a new struct value.
- Static cache `AppContainer._signInModalSheetPresenter` is unaffected — overrides don't write to or read from it.
- Computed property check order: override first → static cache → lazy init. Maintains exactly-once semantics for the static cache (no double-init).
- Thread safety: `@MainActor`-isolated for the override branch; matches the existing computed property's `@MainActor` isolation.

## Test contracts

### NEW — `PalaceTests/AppInfrastructure/AppContainerWithSignInModalSheetPresenterTests.swift` (2 tests)

1. **`testWithSignInModalSheetPresenter_overrideValue_isPreferredOverStaticCache`**
   - Arrange: Get production container. Get the default `signInModalSheetPresenter` (which primes the static cache). Construct a distinct spy presenter via test seam (we can subclass `SignInModalSheetPresenter` with a fake driver per the wave 3 lifecycle test pattern).
   - Act: `let overridden = container.withSignInModalSheetPresenter(spy)`. Read `overridden.signInModalSheetPresenter`.
   - Assert: `overridden.signInModalSheetPresenter === spy` (identity match — the spy IS the resolved value); `container.signInModalSheetPresenter !== spy` (original container unchanged).
   - Kill case: a regression that ignores the override field in the computed property is observable.

2. **`testWithSignInModalSheetPresenter_productionContainer_fallsThroughToStaticCacheWhenOverrideNil`**
   - Arrange: Get production container directly (override is nil).
   - Act: Read `container.signInModalSheetPresenter` twice.
   - Assert: both reads return the SAME instance (`===`) — the static cache short-circuit still works; the override field being nil does NOT break the existing cache lookup.
   - Kill case: a regression that always returns a new instance (ignoring the cache) is observable.

## Files scoped to THIS implementer

**Production MODIFIED:**
- `Palace/AppInfrastructure/AppContainer.swift` — add field + computed-property branch + modifier + augmented init

**Tests NEW:**
- `PalaceTests/AppInfrastructure/AppContainerWithSignInModalSheetPresenterTests.swift`

**Tooling:**
- `ruby scripts/pbxproj_add_swift.rb --target PalaceTests PalaceTests/AppInfrastructure/AppContainerWithSignInModalSheetPresenterTests.swift`

## Files explicitly OFF-LIMITS

**Anti-scope (universal):** same as Module A.

**Off-limits per Module A ownership:** every file in Module A's manifest list. Module B touches `AppContainer.swift` exclusively.

**Off-limits per Module C ownership:** `scripts/check-test-name-vs-body.py`, `.claude/skills/swarm/SKILL.md`, `CLAUDE.md`.

## Verification criteria

1. **SUT instantiation check:**
   ```bash
   test -f PalaceTests/AppInfrastructure/AppContainerWithSignInModalSheetPresenterTests.swift
   grep -c "AppContainer.production()" PalaceTests/AppInfrastructure/AppContainerWithSignInModalSheetPresenterTests.swift  # MUST be ≥1
   grep -c "withSignInModalSheetPresenter" PalaceTests/AppInfrastructure/AppContainerWithSignInModalSheetPresenterTests.swift  # MUST be ≥2
   ```

2. **Modifier declared:**
   ```bash
   grep -c "func withSignInModalSheetPresenter" Palace/AppInfrastructure/AppContainer.swift  # MUST be 1
   ```

3. **Override field declared:**
   ```bash
   grep -c "_signInModalSheetPresenterOverride" Palace/AppInfrastructure/AppContainer.swift  # MUST be ≥3 (declaration + storage in init + read in computed property)
   ```

4. **Production `production()` unchanged in behavior:**
   ```bash
   git diff origin/develop -- Palace/AppInfrastructure/AppContainer.swift | grep -E "^[-+].*static func production" 
   # Either empty (signature unchanged — preferred) or shows only whitespace changes
   ```

5. **No new public init parameters required by callers:**
   ```bash
   # Verify production() and Environment default both still resolve without the new param
   grep -c "AppContainer(" Palace/ --include="*.swift" -r | awk -F: '{sum+=$2} END {print sum}'
   # MUST be the same as origin/develop (the new param has a default nil, no caller change required)
   ```

6. **No force unwraps:**
   ```bash
   git diff origin/develop -- Palace/AppInfrastructure/AppContainer.swift \
                              PalaceTests/AppInfrastructure/AppContainerWithSignInModalSheetPresenterTests.swift \
     | grep -E '^\+.*[a-zA-Z_]!([. ;)\[])' | grep -v '!=' | grep -v '// '
   # MUST be empty
   ```

7. **No new `.shared` reads:**
   ```bash
   git diff origin/develop -- Palace/AppInfrastructure/AppContainer.swift | grep -E '^\+.*\.shared'
   # Existing .shared (UserAccountPublisher.shared, ImageCache.shared) UNCHANGED; no NEW ones
   ```

8. **Existing tests still green:**
   ```bash
   xcodebuild ... -only-testing:PalaceTests/AppInfrastructure/AppContainerWithSignInModalSheetPresenterTests test
   xcodebuild ... -only-testing:PalaceTests/SignInLogic/SignInModalLifecycleTests test  # wave-3 tests use AppContainer.production() — must still resolve
   ```

9. **Mutation kill-rate:**
   ```bash
   python3 scripts/palace_mutate.py --file Palace/AppInfrastructure/AppContainer.swift \
     --tests PalaceTests/AppInfrastructure/AppContainerWithSignInModalSheetPresenterTests \
     --diff-only --diff-base origin/develop
   ```
   Kill rate MUST be ≥80% diff-scoped on the new field + computed-property branch + modifier. Paste `Killed: X / Y (Z%)` lines.

10. **Build + verify-pr:**
    ```bash
    scripts/verify-pr.sh --quick
    ```
    MUST PASS. Paste tails.

## Implementer prompt (one paragraph)

You are Module B implementer for `swarm_d8f11437` (wave 4 of the 3.2.0 close-out). Add a `withSignInModalSheetPresenter(_:)` modifier on `AppContainer` (which is a `struct` in `Palace/AppInfrastructure/AppContainer.swift`) — returns a copy of `self` with an instance-local override field set; the existing `signInModalSheetPresenter` computed property reads the override first, falls through to the static `_signInModalSheetPresenter` cache when nil. Add an optional `signInModalSheetPresenterOverride: SignInModalSheetPresenter? = nil` param to the existing 18-param `init` (defaults to nil so existing callers, including `production()`, are unchanged). The modifier's purpose is test-only: Module A's wiring test injects a spy presenter to verify `TPPReauthenticator().authenticateIfNeeded(...)` actually routes through the AppContainer-injected presenter (closes wall-failure cs_9a267b63). Add 2 tests in a new file `PalaceTests/AppInfrastructure/AppContainerWithSignInModalSheetPresenterTests.swift`: (1) override is preferred over static cache, (2) production fall-through still works when override is nil. Use `ruby scripts/pbxproj_add_swift.rb --target PalaceTests` for the new test file. Mutation kill-rate ≥80% diff-scoped on the modified `AppContainer.swift`. NO file other than `Palace/AppInfrastructure/AppContainer.swift` and `PalaceTests/AppInfrastructure/AppContainerWithSignInModalSheetPresenterTests.swift`. Module A and Module C own everything else. If you find that adding the override field requires breaking changes to `AppContainer.production()` or any of the 18 existing init params, STOP with BLOCKED — the modifier should be PURELY additive (one new optional param + one new field + one new method + one new branch in the existing computed property).
````

---
