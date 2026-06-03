# Module A — Format Recognition (OPDS + ContentType + Filter)

**Standard risk.** Touches PalaceCatalog SPM (public API surface change) +
OPDS2 + Book/Models. Cross-module ripple is contained: every Module-A
public-surface addition is purely additive (new constant, new enum case),
so consumers compile without modification until they explicitly opt in.

## Goal

Land the new `text/html;profile=http://librarysimplified.org/terms/profiles/streaming-media`
MIME constant in PalaceCatalog, plumb it through the supported-types /
supported-subtypes set so the acquisition-path resolver recognizes streaming-
HTML leaves, add the `.streamingHTML` case to `TPPBookContentType`, expose
`TPPBook.isStreamingHTML`, and reverse the PR #847 OPDS2 filter at BOTH
`toBook()` sites so streaming-media-only publications are no longer dropped.

## What public types/protocols change

- `Palace/Packages/PalaceCatalog/Sources/PalaceCatalog/TPPOPDSAcquisitionPath.swift`:
  - NEW `public let ContentTypeStreamingHTML = "text/html;profile=http://librarysimplified.org/terms/profiles/streaming-media"`
  - `supportedTypes()` adds `ContentTypeStreamingHTML`
  - `supportedSubtypes(forType: ContentTypeOPDSPublication)` adds `ContentTypeStreamingHTML` as a leaf
- `Palace/Book/Models/TPPContentType.swift`:
  - `TPPBookContentType` enum adds `case streamingHTML`
  - `TPPBookContentType.from(mimeType:)` recognizes `ContentTypeStreamingHTML`
- `Palace/Book/Models/TPPBookContentTypeConverter.swift`:
  - `stringValue(of:)` adds explicit `case .streamingHTML: return "StreamingHTML"`
  - Drops the `default:` clause for F-011 exhaustiveness (compiler enforces future case-add)
- `Palace/Book/Models/TPPBook.swift`:
  - NEW `@objc var isStreamingHTML: Bool { defaultBookContentType == .streamingHTML }`
  - Verify `defaultBookContentType` correctly resolves to `.streamingHTML` for streaming-media-only books (no production change needed if the supported-types path works — but add a test)

## What internal seams (DI) need updating

None — all changes are additive. Module B's `StreamingReaderViewModel` will
import `PalaceCatalog` to reference `ContentTypeStreamingHTML` if needed.

## Files scoped to THIS implementer

Production:
- `Palace/Packages/PalaceCatalog/Sources/PalaceCatalog/TPPOPDSAcquisitionPath.swift`
- `Palace/OPDS2/Models/OPDS2PublicationExtended.swift` (BOTH `toBook()` filter sites: lightweight `:264-282` AND full `:384-398`)
- `Palace/Book/Models/TPPContentType.swift`
- `Palace/Book/Models/TPPBookContentTypeConverter.swift`
- `Palace/Book/Models/TPPBook.swift` (additive `isStreamingHTML` only)

Tests:
- `PalaceTests/OPDS2/OPDS2PublicationExtendedTests.swift` (modify; both `toBook()` paths)
- `PalaceTests/Book/TPPBookTests.swift` (modify or extend)
- `PalaceTests/Book/TPPContentTypeTests.swift` (NEW file)
- `PalaceTests/Book/TPPBookContentTypeConverterTests.swift` (NEW or extend existing)
- `Palace/Packages/PalaceCatalog/Tests/PalaceCatalogTests/TPPOPDSAcquisitionPathTests.swift` (modify or NEW)

Tooling:
- `ruby scripts/pbxproj_add_swift.rb` for NEW test files — auto-routes to PalaceTests target.

## Files explicitly OFF-LIMITS

