# Palace iOS Testing Standards

## Required Tests

All code changes require corresponding tests:

| Change Type | Required Tests |
|-------------|----------------|
| **New Feature** | Unit tests (80% coverage), snapshot tests for UI, integration tests for flows |
| **Bug Fix** | Regression test that fails before fix, passes after (include ticket # in comments) |
| **Modified Code** | Update existing tests, add tests for any coverage gaps |

## Test Organization

```
PalaceTests/
├── ViewModels/          # ViewModel unit tests
├── Network/             # Network layer tests
├── Snapshots/           # UI snapshot tests
├── Mocks/               # Shared mock implementations
├── Audiobook/           # Audiobook-specific tests
├── Reader/              # EPUB reader tests
├── PDF/                 # PDF reader tests
├── Catalog/             # Catalog/OPDS tests
└── OPDS2/               # OPDS2 feed tests
```

## What Makes a Valid Test

### ✅ DO Test:
- **Real production classes** (ViewModels, Models, Services, Extensions)
- Real encoding/decoding behavior
- Real business logic and state transitions
- Error handling paths
- Edge cases with real data

### ❌ DON'T Test:
- Mock implementations themselves
- Basic Swift operations (Set.insert, Array.filter, Bool assignment)
- Arithmetic operations
- Inline mock structs instead of production types
- String trimming or empty checks without real class involvement

## Mock Usage Rules

**Mocks are for DEPENDENCY INJECTION, not for testing.**

```swift
// ✅ CORRECT: Mock isolates the real class under test
func testBookDetailViewModel_LoadsBook() {
  let mockRegistry = TPPBookRegistryMock()
  let viewModel = BookDetailViewModel(registry: mockRegistry)  // Real class
  
  XCTAssertNotNil(viewModel.book)
}

// ❌ WRONG: Testing the mock itself
func testMockRegistry_StoresState() {
  let mockRegistry = TPPBookRegistryMock()
  mockRegistry.setState(.downloading, for: "id")
  
  XCTAssertEqual(mockRegistry.state(for: "id"), .downloading)  // Tests nothing!
}
```

## Available Mocks

Use existing infrastructure in `PalaceTests/Mocks/`:
- `TPPBookRegistryMock` - Book registry operations
- `MockImageCache` - Image caching with TenPrint cover generation
- `CatalogRepositoryMock` - Catalog API operations
- `MockPDFDocument` - PDF document operations
- `TPPBookMocker` - Deterministic test books

## Snapshot Test Standards

```swift
func testBookCell_Downloaded() {
  // 1. Create deterministic data
  let book = TPPBookMocker.snapshotEPUB()
  XCTAssertNotNil(book.coverImage)  // Verify TenPrint cover loaded
  
  // 2. Use real view
  let view = BookCell(book: book)
    .frame(width: 390, height: 120)
  
  // 3. Snapshot with fixed size
  assertSnapshot(of: view, as: .image)
}
```

### Snapshot Requirements:
- Use `SnapshotTesting` library with `.image` strategy
- Pre-load TenPrint covers via `MockImageCache.generateTenPrintCover()`
- Use fixed frame sizes for device-independent snapshots
- Store in `__Snapshots__/` directories
- **Test real views only**, never placeholder/fake views

## Example: Bug Fix Test

```swift
/// Regression test for PP-1234: Book returns don't update UI
/// This test verifies the fix by ensuring state updates propagate.
func testBookReturn_UpdatesUIState() {
  // Arrange: Book in downloaded state
  let mockRegistry = TPPBookRegistryMock()
  let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
  mockRegistry.addBook(book, state: .downloadSuccessful)
  
  let viewModel = MyBooksViewModel(registry: mockRegistry)
  
  // Act: Return the book
  viewModel.returnBook(book)
  
  // Assert: UI state reflects the change
  XCTAssertFalse(viewModel.downloadedBooks.contains(where: { $0.identifier == book.identifier }))
}
```

## Quick Checklist

Before submitting a PR:

- [ ] All new code has corresponding tests
- [ ] Tests use real production classes (not mocks as subjects)
- [ ] No tests of basic Swift operations
- [ ] Snapshot tests use real views with deterministic data
- [ ] Bug fixes include regression tests with ticket reference
- [ ] Tests are organized in appropriate subdirectories

