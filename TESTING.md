# Palace iOS Testing

Quick-start for running and writing tests. Deeper references live in
[`docs/Testing/`](./docs/Testing/) and the agent-facing TDD rules live in
[`CLAUDE.md`](./CLAUDE.md) under "TDD & Test Quality — MANDATORY".

## Running tests

Use `Palace.xcodeproj`. The legacy `PalaceR2.xcworkspace` was removed (it hit
Firebase SPM xcframework resolution issues); `Palace.xcodeproj` is the only
supported entry point. Pick a simulator by name, not by UDID, so this works
on any machine.

```bash
# Build
xcodebuild -project Palace.xcodeproj -scheme Palace \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build

# Run all tests
xcodebuild -project Palace.xcodeproj -scheme Palace \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test

# Run a single test class
xcodebuild -project Palace.xcodeproj -scheme Palace \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:PalaceTests/MyTestClass test
```

## Test organization

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

## Required tests for each change type

| Change Type    | Required Tests                                                                                |
| -------------- | --------------------------------------------------------------------------------------------- |
| New Feature    | Unit tests for the new behavior, snapshot tests for UI, integration tests for end-to-end flow |
| Bug Fix        | Regression test that fails before the fix and passes after; reference the ticket in comments  |
| Modified Code  | Update existing tests; add tests for any coverage gap the change exposes                      |

## Test quality

Every test should exercise real production code via injected dependencies and
assert observable behavior, not implementation details. The deep references:

- [`docs/Testing/TESTING_POSTURE.md`](./docs/Testing/TESTING_POSTURE.md) —
  posture, confidence matrix, current gaps. Read before writing tests for an
  unfamiliar area.
- [`docs/Testing/Test_Patterns.md`](./docs/Testing/Test_Patterns.md) —
  reusable patterns (Combine + spy, closure DI, `FakeDownloadTask`, async
  helpers).
- [`docs/Testing/REGRESSION_TEST_MATRIX.md`](./docs/Testing/REGRESSION_TEST_MATRIX.md) —
  regression coverage by feature area and ticket.
- [`docs/Testing/Coverage_Roadmap.md`](./docs/Testing/Coverage_Roadmap.md) —
  coverage trajectory and floors.
- [`CLAUDE.md`](./CLAUDE.md) "TDD & Test Quality — MANDATORY" — test-first
  workflow, fluff/tautology rules, and mutation-survival expectation.

## Mutation testing

Every test should kill at least one mutant in the production code it covers.
Run on changed files before opening a PR:

```bash
python3 scripts/palace_mutate.py --file Palace/Path/Changed.swift \
  --tests PalaceTests/Path/ --dry-run
# Re-run without --dry-run to verify the test catches the mutants.
```

A test that survives no mutants is fluff regardless of how many assertions it
has. See `CLAUDE.md` for the mutation-verification rule in full.

## Snapshot tests

Use the `SnapshotTesting` library with the `.image` strategy and a fixed
frame size so output is device-independent. Use `TPPBookMocker` for
deterministic book fixtures and pre-load TenPrint covers via
`MockImageCache.generateTenPrintCover()` so the rendered image is stable
across runs. Snapshots live alongside the tests in `__Snapshots__/`
directories. Test real views, never placeholder views built only for the
snapshot.

## Bug-fix test example

```swift
/// Regression test for PP-1234: Book returns don't update UI.
func testBookReturn_UpdatesUIState() {
  let mockRegistry = TPPBookRegistryMock()
  let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
  mockRegistry.addBook(book, state: .downloadSuccessful)

  let viewModel = MyBooksViewModel(registry: mockRegistry)
  viewModel.returnBook(book)

  XCTAssertFalse(viewModel.downloadedBooks.contains { $0.identifier == book.identifier })
}
```
