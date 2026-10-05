# Traceability Matrix

**Document Version:** 1.0
**Last Updated:** 2026-01-29 (rows that claimed missing tests corrected 2026-10-05)

> **Status:** the requirement rows, test counts and coverage percentages are a 2026-01-29 snapshot and are not maintained. On 2026-10-05 each row that said a file or behavior had no tests was checked against `PalaceTests/` and corrected to name the test file; other rows, the summary statistics in section 13 and the appendix in section 15 were not re-measured. Some implementing files listed below have since moved or been removed (for example `Palace/Utilities/FileCleanup.swift`, `Palace/Reader2/BusinessLogic/PositionSync.swift`, `Palace/PDF/Model/TPPEncryptedPDFDocument.swift`).

---

## 1. Overview

This document maps requirements to their implementing code and corresponding tests, establishing traceability for the Palace iOS test coverage initiative.

---

## 2. Authentication & Sign-In

### Requirements to Code

| Req ID | Requirement | Implementing Files | Lines |
|--------|-------------|-------------------|-------|
| AUTH-001 | Secure credential storage | `Palace/Keychain/TPPKeychainManager.swift` | All |
| | | `Palace/Accounts/User/TPPUserAccount.swift` | All |
| AUTH-002 | OAuth token refresh | `Palace/Network/TPPNetworkExecutor.swift` | 312-430 |
| | | `Palace/Packages/PalaceAuth/Sources/PalaceAuth/TokenRequest.swift` | All |
| AUTH-003 | SAML auth flow | `Palace/Packages/PalaceAuth/Sources/PalaceAuth/TPPSAMLHelper.swift` | All |
| | | `Palace/SignInLogic/TPPCookiesWebViewController.swift` | All |
| AUTH-004 | Proactive token refresh | `Palace/Network/TPPNetworkExecutor.swift` | 120-135 |
| AUTH-005 | Sign-out with DRM preservation | `Palace/SignInLogic/TPPSignInBusinessLogic+SignOut.swift` | All |
| AUTH-006 | Age verification | `Palace/Accounts/AgeCheck/TPPAgeCheck.swift` | All |
| AUTH-007 | Account switch cleanup | `Palace/Accounts/Library/AccountsManager.swift` | 128-147 |

### Code to Tests

| File | Test File | Test Methods | Coverage |
|------|-----------|--------------|----------|
| `TPPKeychainManager.swift` | `Keychain/TPPKeychainManagerTests.swift`; credential storage in `Palace/Packages/PalaceKeychain/Tests/PalaceKeychainTests/` | 9 tests (archive decoding, error logging); package: 17 tests | Not measured |
| `TPPUserAccount.swift` | `TPPUserAccountTests.swift` (partial) | - | ~20% |
| `TPPNetworkExecutor.swift` | `NetworkClientTests.swift` | Limited | ~15% |
| `TPPSAMLHelper.swift` | `SignInLogic/TPPSAMLFlowTests.swift` | 31 tests | Not measured |
| `TPPAgeCheck.swift` | `TPPAgeCheckTests.swift` | 5 tests | ~60% |
| `TPPSignInBusinessLogic.swift` | `TPPSignInBusinessLogicTests.swift` | 3 tests | ~25% |

### Test Gaps

| Req ID | Gap Description | Priority |
|--------|-----------------|----------|
| AUTH-001 | Credential store/read round trips are covered in `Palace/Packages/PalaceKeychain/Tests/PalaceKeychainTests/` (for example `test_setObject_roundtripsStringAndNumber`); `PalaceTests/Keychain/TPPKeychainManagerTests.swift` covers archive decoding and error logging. `validateKeychain`, `updateKeychainForBackgroundFetch` and the keychain cleanup path have no tests | P0 |
| AUTH-002 | Retry queue covered by `Network/TokenRefreshAndRetryQueueTests.swift` (single-flight refresh, queued retry with new bearer, 401 and network-error paths); not re-audited for completeness | P0 |
| AUTH-003 | SAML sign-in, logout and helper covered by `TPPSAMLFlowTests.swift`, `TPPSAMLSignInTests.swift`, `TPPSAMLLogoutTests.swift`; the IdP web page itself is not exercised | P1 |
| AUTH-005 | Covered by `SignInLogic/TPPSignInBusinessLogicSignOutTests.swift` (deauthorize ordering, Adobe activation preserved on a stale callback); not re-audited for completeness | P0 |

