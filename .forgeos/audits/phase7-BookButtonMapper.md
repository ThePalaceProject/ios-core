---
name: audit-phase7-BookButtonMapper
type: ephemeral
status: active
created: 2026-05-26
last_refresh: 2026-05-26
freshness_window: 180d
owners: [mybooks]
description: "Phase 7 Audit — `BookButtonMapper.swift`"
---

# Phase 7 Audit — `BookButtonMapper.swift`

## Summary

**Verdict: 0 BUG / 3 NEEDS-TEST / 1 CLEAN.** No live F-011/F-014/F-017 defect — the
mapper is byte-identical to its 3.0.2 ancestor (other than the `import
PalaceCatalog` line added during Phase 6 SPM extraction). However, the file is
**not** on the strict critical-path mutation list per memory's warning, and the
test suite leaves `.SAMLStarted` completely uncovered, the `isProcessingDownload
|| .returning` interaction unpinned at the mapper boundary, and the implicit
`default` (`.unsupported` fall-through) untestable as a regression net for
future enum additions. Any new `TPPBookState` case added later would silently
collapse into `.unsupported` with zero test failure — that's the F-011 shape
exactly.

---

## File:line citations

### Code under audit

- `Palace/Book/UI/BookDetail/BookButtonMapper.swift:17-58` — `map(registryState:availability:isProcessingDownload:)`
- `Palace/Book/UI/BookDetail/BookButtonMapper.swift:22` — short-circuit `if registryState == .downloading || isProcessingDownload`
- `Palace/Book/UI/BookDetail/BookButtonMapper.swift:34-36` — `.downloadNeeded` branch (the F-011 historical fall-through site in the inline original)
- `Palace/Book/UI/BookDetail/BookButtonMapper.swift:49-51` — `.returning` branch (comes AFTER `.holding`, BEFORE availability fallback)
- `Palace/Book/UI/BookDetail/BookButtonMapper.swift:53-57` — implicit `default` via cascade fall-off → `.unsupported`

### Caller seam (relevant context, not under audit but informs findings)

- `Palace/Book/UI/BookDetail/BookDetailViewModel.swift:379-390` — `computeButtonState(...)` constructs `isProcessingDownload` and calls the mapper.
- `Palace/Book/UI/BookDetail/BookDetailViewModel.swift:382-383` —
  ```swift
  let downloadRelatedButtons: Set<BookButtonType> = [.download, .get, .retry, .reserve]
  let isProcessingDownload = state == .downloading || processingButtons.intersection(downloadRelatedButtons).count > 0
  ```
  Explicitly excludes `.return` from the processing-download intersection, so a
  `.returning` book with `processingButtons = [.returning]` correctly produces
  `isProcessingDownload = false`. This is the F-017-class fix — the caller is
  defensive — but the mapper has no test that pins this invariant.

### 3.0.2 reference

- `git show 3.0.2:Palace/Book/UI/BookDetail/BookButtonMapper.swift` — byte-identical
  to `HEAD` except for the `import PalaceCatalog` line. **No regression vs.
  3.0.2.** The Phase 7 decomposition that landed this file did not introduce a
  defect here; the file shipped clean and stayed clean.

### Mutation-list policy

- `scripts/verify-pr.sh:73` — `CRITICAL_MUTATION_PATHS_REGEX='^Palace/(Audiobooks|SignInLogic|MyBooks/Download)'`
- `BookButtonMapper.swift` lives under `Palace/Book/UI/BookDetail/` → **does not
  match** the strict critical-path regex. Mutation kill-rate is advisory, not
  enforced. Per memory's call-out, this should be tightened (see notes below).

---

## Findings

### Finding 1 — NEEDS-TEST: `.SAMLStarted` is the live F-011 latent

**Why this matters.** `TPPBookState.SAMLStarted` (`Palace/Book/Models/TPPBookState.swift:25`)
is a real, reachable state — `BookDetailViewModel` and the borrow flow transition
into it during SAML-gated downloads. The mapper has NO branch for it; it falls
through the entire `if`-cascade and exits at `BookButtonMapper.swift:57` as
`.unsupported`. The user would see no actionable button for an in-flight SAML
download.

Today no test pins this. `BookButtonMapperTests.swift` and
`BookButtonMapperHoldReadyTests.swift` both omit `.SAMLStarted` entirely
(confirmed: grep returns 0 hits). A future contributor could rename `.SAMLStarted`
or add a new state, and the mapper would silently regress.

**Mutant that survives.** Comment out lines 34-36 (`.downloadNeeded` branch). The
existing test `testMap_downloadNeeded_returnsDownloadNeeded`
(`BookButtonMapperTests.swift:56-63`) catches that — so `.downloadNeeded` is
mutant-killed. But add an `if false &&` guard to line 49 (`.returning` branch),
or remove it outright — `testMap_returning_returnsReturning`
(`BookButtonMapperTests.swift:74-81`) catches THAT too. The mutants that survive
are the ones in the `default` zone:

1. **Add a hypothetical `case .borrowing` to `TPPBookState`** — every existing
   test still passes, but the mapper now returns `.unsupported` for an in-flight
   borrow. There is no test that proves "all `TPPBookState` cases get an explicit
   branch."
2. **`.SAMLStarted` produces `.unsupported`** — this is current production
   behavior and may be deliberate, but no test exists that pins it as a
   *contract* vs. an *oversight*.

**Suggested test (add to `BookButtonMapperTests.swift`).**

```swift
// MARK: - Exhaustive State Coverage (catches F-011 regressions)

/// Every TPPBookState case must produce a defined mapping. Adding a new
/// case to the enum without updating BookButtonMapper.map(...) is the F-011
/// shape — this parameterized test forces the question.
func testMap_everyTPPBookStateCase_producesNonNilBookButtonState() {
    for state in TPPBookState.allCases {
        let result = BookButtonMapper.map(
            registryState: state,
            availability: nil,
            isProcessingDownload: false
        )
        // .unsupported is allowed as an outcome — but it must be the
        // mapper's deliberate choice, not the result of a fallen-off
        // cascade. Pin the contract by enumerating expectations:
        let expected: BookButtonState = {
            switch state {
            case .unregistered, .unsupported, .SAMLStarted: return .unsupported
            case .downloadNeeded:     return .downloadNeeded
            case .downloading:        return .downloadInProgress
            case .downloadFailed:     return .downloadFailed
            case .downloadSuccessful: return .downloadSuccessful
            case .returning:          return .returning
            case .holding:            return .holding
            case .used:               return .used
            }
        }()
        XCTAssertEqual(result, expected,
                       "TPPBookState.\(state) must map to \(expected), got \(result)")
    }
}
```

The `switch state` is **exhaustive** (no `default:`) so adding a new
`TPPBookState` case causes a compile-time failure in the test — that's the
parameterized-test pattern the prelude calls out as the F-011 safety net.

### Finding 2 — NEEDS-TEST: `isProcessingDownload || .returning` boundary unpinned

**Why this matters.** The `.returning` branch sits at lines 49-51, AFTER the
`isProcessingDownload` short-circuit at line 22. If a regression in the caller
ever flipped `BookDetailViewModel.swift:382-383` to include `.return` in
`downloadRelatedButtons` (or if a new processing button leaked in), the mapper
would silently return `.downloadInProgress` instead of `.returning` for a book
the user just tapped Return on — the F-017 shape (in-flight return state not
reflected to UI).

The mapper itself is correct: `isProcessingDownload` is an input, not derived,
so the mapper can't be defensive. But **no test pins the boundary**: there is
no `testMap_returning_withIsProcessingDownloadTrue_???` covering what should
happen when both are set. Today the mapper returns `.downloadInProgress` for
`(registryState: .returning, isProcessingDownload: true)` — and that IS the
current contract — but it's an untested contract.

**Mutant that survives.** Move the `.returning` branch (lines 49-51) above the
`isProcessingDownload` short-circuit (line 22). No existing test fails:
- `testMap_returning_returnsReturning` passes `isProcessingDownload: false` so
  the move doesn't matter.
- `testMap_isProcessingDownloadOverridesEverything`
  (`BookButtonMapperTests.swift:263-272`) uses `registryState: .downloadFailed`,
  not `.returning`.

This is a silent priority-inversion mutant the tests miss.

**Suggested test.**

```swift
/// .returning + isProcessingDownload=true: download-in-progress wins.
/// This pins the priority ordering — a mutant that moves .returning
/// above the isProcessingDownload short-circuit must fail here.
func testMap_returning_withIsProcessingDownloadTrue_returnsDownloadInProgress() {
    let result = BookButtonMapper.map(
        registryState: .returning,
        availability: nil,
        isProcessingDownload: true
    )
    XCTAssertEqual(result, .downloadInProgress,
                   "isProcessingDownload must override .returning — moving the .returning branch above line 22 should fail this test")
}

/// Inverse: .returning + isProcessingDownload=false stays .returning.
/// Already covered by testMap_returning_returnsReturning, but pairing
/// the two is the round-trip pattern from CLAUDE.md.
```

### Finding 3 — NEEDS-TEST: implicit `default` falls off to `.unsupported`

**Why this matters.** Line 57 (`return .unsupported`) is reached in two
semantically distinct cases:
1. `registryState` is a state the mapper doesn't recognize (the F-011 path).
2. `registryState` is a recognized state with no opinion AND `availability` is
   nil or returned nil from `stateForAvailability(_)`.

The mapper conflates these. From the prelude: "Enum cases reused with two
meanings get an explicit semantics test." `BookButtonState.unsupported` is
exactly such a case here.

**Mutant that survives.** Change line 57 to `return .canBorrow`. `testMap_unregistered_withNilAvailability_returnsUnsupported`
(`BookButtonMapperTests.swift:144-151`) catches that. Good — that mutant is
killed. But change line 57 to `return .downloadNeeded` — still killed by the
same test. The mutant that survives: change line 57 to a switch that returns
`.unsupported` only for `.unregistered` and crashes for everything else. The
test passes (it only exercises `.unregistered`); production silently misbehaves
on any future state.

