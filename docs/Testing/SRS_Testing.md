# Software Requirements Specification: Testing

**Document Version:** 1.0
**Last Updated:** 2026-01-29
**Target Coverage:** 80%

---

## 1. Overview

This document defines functional and non-functional testing requirements for the Palace iOS codebase, establishing testability seams, naming conventions, and traceability between requirements, tests, and code ownership.

### 1.1 Scope

- **Unit Tests (XCTest):** Pure logic testing with mocked dependencies
- **Integration Tests:** Multi-module tests with fakes/stubs/network stubs
- **UI Tests (XCUITest):** End-to-end user flow validation
- **Snapshot Tests:** Visual regression via swift-snapshot-testing

### 1.2 Current State

| Metric | Value |
|--------|-------|
| Total Test Files | 119 |
| PalaceTests | 102 files |
| PalaceAudiobookToolkitTests | 13 files |
| Existing Mocks | 18 files |
| Snapshot Tests | 11 files |
| Accessibility Tests | 6 files |

---

## 2. Functional Requirements by Feature Area

### 2.1 Authentication & Sign-In

**Module:** `Palace/SignInLogic/`

| Req ID | Requirement | Test Type | Priority |
|--------|-------------|-----------|----------|
| AUTH-001 | Basic auth credentials stored securely in Keychain | Unit | P0 |
| AUTH-002 | OAuth token refresh on 401 response | Integration | P0 |
| AUTH-003 | SAML cookie-based auth flow completes | Integration | P0 |
| AUTH-004 | Token expiry triggers proactive refresh | Unit | P1 |
| AUTH-005 | Sign-out clears credentials without losing DRM activation | Unit | P0 |
| AUTH-006 | Age verification gate for under-13 content | Unit | P1 |
| AUTH-007 | Multi-library account switching clears active content | Integration | P1 |

**Key Classes to Test:**
- `TPPSignInBusinessLogic.swift:*` - Core orchestration
- `TPPReauthenticator.swift:*` - Re-auth flow
- `TPPBasicAuth.swift:*` - Basic HTTP auth
- `TPPCredentials.swift:*` - Credential model
- `TPPAgeCheck.swift:*` - Age verification

**Existing Tests:** `PalaceTests/SignInLogic/TPPBasicAuthTests.swift`, `TPPReauthenticatorTests.swift`, `TPPAgeCheckTests.swift`

---

### 2.2 Catalog & Library Browsing

**Module:** `Palace/CatalogUI/`, `Palace/CatalogDomain/`

| Req ID | Requirement | Test Type | Priority |
|--------|-------------|-----------|----------|
| CAT-001 | OPDS 1.x feed parsing extracts lanes, books, facets | Unit | P0 |
| CAT-002 | OPDS 2.0 feed parsing with authentication documents | Unit | P0 |
| CAT-003 | Stale-while-revalidate cache returns stale data while refreshing | Unit | P0 |
| CAT-004 | Cache expiry (24h) forces network fetch | Unit | P1 |
| CAT-005 | Search debouncing prevents excessive API calls | Unit | P1 |
| CAT-006 | Facet filtering updates UI optimistically | Unit | P1 |
| CAT-007 | Entry point navigation switches catalog context | Integration | P1 |
| CAT-008 | Pagination loads more results | Integration | P2 |

**Key Classes to Test:**
- `CatalogRepository.swift:*` - Data layer
- `CatalogViewModel.swift:*` - UI state
- `CatalogSearchViewModel.swift:*` - Search logic
- `CatalogSortService.swift:*` - Sorting
- `CatalogFilterService.swift:*` - Filtering
- `TPPOPDSFeed.swift:*` - OPDS 1.x parsing
- `OPDS2CatalogsFeed.swift:*` - OPDS 2.0 parsing

**Existing Tests:** `CatalogViewModelTests.swift`, `CatalogSortServiceTests.swift`, `OPDS2CatalogsFeedTests.swift`, `OPDSFeedParsingTests.swift`

---

### 2.3 Book Management & Registry

**Module:** `Palace/Book/`, `Palace/MyBooks/`

| Req ID | Requirement | Test Type | Priority |
|--------|-------------|-----------|----------|
| BOOK-001 | Book state transitions (Unowned → Downloading → Downloaded) | Unit | P0 |
| BOOK-002 | Registry persists to JSON and restores on launch | Unit | P0 |
| BOOK-003 | Book cell model cache invalidates on state change | Unit | P1 |
| BOOK-004 | Download progress updates UI reactively | Unit | P1 |
| BOOK-005 | Concurrent download limit (4) enforced | Unit | P1 |
| BOOK-006 | Download recovery after network failure | Integration | P1 |
| BOOK-007 | File cleanup removes orphaned downloads | Unit | P2 |

