# Test Coverage Roadmap

**Target:** 80% Code Coverage
**Timeline:** 6 Weeks
**Current Estimate:** ~35-40% coverage

---

## Executive Summary

This roadmap provides a prioritized, incremental plan to achieve 80% test coverage in the Palace iOS codebase. Each stage includes specific targets, test types, expected coverage gains, and risk mitigation strategies.

---

## Stage 1: Foundation & Quick Wins (Weeks 1-2)

### Objectives
- Establish testing infrastructure improvements
- Add high-value, low-risk unit tests
- Create reusable mock factories

### 1.1 Infrastructure Setup (Week 1, Days 1-3)

**Files to Create/Modify:**

| File | Action | Purpose |
|------|--------|---------|
| `PalaceTests/TestSupport/TestDependencyContainer.swift` | Create | Centralized mock injection |
| `PalaceTests/TestSupport/Clock.swift` | Create | Time abstraction for testing |
| `PalaceTests/TestSupport/FileManagerMock.swift` | Create | File system abstraction |
| `PalaceTests/Mocks/TPPSettingsMock.swift` | Create | Settings mock |
| `PalaceTests/Mocks/AccountsManagerMock.swift` | Create | Accounts mock |
| `PalaceTests/Fixtures/` | Organize | Consolidate test fixtures |

**Production Files to Refactor:**

| File | Change | Risk Level |
|------|--------|------------|
| `Palace/Settings/TPPSettings.swift` | Extract `TPPSettingsProviding` protocol | Low |
| `Palace/Accounts/Library/AccountsManager.swift` | Add init with injected network executor | Medium |

**Expected Coverage Delta:** +2%

---

### 1.2 ViewModel Unit Tests (Week 1, Days 4-5)

**Target ViewModels (already have DI support):**

| ViewModel | File | Tests to Add |
|-----------|------|--------------|
| CatalogSearchViewModel | `Palace/CatalogUI/ViewModels/CatalogSearchViewModel.swift` | Debouncing, error states, pagination |
| EPUBSearchViewModel | `Palace/Reader2/UI/EpubSearchView/EPUBSearchViewModel.swift` | Search execution, result handling |
| HoldsViewModel | `Palace/Holds/HoldsViewModel.swift` | Hold actions, refresh |
| BookDetailViewModel | `Palace/Book/UI/BookDetail/BookDetailViewModel.swift` | State transitions, actions |

**Test Files to Create:**

```
PalaceTests/CatalogUI/CatalogSearchViewModelTests.swift
PalaceTests/Reader2/EPUBSearchViewModelTests.swift
PalaceTests/Holds/HoldsViewModelTests.swift
PalaceTests/Book/BookDetailViewModelTests.swift
```

**Expected Coverage Delta:** +5%

---

### 1.3 Pure Logic Unit Tests (Week 2)

**Target: Classes with no singleton dependencies**

| Class | File | Test Focus |
|-------|------|------------|
| CatalogFilter | `Palace/CatalogUI/Models/CatalogFilter.swift` | Property storage |
| CatalogFilterGroup | `Palace/CatalogUI/Models/CatalogFilterGroup.swift` | Filter management |
| CatalogLaneModel | `Palace/CatalogUI/Models/CatalogLaneModel.swift` | Lane construction |
| TPPReaderSettings | `Palace/Reader2/Settings/TPPReaderSettings.swift` | Serialization |
| TPPBookState | `Palace/Book/Models/TPPBookState.swift` | State transitions |
| TPPCredentials | `Palace/SignInLogic/TPPCredentials.swift` | Credential handling |
| CatalogCacheMetadata | `Palace/Accounts/Library/AccountsManager.swift:7-29` | Cache freshness |
| TokenResponse | `Palace/Network/TokenRequest.swift` | Token parsing |

**Test Files to Create:**

```
PalaceTests/CatalogUI/CatalogModelsTests.swift
PalaceTests/SignInLogic/TPPCredentialsTests.swift
PalaceTests/Network/TokenResponseTests.swift
PalaceTests/Accounts/CatalogCacheMetadataTests.swift
```

**Expected Coverage Delta:** +5%

---

### Stage 1 Summary

| Metric | Target |
|--------|--------|
| New Test Files | 10-12 |
| Tests Added | ~80-100 |
| Coverage Delta | +12% |
| Ending Coverage | ~47-52% |

### Risks & Mitigation

