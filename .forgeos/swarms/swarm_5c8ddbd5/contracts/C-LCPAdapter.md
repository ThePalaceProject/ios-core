---
name: swarm_5c8ddbd5-contract-C-LCPAdapter
type: immutable
status: active
created: 2026-05-21
last_refresh: 2026-05-21
freshness_window: never
owners: [audiobook]
description: Module C — LCP adapter + recursive acquisition predicate
---

# Module C — LCP adapter + recursive acquisition predicate

## In-scope files (exclusive write)
- MODIFIED `Palace/Audiobooks/LCP/LCPAudiobooks.swift` (add `hasLCPAcquisition` + recursive helper + `AudiobookVendorAdapter` conformance via LCPAdapter; preserve `#if LCP` gate; do **NOT** remove `canOpenBook` — other call sites still use it)
- NEW `Palace/Audiobooks/Vendors/LCPAdapter.swift` (new, `#if LCP`-gated)
- NEW `PalaceTests/Audiobook/Vendors/LCPAdapterTests.swift`
- NEW `PalaceTests/Audiobook/LCPAcquisitionPredicateTests.swift`

## Out-of-scope (read-only)
- `Palace/Audiobooks/AudiobookLoader.swift` (Module D's territory)
- `Palace/Audiobooks/Vendors/*` (Modules A/B territory except the new `LCPAdapter.swift` file)
- `Palace/MyBooks/MyBooksDownloadCenter.swift` — escalate before touching; callers of `canOpenBook` there are the 3.0.3 hotfix surface — out of scope for this swarm; ship as Module C2 follow-up if needed
- All files in the swarm-wide don't-touch list

## Public types exposed

```swift
#if LCP
extension LCPAudiobooks {
    /// Recursive predicate that walks the entire acquisition chain
    /// (top-level type AND nested indirectAcquisitions[*].type) for the
    /// LCP license MIME. Catches Marketplace audiobooks regardless of
    /// which OPDS feed (XML /loans/ or JSON /groups/) populated the
    /// book record. Ports the 3.0.3 hotfix logic from commit ca2ff13b6.
    @objc static func hasLCPAcquisition(_ book: TPPBook) -> Bool
}

final class LCPAdapter: AudiobookVendorAdapter {
    init(downloadCenter: ..., networkExecutor: ..., fileManager: FileManager = .default)
    func canHandle(_ book: TPPBook) -> Bool  // delegates to LCPAudiobooks.hasLCPAcquisition
    func resolveManifest(for: TPPBook, completion: ...)
}
#endif
```

## Types consumed
- `AudiobookVendorAdapter` protocol (Module A)
- `LCPAudiobooks` (existing, modified to add `hasLCPAcquisition`)
- `DRMDecryptor` (toolkit)

## Behavior carve-out

`LCPAdapter` wraps the following code from pre-swarm `AudiobookLoader.swift`:
- Lines 149-164 (initial LCP source check)
- `prepareLCPSource`, `loadLCPContent`, `redownloadLCPLicense` helpers (lines 222-341)

All four helpers move into `LCPAdapter`. The Loader stops compiling those methods once Module D rewrites the dispatch.

## Tests owned (named cases)

**LCPAcquisitionPredicateTests** (no `#if LCP` — file-level guard, predicate is `@objc`)
- `testHasLCPAcquisition_topLevelLCPMime_returnsTrue` — the `/loans/` XML feed shape — `defaultAcquisition.type` is the LCP license
- `testHasLCPAcquisition_nestedLCPInIndirectChain_returnsTrue` — the `/groups/` JSON feed shape — top-level is `opds-publication+json`, LCP MIME nested in `indirectAcquisitions[*].type`. **THIS IS THE PP-4407 REGRESSION KILL POINT** — `canOpenBook` returns false on this fixture, `hasLCPAcquisition` returns true. Comment must reference PP-4407 and commit `ca2ff13b6`.
- `testHasLCPAcquisition_doublyNestedIndirectChain_returnsTrue` — defends recursion depth > 1
- `testHasLCPAcquisition_noLCPAnywhere_returnsFalse` — OpenAccess audiobook fixture
- `testHasLCPAcquisition_audiobookContentType_required` — an LCP-typed EPUB book (not an audiobook) must return false

**LCPAdapterTests**
- `testCanHandle_marketplaceJSONFeedFixture_returnsTrue` — the PP-4407 case
- `testCanHandle_xmlFeedLCPFixture_returnsTrue`
- `testCanHandle_openAccessAudiobook_returnsFalse`
- `testResolveManifest_localLCPAFile_usesLocalFile`
- `testResolveManifest_licenseFileExists_usesLicenseFile`
- `testResolveManifest_neitherLocalNorLicense_redownloadsLicense`
- `testResolveManifest_redownloadFailure_failsWithLicenseDownloadFailed`
- `testResolveManifest_lcpInstantiationFailure_failsWithLcpInstantiationFailed`

## Acceptance criteria
- `LCPAdapter.swift` <=200 LOC
- New code in `LCPAudiobooks.swift` <=40 LOC (`hasLCPAcquisition` + private recursive helper)
- 100% mutation kill rate on `hasLCPAcquisition` (the recursion is the load-bearing logic — its mutants must be killed)
- 100% mutation kill rate on `LCPAdapter.canHandle` and `resolveManifest`
- `LCPAcquisitionPredicateTests` includes the explicit PP-4407 fixture shape and asserts the `canOpenBook`-vs-`hasLCPAcquisition` divergence — a comment on that test **must reference PP-4407 and the 3.0.3 hotfix commit `ca2ff13b6`** so the regression intent is searchable.

## Implementer prompt

You are Module C implementer for swarm_5c8ddbd5. The recursive `hasLCPAcquisition` predicate is the load-bearing fix — it's how the adapter pattern catches the Marketplace OPDS shape PP-4407 hit. **Reference commit `ca2ff13b6` in code comments** so the architectural intent survives future archaeology.

The LCP source-loading logic (lines 149-164 + 222-341 of pre-swarm `AudiobookLoader.swift`) moves into `LCPAdapter` verbatim. `canOpenBook` **stays** in `LCPAudiobooks` for other callers (`MyBooksDownloadCenter`, `BookRegistrySync`, etc.) — do NOT delete it. Out-of-band Module C2 follow-up will migrate those callers in a separate PR.

Use `scripts/pbxproj_add_swift.rb` to add the 3 new files (LCPAdapter + 2 tests) to `Palace.xcodeproj`. LCPAdapter is `#if LCP`-gated — Palace-noDRM target excludes it via the compile gate.

Validate: `xcodebuild -project Palace.xcodeproj -scheme Palace -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build` succeeds; `-scheme Palace-noDRM` also succeeds; `test -only-testing:PalaceTests/LCPAcquisitionPredicateTests` passes.

When done, write `.forgeos/swarms/swarm_5c8ddbd5/transcripts/C-LCPAdapter.md` with: files added/modified, tests added, key decisions, any gaps for integrator (e.g. if MyBooksDownloadCenter's call to `canOpenBook` is shown to be wrong on Marketplace, flag for C2).

Do NOT commit. Do NOT push. Stage for the integrator.