**Key Classes to Test:**
- `TPPBookRegistry.swift:*` - Central registry
- `TPPBook.swift:*` - Book model
- `TPPBookState.swift:*` - State enumeration
- `MyBooksDownloadCenter.swift:*` - Download coordination
- `MyBooksViewModel.swift:*` - UI state
- `BookDetailViewModel.swift:*` - Detail view state
- `BookCellModelCache.swift:*` - Cell caching

**Existing Tests:** `TPPBookStateTests.swift`, `TPPBookCreationTests.swift`, `MyBooksDownloadCenterTests.swift`, `BookButtonMapperTests.swift`, `BookCellModelStateTests.swift`

---

### 2.4 EPUB Reader

**Module:** `Palace/Reader2/`

| Req ID | Requirement | Test Type | Priority |
|--------|-------------|-----------|----------|
| EPUB-001 | Reader settings (font, size, theme) persist | Unit | P1 |
| EPUB-002 | Bookmark creation syncs to server | Integration | P0 |
| EPUB-003 | Reading position restores on reopen | Integration | P0 |
| EPUB-004 | Table of contents navigation works | Unit | P1 |
| EPUB-005 | In-book search finds matches | Unit | P1 |
| EPUB-006 | DRM-protected content decrypts correctly | Integration | P0 |

**Key Classes to Test:**
- `TPPReaderSettings.swift:*` - Reader preferences
- `TPPReaderBookmarksBusinessLogic.swift:*` - Bookmark sync
- `TPPReaderTOCBusinessLogic.swift:*` - TOC navigation
- `EPUBSearchViewModel.swift:*` - Search
- `TPPReadiumBookmark.swift:*` - Bookmark model

**Existing Tests:** `TPPReaderSettingsTests.swift`, `BookmarkBusinessLogicTests.swift`, `PositionSyncTests.swift`, `EPUBPositionTests.swift`

---

### 2.5 Audiobook Player

**Module:** `Palace/Audiobooks/`

| Req ID | Requirement | Test Type | Priority |
|--------|-------------|-----------|----------|
| AUDIO-001 | Playback state machine transitions correctly | Unit | P0 |
| AUDIO-002 | Chapter navigation updates position | Unit | P0 |
| AUDIO-003 | Listening position bookmarks sync | Integration | P0 |
| AUDIO-004 | Sleep timer stops playback at duration | Unit | P1 |
| AUDIO-005 | Now Playing info updates correctly | Unit | P1 |
| AUDIO-006 | CarPlay controls mirror app state | Integration | P2 |
| AUDIO-007 | Background playback continues | Integration | P1 |

**Key Classes to Test:**
- `AudiobookSessionManager.swift:*` - Session state
- `NowPlayingCoordinator.swift:*` - MPNowPlayingInfoCenter updates
- `AudiobookBookmarkBusinessLogic.swift:*` - Bookmark sync
- `AudiobookTimeTracker.swift:*` - Position tracking
- `PlaybackBootstrapper.swift:*` - Initialization

**Existing Tests:** `AudiobookPlaybackTests.swift`, `AudiobookBookmarkBusinessLogicTests.swift`, `AudiobookmarkTests.swift`, `AudiobookTOCTests.swift`, `AudiobookReliabilityTests.swift`

---

### 2.6 PDF Reader

**Module:** `Palace/PDF/`

| Req ID | Requirement | Test Type | Priority |
|--------|-------------|-----------|----------|
| PDF-001 | Encrypted PDFs decrypt with valid license | Integration | P0 |
| PDF-002 | Thumbnail generation caches efficiently | Unit | P1 |
| PDF-003 | Text extraction enables search | Unit | P1 |
| PDF-004 | Page navigation updates position | Unit | P1 |

**Key Classes to Test:**
- `TPPEncryptedPDFDocument.swift:*` - Encrypted PDF handling
- `TPPPDFDocument.swift:*` - PDF model
- `PDFDocumentProviding.swift:*` - Protocol for testing

**Existing Tests:** `PDFReaderTests.swift`

---

### 2.7 Networking & Offline

**Module:** `Palace/Network/`

| Req ID | Requirement | Test Type | Priority |
|--------|-------------|-----------|----------|
| NET-001 | GET/POST/PUT/DELETE execute with proper headers | Unit | P0 |
| NET-002 | Token refresh retries failed requests | Unit | P0 |
| NET-003 | Offline queue stores failed requests | Unit | P1 |
| NET-004 | Reachability monitor triggers queue processing | Integration | P1 |
| NET-005 | Custom User-Agent applied to all requests | Unit | P2 |
| NET-006 | Cache policies respected per request | Unit | P1 |