| Risk | Probability | Impact | Mitigation |
|------|-------------|--------|------------|
| Protocol extraction breaks ObjC interop | Medium | High | Keep `@objc` on protocol, test incrementally |
| Test flakiness from async code | Medium | Medium | Use `XCTestExpectation` with timeouts |
| Mock complexity grows | Low | Medium | Use factory pattern, limit mock scope |

---

## Stage 2: High-Value Coverage Expansion (Weeks 3-4)

### Objectives
- Add tests for critical business logic
- Implement network stubbing across tests
- Cover authentication and download flows

### 2.1 Authentication Tests (Week 3, Days 1-3)

**Target Files:**

| File | Test Focus | Priority |
|------|------------|----------|
| `TPPSignInBusinessLogic.swift` | OAuth flow, sign-out, DRM preservation | P0 |
| `TPPReauthenticator.swift` | Re-auth triggers, completion | P0 |
| `TPPNetworkExecutor.swift:312-430` | Token refresh, retry queue | P0 |
| `TPPAgeCheck.swift` | Age verification states | P1 |

**Tests to Add:**

```swift
// PalaceTests/SignInLogic/TPPSignInBusinessLogicTests.swift
func testSignIn_WithValidCredentials_StoresInKeychain()
func testSignIn_WithOAuth_RequestsToken()
func testSignOut_PreservesAdobeDRMActivation()
func testSignOut_ClearsCredentials()

// PalaceTests/Network/TokenRefreshTests.swift
func testTokenRefresh_On401_RetriesFailedRequest()
func testTokenRefresh_AlreadyInProgress_QueuesRequest()
func testTokenRefresh_FailsWith401_PresentsSignIn()
```

**Expected Coverage Delta:** +4%

---

### 2.2 Book Registry & Download Tests (Week 3, Days 4-5)

**Target Files:**

| File | Test Focus | Priority |
|------|------------|----------|
| `TPPBookRegistry.swift` | State persistence, publishers | P0 |
| `MyBooksDownloadCenter.swift` | Concurrent limits, recovery | P0 |
| `DownloadCoordinator` (actor) | Lock-free coordination | P1 |

**Tests to Add:**

```swift
// PalaceTests/BookStateManagement/TPPBookRegistryTests.swift
func testRegistry_SavesAndLoadsFromDisk()
func testRegistry_PublishesStateChanges()
func testRegistry_HandlesCorruptedJSON()

// PalaceTests/MyBooks/MyBooksDownloadCenterConcurrencyTests.swift
func testDownload_EnforcesConcurrentLimit()
func testDownload_QueuesExcessDownloads()
func testDownload_RecoveriesAfterNetworkFailure()
```

**Expected Coverage Delta:** +4%

---

### 2.3 OPDS Parsing Tests (Week 4, Days 1-2)

**Target Files:**

| File | Test Focus | Priority |
|------|------------|----------|
| `TPPOPDSFeed.swift` | OPDS 1.x parsing | P0 |
| `OPDS2CatalogsFeed.swift` | OPDS 2.0 parsing | P0 |
| `TPPOPDSEntry.swift` | Entry extraction | P1 |
| `TPPOPDSLink.swift` | Link relations | P1 |

**Fixtures to Add:**

```
PalaceTests/Fixtures/OPDSFeeds/
├── opds1_catalog.xml
├── opds1_search_results.xml
├── opds1_with_facets.xml
├── opds2_catalog.json
├── opds2_auth_document.json
└── opds2_publication.json
```

**Expected Coverage Delta:** +3%

---

### 2.4 Catalog Repository Tests (Week 4, Days 3-5)

**Target Files:**

| File | Test Focus | Priority |
|------|------------|----------|
| `CatalogRepository.swift` | Stale-while-revalidate | P0 |
| `DefaultCatalogAPI.swift` | Network integration | P0 |
| `OPDSFeedService.swift` | Feed caching | P1 |

**Tests to Add:**

```swift
// PalaceTests/CatalogDomain/CatalogRepositoryTests.swift
func testLoadCatalog_WithFreshCache_ReturnsCachedData()
func testLoadCatalog_WithStaleCache_ReturnsAndRefreshes()
func testLoadCatalog_WithExpiredCache_FetchesFromNetwork()
func testLoadCatalog_NetworkFailure_FallsBackToCache()
```

**Expected Coverage Delta:** +4%

---

