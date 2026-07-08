# Contract D — UserDefaultsIsolation

## Scope

Create `XCTestCase.testUserDefaults()` helper, migrate test sites that own UserDefaults state, audit per-site whether production interaction requires DI; add warn-only lint.

### Production seam audit finding (architect)

89 sites in production read `UserDefaults.standard`. The top concentrators (`Palace/Settings/TPPSettings.swift` and `Palace/FeatureFlags/RemoteFeatureFlags.swift` — exact paths to be verified by implementer) have NO DI seam. Test migration to per-test suiteName UserDefaults will only work for sites where production is ALSO reading from the injected defaults; otherwise the test exercises a different store than production and the test is meaningless.

**Scope-narrowing decision (orchestrator pinned)**: Contract D migrates ONLY:
- (i) test files where the test owns the UserDefaults state end-to-end (no production interaction with the same key). Migrate to `testUserDefaults()`.
- (ii) production files `TPPSettings.swift` and `RemoteFeatureFlags.swift`: add minimum DI via `private let defaults: UserDefaults = .standard` instance property (or constructor injection if call-sites allow without blast-radius). **NO fallbacks per intent anti-claim** — if a call site can't be cleanly migrated, document the deferral.
- (iii) all other production sites: documented gap, deferred to follow-up.

### Files (NEW)
- `PalaceTests/Support/XCTestCase+testUserDefaults.swift`
- `PalaceTests/Support/XCTestCase+testUserDefaultsTests.swift`
- `PalaceTests/MetaTests/UserDefaultsIsolationLintTests.swift` (**warn-only**)

### Files (MODIFY — test target)

13 test files with `UserDefaults.standard` — each audited at implementation time:

| File | Sites | Category | Notes |
|---|---|---|---|
| `PalaceTests/CoverageGapTests.swift` | 2 | (i) test-only state | Clean migrate |
| `PalaceTests/Settings/DownloadOnlyOnWiFiTests.swift` | 5 | (ii) interacts with TPPSettings | Requires prod DI; D owns AppContainer.production migration too |
| `PalaceTests/CatalogDomain/CatalogCacheKeyAndIsolationTests.swift` | 3 | audit at impl | Likely (ii) |
| `PalaceTests/CatalogDomain/CatalogRepositoryStaleWhileRevalidateTests.swift` | 3 | audit at impl | Likely (ii) |
| `PalaceTests/Audiobook/AudiobookIssueFixTests.swift` | 6 | (i) test-only build-key state | Clean migrate |
| `PalaceTests/AppInfrastructure/RemoteFeatureFlagsTests.swift` | 6 | (ii) interacts with RemoteFeatureFlags | Requires prod DI |
| `PalaceTests/Bookmarks/TPPBookmarkDeletionLogTests.swift` | 2 | audit at impl | |
| `PalaceTests/SignInLogic/ForceResetTests.swift` | 9 | audit at impl | |
| `PalaceTests/Accounts/AccountDetailsURLTests.swift` | 5 | audit at impl | |
| `PalaceTests/Accounts/AccountsManagerStateMachineWiringTests.swift` | 10 | audit at impl | Wiring test under PalaceWiringTestCase |
| `PalaceTests/Accounts/AccountsManagerTests.swift` | 7 sites + 21 AppContainer.production() | D owns this file end-to-end | A and B skip; D handles all polluter cleanup |

### Files (MODIFY — production seams, minimum DI)

- `Palace/Settings/TPPSettings.swift` (implementer to verify path) — add `private let defaults: UserDefaults` instance property, init from arg with `.standard` default. Audit blast radius: if every `TPPSettings` construction goes through `AppContainer._buildCachedAppContainer()` (single site), trivial. Otherwise scope-deferral.
- `Palace/FeatureFlags/RemoteFeatureFlags.swift` (implementer to verify path) — same pattern.

## Public surface (test target)

```swift
extension XCTestCase {
    func testUserDefaults(file: StaticString = #file, line: UInt = #line) -> UserDefaults
}
```

### Required behavior
- Returns a `UserDefaults(suiteName: "test-\(testClass)-\(UUID())")` per test invocation. Implementer chooses a stable-per-test or stable-per-call key — either is acceptable as long as the resetter cleans up.
- Registers a `SingletonResetRegistry` resetter that calls `removePersistentDomain(forName:)` on the suiteName at test end.
- The suiteName encodes `self.name` so per-test-class isolation is automatic.

## Whitelist (lint exceptions, **warn-only** initially)

| File | Reason |
|---|---|
| `PalaceTests/Support/XCTestCase+testUserDefaults.swift` | Helper itself |
| Integration tests with explicit `.standard` need | Document at migration time |
| `Palace/Packages/PalaceKeychain/**` tests | Out-of-target |

## Off-limits

- All A, B, C, E files
- Production files OUTSIDE the audited `TPPSettings` + `RemoteFeatureFlags` pair (i.e. do NOT add DI seams to `TPPBookmarkDeletionLog`, `TPPSignInBusinessLogic+ForceReset`, etc. — document the gap and stop, per intent anti-claim)

## Verification criteria

| # | Criterion | Command |
|---|---|---|
| 1 | Migration grep produces small documented list | `grep -rn "UserDefaults\.standard" PalaceTests --include="*.swift" \| grep -v "testUserDefaults\|Keychain\|XCTestCase+testUserDefaults"` matches whitelist |
| 2 | Production DI added safely | `git diff Palace/Settings/TPPSettings.swift Palace/FeatureFlags/RemoteFeatureFlags.swift` — verify `private let defaults: UserDefaults` added; no callers broken |
| 3 | Blast-radius exit 0 (no new public API) | `python3 scripts/check-blast-radius.py --quiet` |
| 4 | Lint warn-only | Test class compiles but does NOT XCTFail on existing exceptions; only warns via `XCTContext.runActivity` or skipped XCTFail with logging |
| 5 | Build clean | PASS |
| 6 | verify-pr.sh --quick | PASS |
| 7 | Mutation kill rate ≥ 50% on TPPSettings + RemoteFeatureFlags DI changes | `palace_mutate.py --diff-only` per modified prod file |

## Coordination notes

- **STOP / scope-deferral marker**: if blast-radius scan shows `TPPSettings` DI requires >5 caller changes, STOP and report BLOCKED. Options: (a) extend budget, (b) reduce D scope to only the (i) test-only-state files, (c) split into follow-up.
- For D, **the AppContainer.production() migration in the files D owns end-to-end IS D's responsibility** (not A's). Specifically: `Accounts/AccountsManagerTests.swift` (21 sites) and `Settings/DownloadOnlyOnWiFiTests.swift` (sites + UserDefaults).