---

## 3. Catalog & Library Browsing

### Requirements to Code

| Req ID | Requirement | Implementing Files | Lines |
|--------|-------------|-------------------|-------|
| CAT-001 | OPDS 1.x parsing | `Palace/Packages/PalaceCatalog/Sources/PalaceCatalog/TPPOPDSFeed.swift` | All |
| | | `Palace/Packages/PalaceCatalog/Sources/PalaceCatalog/TPPOPDSEntry.swift` | All |
| CAT-002 | OPDS 2.0 parsing | `Palace/Packages/PalaceCatalog/Sources/PalaceCatalog/OPDS2CatalogsFeed.swift` | All |
| | | `Palace/OPDS2/Service/UnifiedOPDSService.swift` | All |
| CAT-003 | Stale-while-revalidate | `Palace/Packages/PalaceCatalog/Sources/PalaceCatalog/CatalogRepository.swift` | 50-120 |
| | | `Palace/Accounts/Library/AccountsManager.swift` | 216-265 |
| CAT-004 | Cache expiry | `Palace/Accounts/Library/AccountsManager.swift` | 7-29 |
| CAT-005 | Search debouncing | `Palace/CatalogUI/ViewModels/CatalogSearchViewModel.swift` | All |
| CAT-006 | Optimistic facet updates | `Palace/CatalogUI/ViewModels/CatalogViewModel.swift` | facet methods |
| CAT-007 | Entry point navigation | `Palace/CatalogUI/ViewModels/CatalogViewModel.swift` | entry point methods |
| CAT-008 | Pagination | `Palace/CatalogUI/ViewModels/CatalogLaneMoreViewModel.swift` | All |

### Code to Tests

| File | Test File | Test Methods | Coverage |
|------|-----------|--------------|----------|
| `TPPOPDSFeed.swift` | `OPDSFeedParsingTests.swift` | 8 tests | ~50% |
| `OPDS2CatalogsFeed.swift` | `OPDS2CatalogsFeedTests.swift` | 6 tests | ~60% |
| `CatalogRepository.swift` | `CatalogRepositoryTests.swift` (partial) | 2 tests | ~20% |
| `CatalogSearchViewModel.swift` | `CatalogUI/CatalogSearchViewModelTests.swift` | 67 tests | Not measured |
| `CatalogViewModel.swift` | `CatalogViewModelTests.swift` | 15 tests | ~70% |
| `CatalogSortService.swift` | `CatalogSortServiceTests.swift` | 4 tests | ~80% |

### Test Gaps

| Req ID | Gap Description | Priority |
|--------|-----------------|----------|
| CAT-003 | Cache freshness covered by `Accounts/AccountsManagerCacheTests.swift` (stale and expired thresholds) and `CatalogDomain/CatalogRepositoryStaleWhileRevalidateTests.swift`; not re-audited for completeness | P0 |
| CAT-005 | Debouncing covered by `CatalogSearchViewModelTests.swift` (`testSearch_Debounces_*`, `testSearch_CancelsDebounce_OnNewQuery`) | P1 |
| CAT-008 | `ViewModels/CatalogLaneMoreViewModelTests.swift` covers pagination state (`nextPageURL`, `isLoadingMore`); no test name refers to fetching the next page | P2 |

---

## 4. Book Management & Registry

### Requirements to Code

| Req ID | Requirement | Implementing Files | Lines |
|--------|-------------|-------------------|-------|
| BOOK-001 | Book state transitions | `Palace/Packages/PalaceBookModel/Sources/PalaceBookModel/TPPBookState.swift` | All |
| | | `Palace/Packages/PalaceBookRegistry/Sources/PalaceBookRegistry/TPPBookRegistry.swift` | state methods |
| BOOK-002 | Registry persistence | `Palace/Packages/PalaceBookRegistry/Sources/PalaceBookRegistry/TPPBookRegistry.swift` | save/load |
| BOOK-003 | Cell model cache invalidation | `Palace/MyBooks/MyBooks/BookCell/BookCellModelCache.swift` | All |
| BOOK-004 | Download progress UI | `Palace/MyBooks/MyBooksDownloadInfo.swift` | All |
| | | `Palace/MyBooks/MyBooks/MyBooksViewModel.swift` | progress |
| BOOK-005 | Concurrent download limit | `Palace/MyBooks/MyBooksDownloadCenter.swift` | coordinator |
| BOOK-006 | Download recovery | `Palace/MyBooks/DownloadErrorRecovery.swift` | All |
| BOOK-007 | File cleanup | `Palace/Utilities/FileCleanup.swift` | All |

