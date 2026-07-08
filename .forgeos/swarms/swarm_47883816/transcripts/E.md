# Work package E — MetaTestsLintExpansion (transcript)

**Swarm:** `swarm_47883816`
**Implementer:** E
**Status:** READY FOR INTEGRATION
**Contract:** `.forgeos/swarms/swarm_47883816/contracts/E-MetaTestsLintExpansion.md`

## Scope landed

1. **`PalaceTests/MetaTests/MockIsolationLintTests.swift`** — broadened scope.
   - `mocksRoot` (path resolution) became `palaceTestsRoot`; walk is now the
     entire `PalaceTests/` tree, with the `MetaTests/` directory itself
     skipped (lint sources contain banned substrings in synthetic fixtures —
     would self-trigger).
   - Rule 1 (`shared` without `resetShared`) — added 2 explicit `Support/`
     exemptions (`SingletonResetRegistry.swift`,
     `TPPUserAccountTestFactory.swift`). Both are the reset infrastructure
     itself; linting them would be circular.
   - Rule 2 (`cancellables` teardown) — added inheritance-from-`*TestCase`
     as a compliance shape. `PalaceWiringTestCase` drains the bag on its
     own tearDown, so subclasses are compliant by inheritance.
   - Rule 3 (`addObserver` → `removeObserver`) — unchanged. All
     `PalaceTests/**` callers of `NotificationCenter.default.addObserver`
     already call `removeObserver` (verified pre-implementation).
   - Added 2 lint self-tests: `testLintCatchesSyntheticViolator`,
     `testLintAcceptsInheritedTearDown`. Prove the detectors actually
     fire (a regex regression cannot silently make the lint pass green).

2. **`PalaceTests/MetaTests/TearDownRequiredLintTests.swift`** — NEW.
   - Polluter substrings: `.shared`, `AccountsManager(`,
     `AppContainer.production()`, `NotificationCenter.default.addObserver`,
     `UserDefaults.standard.set`.
   - Trigger: file must declare `: XCTestCase` directly (not via
     `*TestCase` base — those are exempt by inheritance). File must
     contain at least one polluter substring. Compliance requires
     `override func tearDown[WithError]\(`.
   - Exemption: baseline file at
     `.forgeos/swarms/swarm_47883816/E-teardown-baseline.txt` listing
     37 current XCTestCase-derived polluter-touching files without
     tearDown. The list is **shrink-only** — adding a new file is
     rejected by the lint (the structural protection).
   - 4 lint self-tests:
     - `testTearDownRequired_runsAgainstPalaceTestsTree` — real-tree scanner
     - `testLintCatchesSyntheticViolator` — synthetic violator → flagged
     - `testLintAcceptsInheritedTearDown` — synthetic `*TestCase` subclass → NOT flagged
     - `testLintAcceptsExplicitTearDown` — synthetic XCTestCase + tearDown → NOT flagged
     - `testBaselineFileIsLoaded` — resolver path sanity (loud failure if
       baseline file moves or is empty)

3. **`.forgeos/swarms/swarm_47883816/E-teardown-baseline.txt`** — NEW.
   - 37 files, generated mechanically by scanning PalaceTests/ for
     `: XCTestCase` declarations with polluter substrings and no
     tearDown override.
   - Header documents the shrink-only invariant.

4. **`Palace.xcodeproj/project.pbxproj`** — TearDownRequiredLintTests
   registered via `ruby scripts/pbxproj_add_swift.rb`. Idempotent — added=1.

## DoD evidence

### 1. SUT-instantiation check

```bash
$ grep -c "MockIsolationLintTests\|TearDownRequiredLintTests" \
    PalaceTests/MetaTests/MockIsolationLintTests.swift \
    PalaceTests/MetaTests/TearDownRequiredLintTests.swift
PalaceTests/MetaTests/MockIsolationLintTests.swift:2
PalaceTests/MetaTests/TearDownRequiredLintTests.swift:2
```

Both files reference their own class name. The `final class
MockIsolationLintTests: XCTestCase {` declaration and the
`final class TearDownRequiredLintTests: XCTestCase {` declaration
each appear at least once in the corresponding file.

### 2. MockIsolationLintTests scope broadened

```bash
$ grep -n "PalaceTests" PalaceTests/MetaTests/MockIsolationLintTests.swift | head -10
3://  PalaceTests
6://  PalaceTests/. They prevent the class of test-pollution bugs surfaced
30://  Scope (swarm_47883816 work package E): walks ALL of `PalaceTests/`
50:  /// `PalaceTests/` resolved relative to this file's location so the test
54:  /// the entire `PalaceTests/` tree. The 3 hygiene rules apply equally
62:      .deletingLastPathComponent()  // PalaceTests/
78:    "PalaceTests/Support/SingletonResetRegistry.swift",
83:    "PalaceTests/Support/TPPUserAccountTestFactory.swift",
86:  /// All `*.swift` files under `PalaceTests/` (recursive), with the
96:      XCTFail("Could not enumerate \(Self.palaceTestsRoot.path) — is the PalaceTests directory present?")
```

The path resolver now stops at `PalaceTests/` (line 62) rather than
descending into `Mocks/` (the previous behaviour).

### 3. Synthetic-violator detection