- `Palace/MyBooks/` — Module C
- `Palace/Book/UI/BookDetail/` — Module C
- `Palace/ReaderStreaming/` — Module B (doesn't exist yet)
- `Palace/Book/UI/BookDetail/BookButtonMapper.swift` — Module C may consume new APIs but Module A doesn't touch it
- All anti-scope files per `dont_touch` in manifest.yaml

## Test contracts the module must satisfy

1. **OPDS2 lightweight pass-through (mandatory).** New test:
   `testOPDS2Publication_toBook_streamingMediaOnlyAcquisition_doesNotDrop`.
   Set up a `OPDS2Publication` whose ONLY acquisition link has
   `type = ContentTypeStreamingHTML`. Assert `toBook()` returns non-nil
   AND the returned book's `defaultBookContentType == .streamingHTML`.

2. **OPDS2 full pass-through (mandatory).** Same test against
   `OPDS2FullPublication.toBook()` — pins the parallel filter site at `:384-398`.

3. **TPPBookContentType recognition.** New test:
   `testTPPBookContentType_from_streamingMediaMIME_returnsStreamingHTML`.
   Assert `TPPBookContentType.from(mimeType: ContentTypeStreamingHTML) == .streamingHTML`.

4. **TPPBook.isStreamingHTML positive + negative.**
   `testTPPBook_isStreamingHTML_streamingMediaOnly_returnsTrue` AND
   `testTPPBook_isStreamingHTML_epubOnly_returnsFalse`.

5. **Converter exhaustiveness pin.** New test:
   `testTPPBookContentTypeConverter_stringValue_streamingHTML_returnsExpectedToken`.
   Asserts the new case maps and (via meta-cardinality) that all enum cases
   are handled — see verification grep #4 below.

6. **AcquisitionPath round-trip.** Test:
   `testTPPOPDSAcquisitionPath_supportedTypes_containsStreamingHTML` AND
   `testTPPOPDSAcquisitionPath_supportedSubtypes_forOPDSPublication_containsStreamingHTML`.

## Verification criteria (MANDATORY — grep-able assertions)

1. **MIME constant exists in PalaceCatalog:**
   ```bash
   grep -c 'public let ContentTypeStreamingHTML' Palace/Packages/PalaceCatalog/Sources/PalaceCatalog/TPPOPDSAcquisitionPath.swift
   ```
   Must return 1.

2. **MIME constant referenced 3+ times in PalaceCatalog (constant + supportedTypes + supportedSubtypes):**
   ```bash
   grep -c 'ContentTypeStreamingHTML' Palace/Packages/PalaceCatalog/Sources/PalaceCatalog/TPPOPDSAcquisitionPath.swift
   ```
   Must return ≥ 3.

3. **TPPBookContentType has the new case:**
   ```bash
   grep -c 'case streamingHTML' Palace/Book/Models/TPPContentType.swift
   ```
   Must return ≥ 1.

4. **Converter dropped `default:` and added `.streamingHTML`:**
   ```bash
   grep -c 'default:' Palace/Book/Models/TPPBookContentTypeConverter.swift
   ```
   Must return 0.
   ```bash
   grep -c 'case .streamingHTML' Palace/Book/Models/TPPBookContentTypeConverter.swift
   ```
   Must return ≥ 1.

5. **TPPBook.isStreamingHTML exists:**
   ```bash
   grep -c 'var isStreamingHTML' Palace/Book/Models/TPPBook.swift
   ```
   Must return ≥ 1.

6. **OPDS2 filter no longer drops streaming-media at lightweight site:**
   ```bash
   grep -n 'streaming-media\|ContentTypeStreamingHTML' Palace/OPDS2/Models/OPDS2PublicationExtended.swift
   ```
   Should return ≥ 1 hit AND the line above the line 270-282 `guard hasOpenablePath` should reflect the change (visual review).

7. **Both OPDS2 toBook sites have the filter passthrough:**
   ```bash
   grep -c 'hasOpenablePath' Palace/OPDS2/Models/OPDS2PublicationExtended.swift
   ```
   Returns 2 (one per `toBook()`); ensure BOTH still pass streaming-media through.
   For each `hasOpenablePath` guard, verify (manually + by test) that streaming-
   media-only acquisitions yield `hasOpenablePath == true` after the change.

8. **SUT instantiation in tests:**
   ```bash
   grep -c 'OPDS2Publication(' PalaceTests/OPDS2/OPDS2PublicationExtendedTests.swift
   ```
   Must return ≥ 1 (the new streaming-media test constructs the SUT).

9. **Tests compile and pass:**
   ```bash
   xcodebuild -project Palace.xcodeproj -scheme Palace \
     -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
     -only-testing:PalaceTests/OPDS2PublicationExtendedTests \
     -only-testing:PalaceTests/TPPBookTests \
     -only-testing:PalaceTests/TPPContentTypeTests \
     -only-testing:PalaceTests/TPPBookContentTypeConverterTests test 2>&1 | tail -50
   ```
   All four suites pass.

10. **No anti-scope edits:**
    ```bash
    git diff origin/feat/PP-4161-streaming-html-reader --name-only -- 'Palace/MyBooks/' 'Palace/Book/UI/' 'Palace/ReaderStreaming/' 'Palace/SignInLogic/' 'Palace/Reader2/' 'Palace/Reader3/' 'Palace/Audiobooks/'
    ```
    Must return empty.

## Definition of Done evidence (paste in transcript)

1. **TDD evidence — failing test first.** `git log --oneline -- PalaceTests/` shows the test commit landed before the production-fix commit (or in a TDD-style same-commit setup, the production changes are bracketed by failing-then-passing test runs in the transcript).
2. **Build clean:** `xcodebuild ... build` tail pasted.
3. **`scripts/verify-pr.sh --quick`** PASS tail pasted.
4. **`python3 scripts/check-contract-reconciliation.py --commit-msg <commitmsg>`** exit 0 (verifies the "adds ContentTypeStreamingHTML" / "adds .streamingHTML" / "drops PR #847 filter" claims reconcile against the diff).
5. **`python3 scripts/check-blast-radius.py --quiet`** exit 0 — new public API surface (`ContentTypeStreamingHTML`, `TPPBookContentType.streamingHTML`, `TPPBook.isStreamingHTML`) is explicitly enumerated in the commit body so the blast-radius gate doesn't flag them as unjustified.
6. **No `.shared` reads added in production:** `git diff ... | grep '+.*\.shared'` empty.

## Implementer prompt

You are Module A implementer for swarm_c2b95c85 (PP-4161). Land the format-
recognition layer for the new LibrarySimplified streaming-media MIME. Read
`.forgeos/intent/pp-4161-streaming-html-reader.md` first — Claims 1-3 in the
"OPDS / acquisition layer" and "Content-type / book model layer" sections
are your scope. TDD per CLAUDE.md: write the OPDS2 pass-through test first
(both `toBook()` sites), make it pass by removing/inverting the PR #847
filter for streaming-media-only acquisitions, then add the TPPBookContentType
case + converter exhaustiveness pin. The supported-types / supported-subtypes
plumbing in PalaceCatalog is purely additive — no Module C consumer touches
this file. Anti-scope: Palace/MyBooks/, Palace/Book/UI/, Palace/ReaderStreaming/,
all of dont_touch in manifest.yaml.
