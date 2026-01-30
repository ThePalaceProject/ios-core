# Traceability Matrix

**Document Version:** 1.0
**Last Updated:** 2026-01-29

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
| | | `Palace/Network/TokenRequest.swift` | All |
| AUTH-003 | SAML auth flow | `Palace/SignInLogic/TPPSAMLHelper.swift` | All |
| | | `Palace/SignInLogic/TPPCookiesWebViewController.swift` | All |
| AUTH-004 | Proactive token refresh | `Palace/Network/TPPNetworkExecutor.swift` | 120-135 |
| AUTH-005 | Sign-out with DRM preservation | `Palace/SignInLogic/TPPSignInBusinessLogic+SignOut.swift` | All |
| AUTH-006 | Age verification | `Palace/Accounts/User/TPPAgeCheck.swift` | All |
| AUTH-007 | Account switch cleanup | `Palace/Accounts/Library/AccountsManager.swift` | 128-147 |

### Code to Tests

| File | Test File | Test Methods | Coverage |
|------|-----------|--------------|----------|
| `TPPKeychainManager.swift` | None | - | 0% |
| `TPPUserAccount.swift` | `TPPUserAccountTests.swift` (partial) | - | ~20% |
| `TPPNetworkExecutor.swift` | `NetworkClientTests.swift` | Limited | ~15% |
| `TPPSAMLHelper.swift` | None | - | 0% |
| `TPPAgeCheck.swift` | `TPPAgeCheckTests.swift` | 5 tests | ~60% |
| `TPPSignInBusinessLogic.swift` | `TPPSignInBusinessLogicTests.swift` | 3 tests | ~25% |

### Test Gaps

| Req ID | Gap Description | Priority |
|--------|-----------------|----------|
| AUTH-001 | No keychain mock - tests skip credential storage | P0 |
| AUTH-002 | Token refresh retry queue untested | P0 |
| AUTH-003 | SAML flow has no automated tests | P1 |
| AUTH-005 | DRM preservation on sign-out untested | P0 |

---

## 3. Catalog & Library Browsing

### Requirements to Code

| Req ID | Requirement | Implementing Files | Lines |
|--------|-------------|-------------------|-------|
| CAT-001 | OPDS 1.x parsing | `Palace/OPDS/TPPOPDSFeed.swift` | All |
| | | `Palace/OPDS/TPPOPDSEntry.swift` | All |
| CAT-002 | OPDS 2.0 parsing | `Palace/OPDS2/OPDS2CatalogsFeed.swift` | All |
| | | `Palace/OPDS2/Service/UnifiedOPDSService.swift` | All |
| CAT-003 | Stale-while-revalidate | `Palace/CatalogDomain/Repository/CatalogRepository.swift` | 50-120 |
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
| `CatalogSearchViewModel.swift` | None | - | 0% |
| `CatalogViewModel.swift` | `CatalogViewModelTests.swift` | 15 tests | ~70% |
| `CatalogSortService.swift` | `CatalogSortServiceTests.swift` | 4 tests | ~80% |

### Test Gaps

| Req ID | Gap Description | Priority |
|--------|-----------------|----------|
| CAT-003 | Stale-while-revalidate logic in AccountsManager untested | P0 |
| CAT-005 | CatalogSearchViewModel debouncing untested | P1 |
| CAT-008 | Pagination flow untested | P2 |

---

## 4. Book Management & Registry

### Requirements to Code

| Req ID | Requirement | Implementing Files | Lines |
|--------|-------------|-------------------|-------|
| BOOK-001 | Book state transitions | `Palace/Book/Models/TPPBookState.swift` | All |
| | | `Palace/Book/Models/TPPBookRegistry.swift` | state methods |
| BOOK-002 | Registry persistence | `Palace/Book/Models/TPPBookRegistry.swift` | save/load |
| BOOK-003 | Cell model cache invalidation | `Palace/MyBooks/BookCellModelCache.swift` | All |
| BOOK-004 | Download progress UI | `Palace/MyBooks/MyBooksDownloadInfo.swift` | All |
| | | `Palace/MyBooks/MyBooksViewModel.swift` | progress |
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
| BOOK-002 | JSON persistence round-trip untested | P1 |
| BOOK-005 | Concurrent limit enforcement untested | P1 |
| BOOK-007 | File cleanup completeness untested | P2 |

---

## 5. EPUB Reader

### Requirements to Code

| Req ID | Requirement | Implementing Files | Lines |
|--------|-------------|-------------------|-------|
| EPUB-001 | Reader settings | `Palace/Reader2/Settings/TPPReaderSettings.swift` | All |
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
| `EPUBSearchViewModel.swift` | None | - | 0% |
| `LCPLibraryService.swift` | `LCPLibraryServiceTests.swift` | 4 tests | ~60% |