**Key Classes to Test:**
- `TPPNetworkExecutor.swift:*` - Request execution
- `URLSessionNetworkClient.swift:*` - Async wrapper
- `TPPNetworkQueue.swift:*` - Offline queue
- `Reachability.swift:*` - Connectivity monitor
- `TPPCaching.swift:*` - Cache configuration

**Existing Tests:** `NetworkClientTests.swift`, `TPPCachingTests.swift`, `URLRequest+NYPLTests.swift`

---

### 2.8 DRM & Content Protection

**Module:** `Palace/Reader2/ReaderStackConfiguration/`

| Req ID | Requirement | Test Type | Priority |
|--------|-------------|-----------|----------|
| DRM-001 | LCP license validates and decrypts | Integration | P0 |
| DRM-002 | Adobe DRM activation persists across sign-out | Integration | P0 |
| DRM-003 | Fulfillment downloads protected content | Integration | P1 |
| DRM-004 | License expiry prevents access | Unit | P1 |

**Key Classes to Test:**
- `LCPLibraryService.swift:*` - LCP integration
- `AdobeDRMLibraryService.swift:*` - Adobe DRM
- `LicensesService.swift:*` - License management

**Existing Tests:** `LCPLibraryServiceTests.swift`, `LCPAudiobooksTests.swift`, `LCPPDFsTests.swift`

---

### 2.9 Holds & Reservations

**Module:** `Palace/Holds/`

| Req ID | Requirement | Test Type | Priority |
|--------|-------------|-----------|----------|
| HOLD-001 | Place hold on unavailable book | Integration | P1 |
| HOLD-002 | Cancel hold removes reservation | Integration | P1 |
| HOLD-003 | Hold ready notification triggers | Integration | P2 |

**Key Classes to Test:**
- `HoldsViewModel.swift:*` - Holds state

**Existing Tests:** `HoldsSnapshotTests.swift`

---

### 2.10 Settings & Preferences

**Module:** `Palace/Settings/`

| Req ID | Requirement | Test Type | Priority |
|--------|-------------|-----------|----------|
| SET-001 | Settings persist via UserDefaults | Unit | P1 |
| SET-002 | Beta library toggle switches catalog | Integration | P1 |
| SET-003 | Developer settings hidden in production | Unit | P2 |

**Key Classes to Test:**
- `TPPSettings.swift:*` - Settings singleton
- `AccountDetailViewModel.swift:*` - Account settings

**Existing Tests:** `SettingsSnapshotTests.swift`

---

## 3. Non-Functional Requirements

### 3.1 Performance

| Req ID | Requirement | Metric | Test Type |
|--------|-------------|--------|-----------|
| PERF-001 | Catalog initial load < 2s on 4G | Time-to-first-paint | Performance |
| PERF-002 | Image cache hit rate > 90% | Cache statistics | Unit |
| PERF-003 | Book registry load < 500ms for 1000 books | Load time | Performance |
| PERF-004 | Chapter parsing optimization reduces memory | Memory delta | Performance |

**Existing Tests:** `PalaceTests/Performance/` (1 file)

### 3.2 Reliability

| Req ID | Requirement | Metric | Test Type |
|--------|-------------|--------|-----------|
| REL-001 | No data loss on crash during download | Recovery test | Integration |
| REL-002 | Offline mode gracefully degrades | Reachability mock | Integration |
| REL-003 | Token refresh retry limit prevents loops | Counter check | Unit |

### 3.3 Accessibility

| Req ID | Requirement | Standard | Test Type |
|--------|-------------|----------|-----------|
| A11Y-001 | All interactive elements have accessibility labels | WCAG AA | Unit |
| A11Y-002 | VoiceOver navigation follows logical order | WCAG AA | UI |
| A11Y-003 | Dynamic Type scales correctly | iOS HIG | Snapshot |

**Existing Tests:** `PalaceTests/Accessibility/` (6 files)

---

## 4. Test Patterns and Conventions

See `Test_Patterns.md` for complete patterns documentation.

### 4.1 Quick Reference

| Pattern | Use Case | Example |
|---------|----------|---------|
| Protocol Mock | Inject fake dependencies | `CatalogRepositoryMock` |
| HTTPStubURLProtocol | Stub network responses | Register handler, return `StubbedResponse` |
| @MainActor Test | Test UI-bound code | `@MainActor final class CatalogViewModelTests` |
| async test | Test async/await code | `func testLoad() async { }` |
| Snapshot | Visual regression | `assertSnapshot(matching: view, as: .image)` |