### Code to Tests

| File | Test File | Test Methods | Coverage |
|------|-----------|--------------|----------|
| `TPPBookState.swift` | `TPPBookStateTests.swift` | 6 tests | ~80% |
| `TPPBookRegistry.swift` | `TPPBookRegistryRecordTests.swift` | 4 tests | ~30% |
| `BookCellModelCache.swift` | `BookCellModelCacheInvalidationTests.swift` | 3 tests | ~60% |
| `MyBooksDownloadCenter.swift` | `MyBooksDownloadCenterTests.swift` | 5 tests | ~25% |
| `MyBooksViewModel.swift` | `MyBooksViewModelTests.swift` | 2 tests | ~20% |
| `DownloadErrorRecovery.swift` | `DownloadRecoveryTests.swift` | 3 tests | ~50% |

### Test Gaps

| Req ID | Gap Description | Priority |
|--------|-----------------|----------|
| BOOK-002 | Round trip covered by `BookRegistry/TPPBookRegistryPersistenceTests.swift` (save then cold-start load, corrupted and truncated JSON) | P1 |
| BOOK-005 | `Decomp/DownloadThrottlingContractTests.swift` (2 tests) covers cap propagation and re-pumping the pending queue; enforcement under load is not covered | P1 |
| BOOK-007 | `Palace/Utilities/FileCleanup.swift` no longer exists; requirement needs re-mapping | P2 |

---

## 5. EPUB Reader

### Requirements to Code

| Req ID | Requirement | Implementing Files | Lines |
|--------|-------------|-------------------|-------|
| EPUB-001 | Reader settings | `Palace/Reader2/ReaderSettings/TPPReaderSettings.swift` | All |
| EPUB-002 | Bookmark sync | `Palace/Reader2/BusinessLogic/TPPReaderBookmarksBusinessLogic.swift` | All |
| | | `Palace/Reader2/Bookmarks/TPPAnnotations.swift` | All |
| EPUB-003 | Position restore | `Palace/Reader2/BusinessLogic/PositionSync.swift` | All |
| EPUB-004 | TOC navigation | `Palace/Reader2/BusinessLogic/TPPReaderTOCBusinessLogic.swift` | All |
| EPUB-005 | In-book search | `Palace/Reader2/UI/EpubSearchView/EPUBSearchViewModel.swift` | All |
| EPUB-006 | DRM decryption | `Palace/Reader2/ReaderStackConfiguration/LCP/LCPLibraryService.swift` | All |
| | | `Palace/Reader2/ReaderStackConfiguration/AdobeDRM/AdobeDRMLibraryService.swift` | All |

### Code to Tests

| File | Test File | Test Methods | Coverage |
|------|-----------|--------------|----------|
| `TPPReaderSettings.swift` | `TPPReaderSettingsTests.swift` | 5 tests | ~70% |
| `TPPReaderBookmarksBusinessLogic.swift` | `BookmarkBusinessLogicTests.swift` | 4 tests | ~40% |
| `TPPAnnotations.swift` | Partial mocking | - | ~20% |
| `PositionSync.swift` | `PositionSyncTests.swift` | 3 tests | ~50% |
| `EPUBSearchViewModel.swift` | `Reader2/EPUBSearchViewModelTests.swift` | 18 tests | Not measured |
| `LCPLibraryService.swift` | `LCPLibraryServiceTests.swift` | 4 tests | ~60% |

### Test Gaps

| Req ID | Gap Description | Priority |
|--------|-----------------|----------|
| EPUB-002 | Sync decision logic in `Crawl/CrossDeviceBookmarkSyncTests.swift`; save/delete call order in `Contract/Reader2BookmarkContractTests.swift`; a round trip against a server response is not covered | P0 |
| EPUB-005 | `EPUBSearchViewModelTests.swift` covers query handling, results, errors, cancellation and batch fetch | P1 |

---

## 6. Audiobook Player

### Requirements to Code