**Suggested test.** This is partially absorbed by Finding 1's exhaustive
parameterized test. Recommend keeping the existing
`testMap_unregistered_withNilAvailability_returnsUnsupported` as the
"`.unregistered` is deliberate" pin, and adding a `.SAMLStarted` companion to
distinguish the two meanings of `.unsupported`:

```swift
/// .SAMLStarted falls through to .unsupported by current design.
/// Pin it explicitly — if SAML-started should ever show a download-in-progress
/// button (likely the right behavior!), this test forces the conversation.
func testMap_SAMLStarted_fallsThroughToUnsupported_DOCUMENTED_GAP() {
    let result = BookButtonMapper.map(
        registryState: .SAMLStarted,
        availability: nil,
        isProcessingDownload: false
    )
    XCTAssertEqual(result, .unsupported,
                   ".SAMLStarted currently has no mapper branch and falls through to .unsupported. " +
                   "If that's wrong, fix the mapper AND update this test.")
}
```

### Finding 4 — CLEAN: cascade ordering vs. 3.0.2 reference

The if-cascade order (lines 22, 26, 30, 34, 38, 42, 49, 53) matches the 3.0.2
reference exactly. No condition was inverted (no F-014). No enum case was
silently dropped from a `switch` (no F-011 in the literal sense — the file uses
an if-cascade, not a switch, so there's no `default:` clause to fall through).
The PP-3702 hold-ready logic (lines 42-47) is preserved with the same precedence:
`registryState == .holding && availability is Ready` → `.canBorrow` BEFORE the
plain `.holding` return. Covered by 7 tests in `BookButtonMapperHoldReadyTests.swift`
(lines 23-115).

`stateForAvailability(_)` (lines 62-89) — the 5-arm match on
`TPPOPDSAcquisitionAvailability` (unavailable / limited / unlimited / reserved
/ ready) — has full per-arm test coverage AND the dispatch-table cross-check
test at `BookButtonMapperTests.swift:218-237` that catches constant-return
mutants. This is the well-tested part of the file.

---

## Mutation-testing notes

**Memory explicitly asks:** "Mutation kill-rate on this file is unknown — should
be in the strict critical-path mutation list."

**Verified.** `scripts/verify-pr.sh:73` defines:

```
CRITICAL_MUTATION_PATHS_REGEX='^Palace/(Audiobooks|SignInLogic|MyBooks/Download)'
```

`BookButtonMapper.swift` lives at `Palace/Book/UI/BookDetail/BookButtonMapper.swift`
— **does not match.** Mutation enforcement on this file today is advisory only;
a low kill-rate would not fail `verify-pr.sh` without `--enforce-mutations`.

**Recommendation.** Extend the regex to include `Book/UI/BookDetail/BookButtonMapper`:

```diff
- CRITICAL_MUTATION_PATHS_REGEX='^Palace/(Audiobooks|SignInLogic|MyBooks/Download)'
+ CRITICAL_MUTATION_PATHS_REGEX='^Palace/(Audiobooks|SignInLogic|MyBooks/Download|Book/UI/BookDetail/BookButtonMapper)'
```

Rationale per memory: BookButtonMapper sits on the borrow / download / return /
hold UI surface — every patron action funnels through `BookButtonMapper.map(...)`
into `BookButtonState.buttonTypes(...)` which renders the actionable button.
A silent wrong-state here yields exactly the F-011 / F-017 user impact: visible
button no longer matches actual book state.

**Expected kill rate after adding Finding 1's parameterized test:** ~90%+. The
file is small (90 LOC, ~12 mutation points), pure (no side effects), and the
exhaustive-state test plus the existing 22 tests would cover branches densely.
The remaining survivors are likely in `stateForAvailability(_)`'s `var state =
.unsupported` initial-value assignment (line 67) — a mutant changing the default
would only manifest if `match(...)` ever returned without writing to `state`,
which the OPDS contract prevents.

**Suggested command for the next mutation pass.**

```bash
python3 scripts/palace_mutate.py \
  --file Palace/Book/UI/BookDetail/BookButtonMapper.swift \
  --tests PalaceTests/BookButtonMapperExtendedTests
# AND
python3 scripts/palace_mutate.py \
  --file Palace/Book/UI/BookDetail/BookButtonMapper.swift \
  --tests PalaceTests/BookButtonMapperHoldReadyTests
```

`scripts/resolve-tests-for.py` may or may not pick up both classes — verify the
selector before relying on it. The 50% strict threshold should be trivially met
after Finding 1.

---

## Headline

**No live bug; the file is clean vs. 3.0.2.** But `.SAMLStarted` is uncovered,
the if-cascade has an implicit `default` that any future `TPPBookState` case
will silently inherit, and the file is **not on the strict mutation list**
despite sitting on every patron-action UI path. Add the exhaustive parameterized
test from Finding 1 AND extend `CRITICAL_MUTATION_PATHS_REGEX` to include this
file. Both changes are <30 LOC and close the F-011-class window memory flagged.