---

## 5. Architecture Seams for Testability

See `Test_Seams_Refactor_Plan.md` for complete seam implementation plan.

### 5.1 Current Testability Blockers

| Blocker | Location | Impact | Priority |
|---------|----------|--------|----------|
| `AccountsManager.shared` | `AccountsManager.swift:44` | Cannot inject mock accounts | P0 |
| `TPPNetworkExecutor.shared` | `TPPNetworkExecutor.swift:59` | Network calls untestable | P0 |
| `TPPBookRegistry.shared` | `TPPBookRegistry.swift:*` | State mutations affect all tests | P0 |
| `TPPUserAccount.sharedAccount()` | `TPPUserAccount.swift:*` | Keychain access in tests | P1 |
| `TPPSettings.shared` | `TPPSettings.swift:*` | UserDefaults pollution | P1 |
| 25+ other singletons | Various | Test isolation issues | P2 |

### 5.2 Recommended Seams

1. **Protocol extraction** for all singletons
2. **Initializer-based DI** with default to `.shared`
3. **Factory pattern** for complex object graphs
4. **Clock abstraction** for time-dependent code
5. **FileManager abstraction** for file operations

---

## 6. Naming Conventions

### 6.1 Test Files

```
<ClassUnderTest>Tests.swift          # Unit tests
<ClassUnderTest>IntegrationTests.swift   # Integration tests
<FeatureArea>SnapshotTests.swift     # Snapshot tests
<FeatureArea>UITests.swift           # UI tests
```

### 6.2 Test Methods

```swift
func test<MethodOrBehavior>_<Condition>_<ExpectedResult>()

// Examples:
func testLoad_WithNilURL_DoesNotCallRepository()
func testTokenRefresh_On401Response_RetriesRequest()
func testSignOut_WithActiveDRM_PreservesActivation()
```

### 6.3 Mock Classes

```swift
<ProtocolName>Mock.swift    # Protocol conforming mock
<ClassName>Fake.swift       # Simplified fake implementation
<ClassName>Stub.swift       # Predefined response stub
```

---

## 7. Folder Structure

```
PalaceTests/
├── Mocks/                      # Shared mock implementations
│   ├── CatalogRepositoryMock.swift
│   ├── TPPBookRegistryMock.swift
│   ├── NYPLNetworkExecutorMock.swift
│   └── ...
├── Fixtures/                   # Test data files (JSON, XML)
│   ├── OPDSFeeds/
│   ├── AuthenticationDocs/
│   └── Manifests/
├── Helpers/                    # Test utilities
│   ├── HTTPStubURLProtocol.swift
│   ├── URLSession+Stubbing.swift
│   └── TPPBookMocker.swift
├── <FeatureArea>/              # Feature-specific tests
│   ├── SignInLogic/
│   ├── CatalogUI/
│   ├── MyBooks/
│   ├── Reader2/
│   ├── Audiobook/
│   └── ...
├── Snapshots/                  # Snapshot tests
├── Accessibility/              # Accessibility tests
├── Performance/                # Performance tests
└── Integration/                # Cross-module integration tests
```

---

## 8. Traceability Matrix

See `Traceability_Matrix.md` for complete requirement-to-test mapping.

### 8.1 Coverage by Feature Area

| Feature | Requirements | Tests | Coverage % |
|---------|-------------|-------|------------|
| Authentication | 7 | 3 | ~43% |
| Catalog | 8 | 5 | ~63% |
| Book Management | 7 | 6 | ~86% |
| EPUB Reader | 6 | 4 | ~67% |
| Audiobook | 7 | 5 | ~71% |
| PDF Reader | 4 | 1 | ~25% |
| Networking | 6 | 3 | ~50% |
| DRM | 4 | 3 | ~75% |
| Holds | 3 | 1 | ~33% |
| Settings | 3 | 1 | ~33% |

---

## 9. Code Ownership

| Module | Owner | Test Responsibility |
|--------|-------|---------------------|
| `Palace/SignInLogic/` | Auth Team | Unit + Integration |
| `Palace/CatalogUI/` | Catalog Team | Unit + Snapshot |
| `Palace/MyBooks/` | Books Team | Unit + Integration |
| `Palace/Reader2/` | Reader Team | Unit + Integration |
| `Palace/Audiobooks/` | Audio Team | Unit + Integration |
| `Palace/Network/` | Platform Team | Unit + Integration |
| `Palace/Keychain/` | Platform Team | Unit |

---

## 10. Approval

| Role | Name | Date | Signature |
|------|------|------|-----------|
| Test Architect | | | |
| Engineering Lead | | | |
| Product Owner | | | |