| Req ID | Requirement | Implementing Files | Lines |
|--------|-------------|-------------------|-------|
| AUDIO-001 | Playback state machine | `Palace/Audiobooks/AudiobookSessionManager.swift` | All |
| AUDIO-002 | Chapter navigation | `ios-audiobooktoolkit/...TrackPosition.swift` | All |
| AUDIO-003 | Bookmark sync | `Palace/Reader2/Bookmarks/AudiobookBookmarkBusinessLogic.swift` | All |
| AUDIO-004 | Sleep timer | `ios-audiobooktoolkit/...SleepTimer.swift` | All |
| AUDIO-005 | Now Playing info | `Palace/Audiobooks/NowPlayingCoordinator.swift` | All |
| AUDIO-006 | CarPlay | `Palace/CarPlay/CarPlayTemplateManager.swift` | All |
| AUDIO-007 | Background playback | `Palace/Audiobooks/PlaybackBootstrapper.swift` | All |

### Code to Tests

| File | Test File | Test Methods | Coverage |
|------|-----------|--------------|----------|
| `AudiobookSessionManager.swift` | `AudiobookPlaybackTests.swift` | 5 tests | ~40% |
| `AudiobookBookmarkBusinessLogic.swift` | `AudiobookBookmarkBusinessLogicTests.swift` | 4 tests | ~50% |
| `NowPlayingCoordinator.swift` | `Audiobooks/NowPlayingCoordinatorTests.swift`, `NowPlayingCoordinatorBackgroundTests.swift` | 19 + 6 tests | Not measured |
| `CarPlayTemplateManager.swift` | `CarPlay/CarPlayTests.swift` (partial) | `shouldShowOpenAppAlert` only | Not measured |
| `TrackPosition.swift` (toolkit) | `TrackPositionTests.swift` | 6 tests | ~70% |

### Test Gaps

| Req ID | Gap Description | Priority |
|--------|-----------------|----------|
| AUDIO-001 | State machine transitions incomplete; see `Audiobooks/AudiobookSessionStateTests.swift` and `Audiobook/AudiobookSessionManagerTests.swift` for current coverage | P0 |
| AUDIO-005 | Covered by `NowPlayingCoordinatorTests.swift` and `NowPlayingCoordinatorBackgroundTests.swift`; not re-audited for completeness | P1 |
| AUDIO-006 | `CarPlay/CarPlayTests.swift` and `CarPlayAuthHelperReadinessTests.swift` cover CarPlay helpers; template construction in `CarPlayTemplateManager` is largely not covered | P2 |

---

## 7. PDF Reader

### Requirements to Code

| Req ID | Requirement | Implementing Files | Lines |
|--------|-------------|-------------------|-------|
| PDF-001 | Encrypted PDF decryption | `Palace/PDF/Model/TPPEncryptedPDFDocument.swift` | All |
| PDF-002 | Thumbnail caching | `Palace/PDF/Model/TPPPDFDocument.swift` | thumbnail methods |
| PDF-003 | Text extraction | `Palace/PDF/Model/TPPPDFDocument.swift` | text methods |
| PDF-004 | Page navigation | `Palace/PDF/View/TPPEncryptedPDFViewer.swift` | All |

### Code to Tests

| File | Test File | Test Methods | Coverage |
|------|-----------|--------------|----------|
| `TPPEncryptedPDFDocument.swift` | `PDFReaderTests.swift` | 2 tests | ~30% |
| `TPPPDFDocument.swift` | `PDFReaderTests.swift` | Partial | ~20% |
| `MockPDFDocument.swift` | Exists | - | N/A |

### Test Gaps

| Req ID | Gap Description | Priority |
|--------|-----------------|----------|
| PDF-001 | `PDF/LCPPDFDiskExtractTests.swift` covers validating the extracted PDF on disk; decryption itself is not covered | P0 |
| PDF-002 | Covered by `PDF/PDFKitThumbnailProviderTests.swift` (5 tests) | P2 |

---

## 8. Networking & Offline

### Requirements to Code

| Req ID | Requirement | Implementing Files | Lines |
|--------|-------------|-------------------|-------|
| NET-001 | HTTP methods | `Palace/Network/TPPNetworkExecutor.swift` | 61-310 |
| | | `Palace/Network/Core/URLSessionNetworkClient.swift` | All |
| NET-002 | Token refresh retry | `Palace/Network/TPPNetworkExecutor.swift` | 312-430 |
| NET-003 | Offline queue | `Palace/Network/TPPNetworkQueue.swift` | All |
| NET-004 | Reachability trigger | `Palace/Packages/PalaceNetwork/Sources/PalaceNetwork/Reachability.swift` | All |
| NET-005 | Custom User-Agent | `Palace/Network/URLRequest+TPP.swift` | All |
| NET-006 | Cache policies | `Palace/Packages/PalaceNetwork/Sources/PalaceNetwork/TPPCaching.swift` | All |