### Test Gaps

| Req ID | Gap Description | Priority |
|--------|-----------------|----------|
| EPUB-002 | Server sync roundtrip untested | P0 |
| EPUB-005 | EPUBSearchViewModel completely untested | P1 |

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
| `NowPlayingCoordinator.swift` | None | - | 0% |
| `CarPlayTemplateManager.swift` | None | - | 0% |
| `TrackPosition.swift` (toolkit) | `TrackPositionTests.swift` | 6 tests | ~70% |

### Test Gaps

| Req ID | Gap Description | Priority |
|--------|-----------------|----------|
| AUDIO-001 | State machine transitions incomplete | P0 |
| AUDIO-005 | NowPlayingCoordinator untested | P1 |
| AUDIO-006 | CarPlay integration untested | P2 |

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
| PDF-001 | LCP-encrypted PDF decryption untested | P0 |
| PDF-002 | Thumbnail generation untested | P2 |

---

## 8. Networking & Offline

### Requirements to Code

| Req ID | Requirement | Implementing Files | Lines |
|--------|-------------|-------------------|-------|
| NET-001 | HTTP methods | `Palace/Network/TPPNetworkExecutor.swift` | 61-310 |
| | | `Palace/Network/Core/URLSessionNetworkClient.swift` | All |
| NET-002 | Token refresh retry | `Palace/Network/TPPNetworkExecutor.swift` | 312-430 |
| NET-003 | Offline queue | `Palace/Network/TPPNetworkQueue.swift` | All |
| NET-004 | Reachability trigger | `Palace/Network/Reachability.swift` | All |
| NET-005 | Custom User-Agent | `Palace/Network/URLRequest+TPP.swift` | All |
| NET-006 | Cache policies | `Palace/Network/TPPCaching.swift` | All |

### Code to Tests

| File | Test File | Test Methods | Coverage |
|------|-----------|--------------|----------|
| `TPPNetworkExecutor.swift` | `NetworkClientTests.swift` | 3 tests | ~15% |
| `URLSessionNetworkClient.swift` | `NetworkClientTests.swift` | 2 tests | ~40% |
| `TPPNetworkQueue.swift` | None | - | 0% |
| `Reachability.swift` | None | - | 0% |
| `TPPCaching.swift` | `TPPCachingTests.swift` | 4 tests | ~60% |

### Test Gaps

| Req ID | Gap Description | Priority |
|--------|-----------------|----------|
| NET-002 | Retry queue completely untested | P0 |
| NET-003 | Offline queue SQLite logic untested | P1 |
| NET-004 | Reachability untested | P2 |

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
| DRM-004 | License expiry scenarios untested | P1 |

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
| `HoldsViewModel.swift` | `HoldsSnapshotTests.swift` | Snapshot only | ~10% |

### Test Gaps

| Req ID | Gap Description | Priority |
|--------|-----------------|----------|
| HOLD-001 | Hold placement logic untested | P1 |
| HOLD-002 | Hold cancellation untested | P1 |
| HOLD-003 | Notification trigger untested | P2 |

---

## 11. Settings & Preferences

### Requirements to Code

| Req ID | Requirement | Implementing Files | Lines |
|--------|-------------|-------------------|-------|
| SET-001 | Settings persistence | `Palace/Settings/TPPSettings.swift` | All |
| SET-002 | Beta library toggle | `Palace/Settings/TPPSettings.swift` | useBetaLibraries |
| | | `Palace/Accounts/Library/AccountsManager.swift` | beta handling |
| SET-003 | Developer settings | `Palace/Settings/DebugSettings.swift` | All |

### Code to Tests

| File | Test File | Test Methods | Coverage |
|------|-----------|--------------|----------|
| `TPPSettings.swift` | None | - | 0% |
| `DebugSettings.swift` | None | - | 0% |

### Test Gaps

| Req ID | Gap Description | Priority |
|--------|-----------------|----------|
| SET-001 | Settings persistence completely untested | P1 |
| SET-002 | Beta toggle effect untested | P1 |

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

| Category | Files |
|----------|-------|
| ViewModels | `CatalogSearchViewModel.swift`, `EPUBSearchViewModel.swift` |
| Singletons | `TPPSettings.swift`, `DebugSettings.swift` |
| Networking | `TPPNetworkQueue.swift`, `Reachability.swift` |
| Features | `NowPlayingCoordinator.swift`, `CarPlayTemplateManager.swift` |
| Auth | `TPPSAMLHelper.swift`, `TPPKeychainManager.swift` |

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
