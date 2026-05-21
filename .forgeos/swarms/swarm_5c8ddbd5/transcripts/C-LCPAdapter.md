# Module C — LCP adapter + recursive acquisition predicate

**Status:** complete (transcript written by integrator after agent stream timeout — files were fully written and verified disjoint before timeout)

## Files added/modified

| File | Status | LOC | Notes |
|---|---|---:|---|
| `Palace/Audiobooks/LCP/LCPAudiobooks.swift` | modified | +37 | `hasLCPAcquisition(_:)` `@objc static` + recursive helper added; `canOpenBook` preserved for non-audiobook callers (MyBooksDownloadCenter, BookRegistrySync) per contract |
| `Palace/Audiobooks/Vendors/LCPAdapter.swift` | new | 199 | `#if LCP`-gated. `AudiobookVendorAdapter` conformance. Carves LCP source-loading from pre-swarm AudiobookLoader.swift:149-164 + 222-341 (prepareLCPSource, loadLCPContent, redownloadLCPLicense) verbatim. Within ≤200 LOC budget. |
| `PalaceTests/Audiobook/LCPAcquisitionPredicateTests.swift` | new | 188 | 5 named tests per contract |
| `PalaceTests/Audiobook/Vendors/LCPAdapterTests.swift` | new | 370 | 8 named tests per contract (LOC higher than expected — includes realistic fixtures and mocks) |

## Tests added

**LCPAcquisitionPredicateTests** (5 tests)
- `testHasLCPAcquisition_topLevelLCPMime_returnsTrue` — the `/loans/` XML feed shape
- `testHasLCPAcquisition_nestedLCPInIndirectChain_returnsTrue` — **PP-4407 REGRESSION KILL POINT** — the `/groups/` JSON feed shape Marketplace returns. Comment references PP-4407 + commit `ca2ff13b6` per contract requirement.
- `testHasLCPAcquisition_doublyNestedIndirectChain_returnsTrue` — defends recursion depth > 1
- `testHasLCPAcquisition_noLCPAnywhere_returnsFalse` — OpenAccess audiobook fixture
- `testHasLCPAcquisition_audiobookContentType_required` — LCP-typed EPUB rejected

**LCPAdapterTests** (8 tests per contract — names follow contract spec)
- `testCanHandle_marketplaceJSONFeedFixture_returnsTrue` (PP-4407 case)
- `testCanHandle_xmlFeedLCPFixture_returnsTrue`
- `testCanHandle_openAccessAudiobook_returnsFalse`
- `testResolveManifest_localLCPAFile_usesLocalFile`
- `testResolveManifest_licenseFileExists_usesLicenseFile`
- `testResolveManifest_neitherLocalNorLicense_redownloadsLicense`
- `testResolveManifest_redownloadFailure_failsWithLicenseDownloadFailed`
- `testResolveManifest_lcpInstantiationFailure_failsWithLcpInstantiationFailed`

## Validation (pre-timeout)

- `xcodebuild -scheme Palace build`: completed (per agent's earlier successful run)
- `xcodebuild -scheme Palace-noDRM build`: completed (LCPAdapter excluded via `#if LCP`)
- `xcodebuild test -only-testing:PalaceTests/LCPAcquisitionPredicateTests`: completed
- Module B implementer noted "Module C's LCPAdapter.swift had a transient TPPNetworkExecutor conformance build error during my first build; later builds succeeded" — flagged for integrator second-look

## Key decisions

1. **`hasLCPAcquisition` is `@objc static`** so it's callable from existing ObjC callers and from future C2 follow-up migrations of `MyBooksDownloadCenter`.
2. **`canOpenBook` preserved** in LCPAudiobooks — other callers still depend on it. Module C2 follow-up migrates those.
3. **LCPAdapter source-loading helpers moved verbatim** from AudiobookLoader.swift:222-341. No semantic changes. Module D's tests gate end-to-end behavior preservation.
4. **PP-4407 + ca2ff13b6 references in code comments** per contract requirement — searchable for future archaeology.

## Gaps for integrator

- **Integrator should run a second xcodebuild build** to confirm Module B's flag about transient TPPNetworkExecutor conformance build error has cleared. Module C's files on disk should compile cleanly against current branch state.
- **Module C2 follow-up out of scope for this swarm:** `MyBooksDownloadCenter.swift` and `BookRegistrySync` still call `canOpenBook` (the top-level-only predicate). They should migrate to `hasLCPAcquisition` in a follow-up PR — escalating to integrator rather than expanding this swarm's scope.
- **Agent timed out at the final transcript-write step.** All files staged correctly before timeout per the directory state at integrator verification time. No work lost.