### Code to Tests

| File | Test File | Test Methods | Coverage |
|------|-----------|--------------|----------|
| `TPPNetworkExecutor.swift` | `NetworkClientTests.swift` | 3 tests | ~15% |
| `URLSessionNetworkClient.swift` | `NetworkClientTests.swift` | 2 tests | ~40% |
| `TPPNetworkQueue.swift` | `Network/NetworkQueueTests.swift` | 22 tests | Not measured |
| `Reachability.swift` | `Network/ReachabilityTests.swift` | 10 tests | Not measured |
| `TPPCaching.swift` | `TPPCachingTests.swift` | 4 tests | ~60% |

### Test Gaps

| Req ID | Gap Description | Priority |
|--------|-----------------|----------|
| NET-002 | Covered by `Network/TokenRefreshAndRetryQueueTests.swift`; see AUTH-002 | P0 |
| NET-003 | Covered by `Network/NetworkQueueTests.swift` (insert failures, credential stripping, per-row drain); not re-audited for completeness | P1 |
| NET-004 | `Network/ReachabilityTests.swift` covers status reporting by interface type | P2 |

---

## 9. DRM & Content Protection

### Requirements to Code

| Req ID | Requirement | Implementing Files | Lines |
|--------|-------------|-------------------|-------|
| DRM-001 | LCP validation | `Palace/Reader2/ReaderStackConfiguration/LCP/LCPLibraryService.swift` | All |
| | | `Palace/Reader2/ReaderStackConfiguration/LCP/LicensesService.swift` | All |
| DRM-002 | Adobe DRM persistence | `adept-ios/ADEPT/...` | External |
| DRM-003 | Fulfillment download | `Palace/Reader2/ReaderStackConfiguration/DRMLibraryService.swift` | fulfill |
| DRM-004 | License expiry | `Palace/Reader2/ReaderStackConfiguration/LCP/LicensesService.swift` | expiry |

### Code to Tests

| File | Test File | Test Methods | Coverage |
|------|-----------|--------------|----------|
| `LCPLibraryService.swift` | `LCPLibraryServiceTests.swift` | 4 tests | ~60% |
| `LCPAudiobooks` | `LCPAudiobooksTests.swift` | 3 tests | ~50% |
| `LCPPDFs` | `LCPPDFsTests.swift` | 2 tests | ~40% |

### Test Gaps

| Req ID | Gap Description | Priority |
|--------|-----------------|----------|
| DRM-002 | Adobe DRM in external module - hard to test | P1 |
| DRM-004 | `ErrorHandling/LoanExpiryHandlingTests.swift` covers loan-term problem detection and expiry messages; LCP license expiry in `LicensesService` is not covered | P1 |

---

## 10. Holds & Reservations

### Requirements to Code

| Req ID | Requirement | Implementing Files | Lines |
|--------|-------------|-------------------|-------|
| HOLD-001 | Place hold | `Palace/Holds/HoldsViewModel.swift` | place hold |
| HOLD-002 | Cancel hold | `Palace/Holds/HoldsViewModel.swift` | cancel |
| HOLD-003 | Hold ready notification | `Palace/Notifications/...` | TBD |

### Code to Tests

| File | Test File | Test Methods | Coverage |
|------|-----------|--------------|----------|
| `HoldsViewModel.swift` | `Holds/HoldsViewModelTests.swift`, `ViewModels/HoldsReducerTests.swift`, `HoldsSnapshotTests.swift` | 52 + 11 tests + snapshots | Not measured |

### Test Gaps

| Req ID | Gap Description | Priority |
|--------|-----------------|----------|
| HOLD-001 | `HoldsViewModelTests.swift` covers listing, filtering and badge counts, not placement; reserve-state transitions are in `ViewModels/BorrowReducerTests.swift`. Not re-audited end to end | P1 |
| HOLD-002 | `BorrowReducerTests.swift` covers the manage-hold and return-confirmed transitions; the cancel request itself is not re-audited | P1 |
| HOLD-003 | Hold classification of incoming notifications covered by `Notifications/NotificationServiceTests.swift`; the trigger that schedules a hold-ready notification is not re-audited | P2 |

---

## 11. Settings & Preferences

### Requirements to Code

