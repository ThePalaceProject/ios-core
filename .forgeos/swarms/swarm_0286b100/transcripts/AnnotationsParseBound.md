# Transcript: AnnotationsParseBound (root cause B) — REFRAMED as victim of A

## Outcome: no production parser bug. B is a victim of cause A (pool starvation).

The implementer (isolated-worktree agent, ~900s, Instruments + bisection) returned
**BLOCKED — could not reproduce a catastrophic input**, with strong evidence:

- `testFuzz_AnnotationsResponse_NoCrashes` runs in **0.5–0.86s** for all 500×3
  iterations on Xcode 26.2 / iOS 26.2 sim. No single annotations input exceeds
  even 0.05s. A 0.2s per-input diagnostic across ALL FOUR corpora printed zero
  `FUZZ_DIAG` lines.
- The "21.8s" baseline in the triage is **`testFuzz_OPDS2JSON`** (22s = the SUM of
  ~1500 inputs at ~15ms each), NOT a single slow annotations input — misattributed.
- For the annotations corpus, `fakeBook` is an EPUB (`isAudiobook == false`) so
  `AudioBookmark.create` is never reached, and every corpus item's
  `target.source` (`urn:isbn:…`) never equals `"fuzz-test-book"`, so
  `TPPBookmarkFactory.make` early-returns nil at the `source == bookID` guard
  before any selector re-serialization. **No reachable super-linear path.**
- Standalone repro of every candidate hot line (deep JSONSerialization,
  JSONDecoder, `[String:Any]` interpolation, AnyCodable cascade) found nothing
  super-linear.

**Conclusion:** the 35-min CI "hang" of the annotations fuzz test was
cooperative-pool starvation from **cause A** (leaked `awaitReady()` continuations),
exactly like CatalogPreloader — NOT the parser. The keystone A fix
(`AccountStateStore` terminal drain) is expected to resolve it.

The implementer correctly **refused to fabricate a production bound** without a
reproduced hot line (rigor bar / no-masking directive).

## What landed (non-masking, defensive)
`PalaceTests/Fuzz/FuzzRunner.runOne` now measures per-input wall-clock and
`recordFailure`s (XCTFail) with the repro bytes if any single input exceeds a
generous **2.0s** per-input regression bound. This is a real-bug DETECTOR, not a
mask: it cannot false-positive (slowest real input <0.2s across all corpora),
keeps iterations at 500, and converts any future genuine algorithmic blowup from
a silent 35-min stall into a loud failure with the offending bytes.

## Files
- `PalaceTests/Fuzz/FuzzRunner.swift` (regression detector only)
- NO production change (no parser bug found).