### Stage 2 Summary

| Metric | Target |
|--------|--------|
| New Test Files | 8-10 |
| Tests Added | ~60-80 |
| Coverage Delta | +15% |
| Ending Coverage | ~62-67% |

### Risks & Mitigation

| Risk | Probability | Impact | Mitigation |
|------|-------------|--------|------------|
| Keychain tests fail in CI | High | High | Mock keychain access, skip real keychain tests in CI |
| Network stubbing incomplete | Medium | Medium | Use HTTPStubURLProtocol consistently |
| Test data out of sync with production | Medium | Low | Generate fixtures from real API responses |

---

## Stage 3: UI & Integration Hardening (Weeks 5-6)

### Objectives
- Add comprehensive snapshot tests
- Implement end-to-end integration tests
- Cover accessibility requirements
- Establish UI tests for critical paths

### 3.1 Snapshot Test Expansion (Week 5, Days 1-3)

**Existing Snapshots to Expand:**

| File | Additional Snapshots |
|------|---------------------|
| `CatalogSnapshotTests.swift` | Loading state, error state, empty state, dark mode |
| `BookDetailSnapshotTests.swift` | All book states, download progress |
| `MyBooksSnapshotTests.swift` | Empty library, downloading, mixed states |
| `AudiobookPlayerSnapshotTests.swift` | Playing, paused, sleep timer |

**New Snapshot Tests:**

```
PalaceTests/Snapshots/
├── SignInSnapshotTests.swift         # Sign-in flows
├── ReaderSettingsSnapshotTests.swift # Reader appearance
├── CarPlaySnapshotTests.swift        # CarPlay UI
└── ErrorStateSnapshotTests.swift     # Error presentations
```

**Expected Coverage Delta:** +3%

---

### 3.2 Accessibility Test Expansion (Week 5, Days 4-5)

**Existing Accessibility Tests to Expand:**

| File | Additional Tests |
|------|-----------------|
| `CatalogAccessibilityTests.swift` | Lane navigation, filter controls |
| `AudiobookAccessibilityTests.swift` | Player controls, chapter list |
| `ReaderAccessibilityTests.swift` | Settings, TOC |

**New Accessibility Tests:**

```swift
// PalaceTests/Accessibility/BookDetailAccessibilityTests.swift
func testBookDetail_AllButtonsHaveLabels()
func testBookDetail_VoiceOverOrder()

// PalaceTests/Accessibility/SignInAccessibilityTests.swift
func testSignIn_FormFieldsLabeled()
func testSignIn_ErrorsAnnounced()
```

**Expected Coverage Delta:** +2%

---

### 3.3 Integration Tests (Week 6, Days 1-3)

**Target Flows:**

| Flow | Components Involved | Priority |
|------|---------------------|----------|
| Sign-in → Catalog Load | Auth, Network, Catalog, UI | P0 |
| Download → Read | MyBooks, DRM, Reader | P0 |
| Account Switch | Accounts, Navigation, Cleanup | P1 |
| Search → Results → Detail | Catalog, Search, Book | P1 |

**Test Files to Create:**

```
PalaceTests/Integration/
├── SignInToCatalogIntegrationTests.swift
├── DownloadAndReadIntegrationTests.swift
├── AccountSwitchIntegrationTests.swift
└── SearchFlowIntegrationTests.swift
```

**Expected Coverage Delta:** +5%

---

### 3.4 UI Tests (Week 6, Days 4-5)

**Critical Paths:**

| Path | Steps | Assertions |
|------|-------|------------|
| Library Selection | Launch → Select Library → Confirm | Catalog loads |
| Sign In | Account → Sign In → Credentials | Session established |
| Browse & Borrow | Catalog → Book → Borrow | Book in My Books |
| Read EPUB | My Books → Book → Read | Reader opens |
| Play Audiobook | My Books → Audiobook → Play | Audio plays |

**Test Files to Create:**

```
PalaceUITests/
├── LibrarySelectionUITests.swift
├── SignInUITests.swift
├── BrowseAndBorrowUITests.swift
├── ReadingUITests.swift
└── AudiobookUITests.swift
```

**Expected Coverage Delta:** +3%

---

### Stage 3 Summary

| Metric | Target |
|--------|--------|
| New Test Files | 12-15 |
| Tests Added | ~80-100 |
| Coverage Delta | +13% |
| Ending Coverage | ~75-80% |

