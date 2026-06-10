# Contract: AnnotationsParseBound  (root cause B)

## Root cause (production robustness)
ParserFuzzTests.testFuzz_AnnotationsResponse_NoCrashes degrades 21.8s → 35min+ on a single
deterministic mutated input (FuzzRunner seed `0xCAFEBABE`). `FuzzRunner` runs each input
synchronously with NO real per-input timeout (`timeoutPerInput` is unused) so one pathological input
hangs the test. Seeds are ≤2KB and mutations are single-byte/≤32-byte → super-linear algorithmic
blowup on a SMALL input in the annotations parse chain (`TPPAnnotations.parseAnnotationItems` →
`TPPBookmarkFactory.make(fromServerAnnotation:)` → `AudioBookmark.create`). A malformed SERVER
annotations response could stall the real bookmark-sync path — genuine production bug.

## Required fix (ROOT CAUSE — not a mask). GATED:
1. INSTRUMENT FIRST: make FuzzRunner record per-input wall-time (or bisect by seed#/mut#) to identify
   the EXACT catastrophic input and the production hot line. Paste seed#/mut# + the hot line.
2. BOUND THE PRODUCTION CODE at that line: cap the unbounded work (recursion/iteration depth bound;
   guard arbitrary-depth `[String:Any]` Log interpolations in `TPPBookmarkFactory`/`AudioBookmark`; or
   bound the nested re-serialization in `TPPBookmarkFactory`). The bound lives in PRODUCTION.
DO NOT: reduce fuzz iterations below 500, add a test-level timeout/skip as the fix, or relax the corpus.
If un-reproducible within budget → STOP + scope-deferral (do NOT mask).

## Files in scope
- `Palace/Reader2/Bookmarks/TPPBookmarkFactory.swift`
- `Palace/Reader2/Bookmarks/AudioBookmark.swift`
- `PalaceTests/Fuzz/FuzzRunner.swift`  (instrumentation; may add a per-input wall-clock REAL-BUG
  DETECTOR that XCTFails with the repro input if a single input exceeds a generous bound — a detector,
  not a mask)
OFF-LIMITS: TPPAnnotations.swift parse funcs (already bounded JSONSerialization), corpus seeds.

## Test contract
- testFuzz_AnnotationsResponse_NoCrashes completes < 30s for all 500 iterations.
- Focused unit test feeding the catastrophic input directly to the bounded production function,
  asserting it returns (nil/throws) in bounded time.

## Verification criteria (grep-able)
- Fuzz still 500 iterations: `grep -n 'iterations: 500'` for the annotations test UNCHANGED.
- No XCTSkip: `git diff origin/develop -- PalaceTests/Fuzz | grep -c XCTSkip` == 0.
- Bound is in PRODUCTION: `git diff` touches TPPBookmarkFactory/AudioBookmark with an explicit
  depth/size guard (`guard depth < N`, `prefix(N)`, early-return).
- Repro evidence pasted (seed#/mut# + hot line). FULL-suite green tail under `-test-timeouts-enabled YES`.