Both files include `testLintCatchesSyntheticViolator`:
 - `MockIsolationLintTests.testLintCatchesSyntheticViolator` — feeds
   a synthetic source that declares `var cancellables: Set<AnyCancellable>` 
   with no teardown shape; asserts the detector flags it as a violator.
 - `TearDownRequiredLintTests.testLintCatchesSyntheticViolator` — feeds
   a synthetic XCTestCase subclass that constructs `AccountsManager()`
   with no `tearDown`; asserts the detector identifies all 3 trigger
   conditions.

Both passed in the test run below.

### 4. Baseline file exists and is non-empty

```bash
$ [ -f .forgeos/swarms/swarm_47883816/E-teardown-baseline.txt ] && \
    wc -l .forgeos/swarms/swarm_47883816/E-teardown-baseline.txt && \
    wc -c .forgeos/swarms/swarm_47883816/E-teardown-baseline.txt
      61 .forgeos/swarms/swarm_47883816/E-teardown-baseline.txt
    3265 .forgeos/swarms/swarm_47883816/E-teardown-baseline.txt
```

61 lines (37 data entries + comment header + blank lines), 3265 bytes.
The `TearDownRequiredLintTests.testBaselineFileIsLoaded` self-test
asserts the file is loaded and has ≥1 entry; passed below.

### 5. Build-for-testing

```bash
$ xcodebuild -project Palace.xcodeproj -scheme Palace \
    -destination 'platform=iOS Simulator,id=141BD227-6E9A-4409-8D99-2D4FE818238D' \
    -derivedDataPath /tmp/swarm_47883816_integrate \
    build-for-testing
...
** TEST BUILD SUCCEEDED **
```

Two pre-existing warnings about duplicate build files in Compile
Sources (`CatalogProblemDocumentTests.swift`,
`CatalogLaneAssemblyTests.swift`) are unrelated to E's diff — they
exist on the orchestrator worktree before this work package landed.

### 6. Both lint tests PASS

```bash
$ xcodebuild ... \
    -only-testing:PalaceTests/MockIsolationLintTests \
    -only-testing:PalaceTests/TearDownRequiredLintTests test
...
Test Suite 'TearDownRequiredLintTests' passed at 2026-06-04 09:34:22.544.
   Executed 5 tests, with 0 failures (0 unexpected) in 1.034 (1.041) seconds
Test Suite 'MockIsolationLintTests' passed at 2026-06-04 09:34:23.433.
   Executed 5 tests, with 0 failures (0 unexpected) in 0.882 (0.888) seconds
Test Suite 'PalaceTests.xctest' passed at 2026-06-04 09:34:23.434.
   Executed 10 tests, with 0 failures (0 unexpected) in 1.916 (1.930) seconds
...
** TEST SUCCEEDED **
```

xcresult bundle:
`/tmp/swarm_47883816_integrate/Logs/Test/Test-Palace-2026.06.04_09-34-09--0400.xcresult`

Total: **10 tests executed, 0 failures.**

### 7. DoD script gates

```bash
$ python3 scripts/check-contract-reconciliation.py
OK: no claims parsed from any source.
EXIT: 0

$ python3 scripts/check-blast-radius.py --quiet
EXIT: 0

$ python3 scripts/check-intent-recorded.py --quiet
EXIT: 0
```

All three gates green. E's diff is test-only (no production code
touched, no public API surface change, no contract claims to
reconcile).

## Sibling-package observations

- **MockIsolationLintTests rule 1** (shared singleton) — exempted
  `SingletonResetRegistry.swift` and `TPPUserAccountTestFactory.swift`
  by absolute path SUFFIX (so the suffix match is robust to absolute
  vs relative path representations in different checkouts).
- **MockIsolationLintTests rule 2** (cancellables) — adding the
  `*TestCase` inheritance compliance shape was a NET LOOSENING of the
  pre-E rule, but it correctly models the seam: `PalaceWiringTestCase`
  is the canonical drain seam (work package B's contract introduced it),
  and subclasses MUST be allowed to delegate teardown via inheritance.
- **TearDownRequiredLintTests baseline (37 files)** — many of these
  are good candidates for migration to `PalaceWiringTestCase`. That
  is explicitly NOT in E's scope (would require touching test logic
  beyond the lint surface). A follow-up "teardown shrink" swarm
  should be scoped from this baseline.

## Off-limits guardrails honoured

- **A/B/C/D's lint files**: NOT modified. `git diff` shows only:
  - `M  PalaceTests/MetaTests/MockIsolationLintTests.swift` (E owns)
  - `A  PalaceTests/MetaTests/TearDownRequiredLintTests.swift` (E owns)
- **Production code**: not touched. The only production-tree changes
  in the worktree (e.g. `Palace/FeatureFlags/RemoteFeatureFlags.swift`,
  `Palace/Settings/TPPSettings.swift`) were landed by sibling implementers
  before E started and are visible only because the worktree is shared.

## Files left staged (NOT committed, per orchestrator instruction)

```
M  PalaceTests/MetaTests/MockIsolationLintTests.swift
A  PalaceTests/MetaTests/TearDownRequiredLintTests.swift
A  .forgeos/swarms/swarm_47883816/E-teardown-baseline.txt
M  Palace.xcodeproj/project.pbxproj   (2 PBXBuildFile + 1 PBXFileReference + 1 group membership + 1 Sources entry)
```

E is ready for orchestrator integration.