### Risks & Mitigation

| Risk | Probability | Impact | Mitigation |
|------|-------------|--------|------------|
| Snapshot tests brittle | High | Medium | Use tolerance, semantic snapshot naming |
| UI tests slow | High | Medium | Parallelize, mock network |
| Integration test isolation | Medium | High | Reset state between tests |

---

## First 3 PRs - Concrete Implementation Plan

### PR #1: Test Infrastructure Foundation

**Branch:** `test/infrastructure-foundation`

**Files Changed:**

```
A  PalaceTests/TestSupport/TestDependencyContainer.swift
A  PalaceTests/TestSupport/Clock.swift
A  PalaceTests/TestSupport/ClockProtocol.swift
A  PalaceTests/Mocks/TPPSettingsMock.swift
A  PalaceTests/Mocks/AccountsManagerProtocol.swift
A  PalaceTests/Mocks/AccountsManagerMock.swift
M  Palace/Settings/TPPSettings.swift (add TPPSettingsProviding protocol)
M  Palace/Accounts/Library/AccountsManager.swift (add protocol conformance)
```

**Commit Messages:**

1. `feat(test): add TestDependencyContainer for centralized mock injection`
2. `feat(test): add Clock protocol and mock for time-dependent testing`
3. `refactor: extract TPPSettingsProviding protocol for testability`
4. `feat(test): add AccountsManagerProtocol and mock implementation`

**Estimated LOC:** ~400 added, ~50 modified

---

### PR #2: ViewModel Unit Tests

**Branch:** `test/viewmodel-unit-tests`

**Files Changed:**

```
A  PalaceTests/CatalogUI/CatalogSearchViewModelTests.swift
A  PalaceTests/Holds/HoldsViewModelTests.swift
A  PalaceTests/Book/BookDetailViewModelTests.swift
A  PalaceTests/Reader2/EPUBSearchViewModelTests.swift
M  PalaceTests/Mocks/CatalogRepositoryMock.swift (add search stubbing)
```

**Commit Messages:**

1. `test(catalog): add CatalogSearchViewModel unit tests`
2. `test(holds): add HoldsViewModel unit tests`
3. `test(book): add BookDetailViewModel unit tests`
4. `test(reader): add EPUBSearchViewModel unit tests`

**Estimated LOC:** ~600 added

---

### PR #3: Authentication Flow Tests

**Branch:** `test/auth-flow-tests`

**Files Changed:**

```
A  PalaceTests/SignInLogic/TPPSignInBusinessLogicTests.swift
A  PalaceTests/Network/TokenRefreshTests.swift
A  PalaceTests/Mocks/TPPUserAccountMock+Keychain.swift
A  PalaceTests/Mocks/TPPDRMAuthorizingMock+Extended.swift
A  PalaceTests/Fixtures/AuthDocs/oauth_token_response.json
M  PalaceTests/Mocks/NYPLNetworkExecutorMock.swift (add token refresh stubbing)
```

**Commit Messages:**

1. `test(auth): add TPPSignInBusinessLogic unit tests for OAuth flow`
2. `test(auth): add tests for sign-out with DRM preservation`
3. `test(network): add token refresh and retry queue tests`
4. `feat(test): extend mocks for authentication testing`

**Estimated LOC:** ~700 added

---

## Coverage Tracking

### Measurement Script

```bash
# Run after each PR merge
xcodebuild test \
  -workspace Palace.xcworkspace \
  -scheme Palace \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -enableCodeCoverage YES \
  -resultBundlePath TestResults.xcresult

# Extract coverage
xcrun xccov view --report TestResults.xcresult --json > coverage.json
python scripts/coverage-report.py coverage.json
```

### Weekly Targets

| Week | Stage | Target Coverage |
|------|-------|-----------------|
| 1 | Foundation | 42% |
| 2 | Quick Wins | 52% |
| 3 | Auth + Downloads | 60% |
| 4 | OPDS + Catalog | 67% |
| 5 | Snapshots + A11y | 72% |
| 6 | Integration + UI | 80% |

---

## Success Criteria

1. **Coverage Target Met:** ≥80% line coverage
2. **No Test Flakiness:** <1% flaky test rate over 100 runs
3. **CI Integration:** All tests pass in GitHub Actions
4. **Documentation:** All patterns documented in Test_Patterns.md
5. **Traceability:** All P0 requirements have at least one test
