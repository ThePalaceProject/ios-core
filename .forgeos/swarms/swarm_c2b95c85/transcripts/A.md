# Module A — Format Recognition transcript

**Status:** READY (orchestrator-verified; subagent was rate-limited before writing its own transcript)
**Reconstructed-by:** orchestrator from direct file inspection + contract verification greps

## Summary

- Added `ContentTypeStreamingHTML` MIME constant to `Palace/Packages/PalaceCatalog/Sources/PalaceCatalog/TPPOPDSAcquisitionPath.swift`, plumbed into `supportedTypes()` and `supportedSubtypes(forType: ContentTypeOPDSPublication)`.
- Added `case streamingHTML` to `TPPBookContentType` enum + recognition in `from(mimeType:)`.
- Made `TPPBookContentTypeConverter.stringValue(of:)` exhaustive (dropped `default:`, added explicit `.streamingHTML` arm) — comments document the F-011 intent.
- Added `@objc var isStreamingHTML: Bool` to `TPPBook` (additive).
- Did not edit `OPDS2PublicationExtended.swift` filter sites (per contract advisory B: the generic filter unblocks automatically once `supportedTypes()` contains the new MIME).
- Added/extended 5 test files.

## Files (modified)

Production:
- `Palace/Packages/PalaceCatalog/Sources/PalaceCatalog/TPPOPDSAcquisitionPath.swift` — MIME constant + supportedTypes + supportedSubtypes (3+ refs to `ContentTypeStreamingHTML`).
- `Palace/Book/Models/TPPContentType.swift` — new `case streamingHTML`; `from(mimeType:)` returns `.streamingHTML` for the new MIME.
- `Palace/Book/Models/TPPBookContentTypeConverter.swift` — exhaustive (no `default:`); explicit `case .streamingHTML: return "StreamingHTML"` + F-011 documentation.
- `Palace/Book/Models/TPPBook.swift` — `@objc var isStreamingHTML: Bool { defaultBookContentType == .streamingHTML }`.

Tests:
- `PalaceTests/OPDS2/OPDS2PublicationExtendedTests.swift` (modified)
- `PalaceTests/Book/TPPBookTests.swift` (modified)
- `PalaceTests/OPDS2/TPPContentTypeTests.swift` (new — **placed in OPDS2/ folder; contract said Book/. Functionally equivalent; integrator may relocate.**)
- `PalaceTests/Book/TPPBookContentTypeConverterTests.swift` (new)
- `PalaceTests/TPPOPDSAcquisitionPathTests.swift` (new — **placed at PalaceTests/ root; contract said `Palace/Packages/PalaceCatalog/Tests/PalaceCatalogTests/`. Integrator decision: keep here OR relocate to SPM test target.**)

## Gaps for the integrator

1. **Test file location deviations** noted above. Functionally fine; rename/move during Phase 4 if desired.
2. **OPDS2PublicationExtended.swift unchanged** per advisory B. If a comment update reflecting the new behavior is desired, integrator can add a one-line comment.

## Definition-of-done evidence (orchestrator-verified)

### #1 SUT instantiation check

```bash
$ grep -c 'OPDS2Publication(' PalaceTests/OPDS2/OPDS2PublicationExtendedTests.swift
# Must return ≥ 1 — verified during file inspection (test was added per contract grep #8).
```

### #4 Scope coverage

- PalaceCatalog MIME constant ✓
- TPPBookContentType new case ✓
- TPPBookContentTypeConverter exhaustive ✓ (verified: `grep -n 'default:' ...` returned only the comment line)
- TPPBook.isStreamingHTML ✓
- OPDS2PublicationExtended.swift: deferred per advisory B (test-only) ✓
- 5 test files: 4 in scope, 1 location deviation (TPPContentTypeTests in OPDS2/ folder)

### Contract verification grep evidence

```bash
$ grep -n 'ContentTypeStreamingHTML' Palace/Packages/PalaceCatalog/Sources/PalaceCatalog/TPPOPDSAcquisitionPath.swift
30:public let ContentTypeStreamingHTML = "text/html;profile=http://librarysimplified.org/terms/profiles/streaming-media"
75:      ContentTypeStreamingHTML
121:        ContentTypeStreamingHTML
# count = 3 ≥ 3 ✓

$ grep -c 'case streamingHTML' Palace/Book/Models/TPPContentType.swift
# 1 ≥ 1 ✓

$ grep -n 'default:' Palace/Book/Models/TPPBookContentTypeConverter.swift
12:    /// PP-4161 / F-011: exhaustive — NO `default:` clause. ...
# 0 actual `default:` clauses in code (1 hit is in a comment that documents NOT using one) ✓
# Switch IS exhaustive (.epub / .audiobook / .pdf / .unsupported / .streamingHTML).

$ grep -c 'case .streamingHTML' Palace/Book/Models/TPPBookContentTypeConverter.swift
# 1 ≥ 1 ✓

$ grep -c 'var isStreamingHTML' Palace/Book/Models/TPPBook.swift
# 1 ≥ 1 ✓
```

### #6 Build + verify-pr

**PENDING — see orchestrator integration phase 4.** Subagent was rate-limited before running xcodebuild. Orchestrator is running `xcodebuild ... build` against the merged Wave 1 state.

### #7 Test xcresult bundle path

**PENDING — see orchestrator integration phase 4.**

### Remaining DoD checks (#2, #3, #5, #8, #9, #10)

PENDING — orchestrator will run these in Phase 4.5 skeptic pass against the merged state with Wave 1 + Wave 2 diffs.
