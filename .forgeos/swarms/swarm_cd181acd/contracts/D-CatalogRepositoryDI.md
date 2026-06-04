# Contract D — CatalogRepository UserDefaults DI

## Public API change

`Palace/Packages/PalaceCatalog/Sources/PalaceCatalog/CatalogRepository.swift` — 4 public initializers gain a trailing `defaults: UserDefaults = .standard` argument.

### Before
```swift
public init(api: CatalogAPI)
public init(api: CatalogAPI, accountID: @escaping () -> String?)
public init(api: CatalogAPI, now: @escaping () -> Date)
public init(api: CatalogAPI, accountID: @escaping () -> String?, now: @escaping () -> Date)
```

### After
```swift
public init(api: CatalogAPI, defaults: UserDefaults = .standard)
public init(api: CatalogAPI, accountID: @escaping () -> String?, defaults: UserDefaults = .standard)
public init(api: CatalogAPI, now: @escaping () -> Date, defaults: UserDefaults = .standard)
public init(api: CatalogAPI, accountID: @escaping () -> String?, now: @escaping () -> Date, defaults: UserDefaults = .standard)
```

## Rationale

Per swarm `swarm_47883816` D-cleanup follow-up: `CatalogRepository` was using `UserDefaults.standard` directly for its stale-cache key (`lastAppLaunchKey`). Tests in `PalaceTests/CatalogDomain/Catalog{CacheKeyAndIsolation,RepositoryStaleWhileRevalidate}Tests.swift` needed to inject an isolated `UserDefaults(suiteName:)` instance to verify cache-window logic deterministically, without polluting the process-wide `.standard` store.

## Blast radius

3 production callers preserved unchanged via the default-arg pattern:
- `AppContainer._buildCachedAppContainer` (Palace target — composition root)
- `CatalogViewModel` init (Palace target)
- `PalaceTests/CatalogDomain/Catalog*Tests.swift` (test target — now passes explicit `defaults:`)

No `?? .standard` fallback in the implementation per intent anti-claim — the field is `private let defaults: UserDefaults` set from the constructor arg.

## Test coverage

`Palace/Packages/PalaceCatalog/Tests/PalaceCatalogTests/CatalogRepositoryStaleWhileRevalidateTests` continues to pass; new test-target sites under PalaceTests/CatalogDomain pass with `defaults: testUserDefaults()`.

## Reviewer notes

- This is the SAME pattern as the parent swarm's TPPSettings + RemoteFeatureFlags DI (cs_d92d06e8) — narrow constructor injection, default arg preserves existing callers.
- The blast-radius reviewer in the parent swarm (`rev_1dfc9e56`) verified the same approach is OK; this is a follow-on application of the same pattern.