| Req ID | Requirement | Implementing Files | Lines |
|--------|-------------|-------------------|-------|
| SET-001 | Settings persistence | `Palace/Packages/PalacePreferences/Sources/PalacePreferences/TPPSettings.swift` | All |
| SET-002 | Beta library toggle | `Palace/Packages/PalacePreferences/Sources/PalacePreferences/TPPSettings.swift` | useBetaLibraries |
| | | `Palace/Accounts/Library/AccountsManager.swift` | beta handling |
| SET-003 | Developer settings | `Palace/Settings/Debug/DebugSettings.swift` | All |

### Code to Tests

| File | Test File | Test Methods | Coverage |
|------|-----------|--------------|----------|
| `TPPSettings.swift` | `Settings/TPPSettingsTests.swift` | 6 tests | Not measured |
| `DebugSettings.swift` | `Settings/DebugSettingsTests.swift` | 33 tests | Not measured |

### Test Gaps

| Req ID | Gap Description | Priority |
|--------|-----------------|----------|
| SET-001 | `Settings/TPPSettingsTests.swift` exists (6 tests); persistence across launches is not re-audited | P1 |
| SET-002 | `TPPSettingsTests.swift` covers the `useBetaLibraries` publisher and notification; the effect on the library list in `AccountsManager` is not covered | P1 |

---

## 12. Accessibility

### Requirements to Code

| Req ID | Requirement | Implementing Files | Lines |
|--------|-------------|-------------------|-------|
| A11Y-001 | Accessibility labels | All UI components | Various |
| A11Y-002 | VoiceOver order | All UI components | Various |
| A11Y-003 | Dynamic Type | All UI components | Various |

### Code to Tests

| File | Test File | Test Methods | Coverage |
|------|-----------|--------------|----------|
| Various | `AccessibilityLabelTests.swift` | 4 tests | ~30% |
| Various | `AudiobookAccessibilityTests.swift` | 3 tests | ~40% |
| Various | `CatalogAccessibilityTests.swift` | 3 tests | ~30% |
| Various | `ReaderAccessibilityTests.swift` | 2 tests | ~20% |
| Various | `SearchAccessibilityTests.swift` | 2 tests | ~20% |
| Various | `FacetToolbarAccessibilityTests.swift` | 2 tests | ~40% |

### Test Gaps

| Req ID | Gap Description | Priority |
|--------|-----------------|----------|
| A11Y-001 | Many components lack label verification | P1 |
| A11Y-002 | VoiceOver order rarely tested | P1 |
| A11Y-003 | Dynamic Type scaling not verified | P2 |

---

## 13. Summary Statistics

### Coverage by Feature Area

| Feature Area | Requirements | Fully Tested | Partially Tested | Untested |
|-------------|-------------|--------------|------------------|----------|
| Authentication | 7 | 1 | 3 | 3 |
| Catalog | 8 | 2 | 4 | 2 |
| Book Management | 7 | 2 | 4 | 1 |
| EPUB Reader | 6 | 1 | 4 | 1 |
| Audiobook | 7 | 1 | 4 | 2 |
| PDF Reader | 4 | 0 | 2 | 2 |
| Networking | 6 | 1 | 2 | 3 |
| DRM | 4 | 1 | 2 | 1 |
| Holds | 3 | 0 | 1 | 2 |
| Settings | 3 | 0 | 0 | 3 |
| Accessibility | 3 | 0 | 3 | 0 |
| **Total** | **58** | **9 (16%)** | **29 (50%)** | **20 (34%)** |

### Priority Distribution of Gaps

| Priority | Count | Percentage |
|----------|-------|------------|
| P0 (Critical) | 12 | 26% |
| P1 (High) | 22 | 48% |
| P2 (Medium) | 12 | 26% |

### Files with Zero Test Coverage

Every file this table listed on 2026-01-29 now has a test file; see the corrected rows above.

---

## 14. Recommended Test Priorities

### Week 1-2 (Foundation)

1. **AUTH-002:** Token refresh retry queue
2. **CAT-003:** Stale-while-revalidate cache
3. **BOOK-002:** Registry persistence
4. **NET-002:** Network retry logic

### Week 3-4 (Core Features)

1. **EPUB-002:** Bookmark server sync
2. **AUDIO-001:** Playback state machine
3. **CAT-005:** Search debouncing
4. **NET-003:** Offline queue

### Week 5-6 (Coverage Expansion)

1. **A11Y-001:** Accessibility label coverage
2. **PDF-001:** Encrypted PDF tests
3. **HOLD-001/002:** Hold actions
4. **SET-001:** Settings persistence

---

## 15. Appendix: Test File Index

### Existing Test Files by Feature

```
PalaceTests/
├── Accessibility/
│   ├── AccessibilityLabelTests.swift
│   ├── AudiobookAccessibilityTests.swift
│   ├── CatalogAccessibilityTests.swift
│   ├── FacetToolbarAccessibilityTests.swift
│   ├── ReaderAccessibilityTests.swift
│   └── SearchAccessibilityTests.swift
├── Accounts/
│   └── AccountsManagerCacheTests.swift
├── Audiobook/
│   ├── AudiobookDataManagerModelsTests.swift
│   ├── AudiobookReliabilityTests.swift
│   └── AudiobookTOCTests.swift
├── BookStateManagement/
│   ├── BookButtonMapperTests.swift
│   ├── BookCellModelCacheInvalidationTests.swift
│   ├── BookCellModelStateTests.swift
│   └── TPPBookRegistryRecordTests.swift
├── Bookmarks/
│   └── TPPBookmarkSpecTests.swift
├── CarPlay/
│   └── (none)
├── CatalogUI/
│   ├── CatalogLaneRowViewAccessibilityTests.swift
│   └── CatalogViewModelTests.swift
├── ConcurrencyTests/
│   └── DownloadRecoveryTests.swift
├── ErrorHandling/
│   └── NSErrorAdditionsTests.swift
├── LCP/
│   ├── LCPAudiobooksTests.swift
│   ├── LCPLibraryServiceTests.swift
│   └── LCPPDFsTests.swift
├── Mocks/
│   ├── CatalogRepositoryMock.swift
│   ├── MockImageCache.swift
│   ├── MockPDFDocument.swift
│   ├── MockPDFDocumentMetadata.swift
│   ├── NYPLLibraryAccountsProviderMock.swift
│   ├── NYPLNetworkExecutorMock.swift
│   ├── TPPAgeCheckChoiceStorageMock.swift
│   ├── TPPAnnotationMock.swift
│   ├── TPPBookRegistryMock.swift
│   ├── TPPCurrentLibraryAccountProviderMock.swift
│   ├── TPPDRMAuthorizingMock.swift
│   ├── TPPMyBooksDownloadsCenterMock.swift
│   ├── TPPSignInOutBusinessLogicUIDelegateMock.swift
│   ├── TPPURLSettingsProviderMock.swift
│   ├── TPPUserAccountMock.swift
│   └── TPPUserAccountProviderMock.swift
├── MyBooks/
│   ├── MyBooksDownloadCenterExtendedTests.swift
│   └── MyBooksViewModelTests.swift
├── Network/
│   └── NetworkClientTests.swift
├── OPDS2/
│   ├── OPDS2AuthenticationDocumentTests.swift
│   ├── OPDS2FeedParsingTests.swift
│   ├── OPDS2FeedTests.swift
│   ├── OPDSFeedCacheTests.swift
│   └── OPDSFeedServiceTests.swift
├── PDF/
│   └── PDFReaderTests.swift
├── Performance/
│   └── (1 file)
├── Reader/
│   └── EPUBPositionTests.swift
├── Reader2/
│   ├── BookmarkBusinessLogicTests.swift
│   ├── PositionSyncTests.swift
│   └── TPPReaderSettingsTests.swift
├── SignInLogic/
│   ├── TPPBasicAuthTests.swift
│   └── TPPReauthenticatorTests.swift
├── Snapshots/
│   ├── AudiobookPlayerSnapshotTests.swift
│   ├── BookDetailSnapshotTests.swift
│   ├── CatalogSnapshotTests.swift
│   ├── FacetsSelectorSnapshotTests.swift
│   ├── HoldsSnapshotTests.swift
│   ├── MyBooksSnapshotTests.swift
│   ├── PDFViewsSnapshotTests.swift
│   ├── ReservationsSnapshotTests.swift
│   ├── SearchSnapshotTests.swift
│   ├── SettingsSnapshotTests.swift
│   └── SnapshotTestConfiguration.swift
├── Utilities/
│   ├── DeviceOrientationTests.swift
│   ├── StringExtensionTests.swift
│   └── URLExtensionTests.swift
└── Root-level tests (34 files)
```
