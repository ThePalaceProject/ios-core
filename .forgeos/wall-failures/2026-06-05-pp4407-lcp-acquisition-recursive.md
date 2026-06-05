---
date: 2026-06-05
pr: "#958 + #1008"
source: shipped-bug
reviewer_ids: []
changeset_id: swarm_162a3219
wall: implementer
walls: [implementer, reviewer, contract]
severity: high
wall_status: applied
applied_in: "swarm_162a3219 Module D1"
detector_script: scripts/check-lcp-acquisition-recursive.py
detector_status: built
contributing_docs: []
name: pp4407-lcp-acquisition-recursive
type: evolving
status: active
created: 2026-06-05
last_refresh: 2026-06-05
freshness_window: 365d
owners: [audiobooks, drm]
description: PP-4407 audiobook + PP-4454 LCP PDF — non-recursive LCP acquisition predicate misses Marketplace OPDS 2.0 indirectAcquisitions chains
---

# PP-4407 / PP-4454 — non-recursive LCP acquisition predicate

## Finding (verbatim from reviewer / bug report)

PP-4407 (Marketplace LCP audiobooks won't play) and PP-4454 (Edge of Darkness LCP PDF fails to open) were both bug-class instances of:

> `LCP{Audiobooks,PDFs}.canOpenBook(_:)` returned `false` for Marketplace-served OPDS 2.0 publications because the predicate inspected only `book.defaultAcquisition.type`. Marketplace wraps the LCP license MIME (`application/vnd.readium.lcp.license.v1.0+json`) one or more levels deep inside `defaultAcquisition.indirectAcquisitions[]` (the `/groups/` JSON feed shape) — and in PP-4454 also as a sibling acquisition (the OPDS-Catalog wrapping shape). The top-level type was `application/opds-publication+json`, so the predicate returned `false`, and the LCP open path was never invoked. The book was treated as a non-LCP acquisition, and the actual content type the user clicked never opened.

Cited file:line at fix time:
- PP-4407 fix: `Palace/Audiobooks/LCP/LCPAudiobooks.swift` — commit `ca2ff13b6` (3.0.3 hotfix; recursive `hasLCPAcquisition(_:)` added; old `canOpenBook(_:)` kept for Obj-C source compat).
- PP-4454 fix: `Palace/PDF/LCP/LCPPDFs.swift` — commit `16fc46900` (recursive `hasLCPAcquisition(_:)` mirroring the audiobook fix, plus extension to iterate `book.acquisitions` siblings).

## What actually happened

The original `canOpenBook(_:)` predicate matched only ONE of three real-world OPDS feed shapes:

1. **`/loans/` XML (Palace circulation manager)** — top-level `defaultAcquisition.type` IS the LCP MIME directly. Worked.
2. **`/groups/` JSON (Marketplace / OPDS 2.0)** — top-level `defaultAcquisition.type` is `application/opds-publication+json`; the LCP license MIME is nested in `defaultAcquisition.indirectAcquisitions[]`, often two levels deep. **MISSED.**
3. **OPDS-Catalog wrapping (e.g. Power Rangers Unlimited via Marketplace)** — `book.acquisitions` exposes multiple top-level entries; `defaultAcquisition` returns only the first (the OPDS catalog entry), so even iterating `indirectAcquisitions` on the default acquisition misses the sibling that IS the LCP license. **MISSED.**

Both PP-4407 (audiobooks, shape 2) and PP-4454 (PDFs, shape 3) were the same bug class. The fix in PP-4454 specifically extended the audiobook recipe by iterating `book.acquisitions` to handle shape 3 in addition to recursing `indirectAcquisitions` for shape 2.

The surviving instance until swarm_162a3219 Module D1: `Palace/Audiobooks/LCP/LCPAudiobooks.swift:200-201` — the OLD non-recursive `canOpenBook` body still present in the codebase alongside the canonical recursive `hasLCPAcquisition` at line 217, because the 3.0.3 hotfix preserved the legacy entry point for Obj-C source compatibility and downstream call sites had never been migrated. The dispatch was effectively safe only because `LCPAudiobooks.canOpenBook(_:)` was being called from sites where the book had already been confirmed LCP via other paths — but the predicate ITSELF could regress at any time a new caller landed.

## Walls that should have caught it (and why they didn't)

- **contract**: No contract clause required acquisition-chain predicates to walk `indirectAcquisitions` recursively. The shape was discovered empirically per-vendor (Marketplace → PP-4407; OPDS-Catalog → PP-4454).
- **implementer**: A reasonable Swift implementer reading `defaultAcquisition.type == expectedAcquisitionType` would not see anything wrong — Swift compiles it, the test fixture passed, the live build smoked OK against the Palace circulation manager. The bug surfaced only on a different OPDS shape.
- **reviewer**: Reviewers reading a one-line predicate against a typed property cannot spot a missing recursion case without knowing the data shape. The architect canon ("acquisition-chain predicates must be recursive by default") postdates the PP-4407 fix.
- **TDD**: A test for the live `/loans/` XML shape passes; the Marketplace shape was never covered. No fixture corpus existed for `indirectAcquisitions[]` chains.
- **verify-pr**: Tests pass, build succeeds. No detector existed for the bug-class shape.

## Proposed permanent fix

**APPLIED** in swarm_162a3219 Module D1:

1. New detector `scripts/check-lcp-acquisition-recursive.py` scans `Palace/MyBooks/`, `Palace/Reader2/`, `Palace/Audiobooks/`, `Palace/OPDS2/` for any Swift function whose body references both `defaultAcquisition` AND an LCP MIME literal (`application/vnd.readium.lcp.license.v1.0+json`) or `expectedAcquisitionType` / `ContentTypeReadiumLCP` constant, AND does NOT reference `indirectAcquisitions` OR `hasLCPAcquisition` OR `indirectChainContainsLCP`. Output code `D1-1`, severity `high`.
2. Annotation escape `// no-lcp-recursive: <reason>` for deliberate legacy shims where the rationale is captured in the audit trail.
3. The legacy `Palace/Audiobooks/LCP/LCPAudiobooks.swift:200-201` body wiped — `canOpenBook(_:)` now delegates to `hasLCPAcquisition(_:)`, so all three OPDS feed shapes resolve through the recursive walk regardless of which entry point a future caller chooses.
4. Test coverage at `scripts/tests/test_check_lcp_acquisition_recursive.py` — 6 cases including violation, two clean shapes, annotation honor, and false-positive immunity for non-LCP `defaultAcquisition` usage (the BorrowOperation / BookCellModel shape).
5. (Integrator-scope) detector wired into `scripts/verify-pr.sh` M1 phase + pre-commit hook entry in `.claude/settings.json`.

After the wipe, the bug class is structurally impossible to land via the four scanned directories. New entry points adopting the recursive `hasLCPAcquisition` are clean by detector; new entry points missing it block at pre-commit.

## Application log

- 2026-04-22 — original PP-4407 audiobook fix shipped in 3.0.3 hotfix `ca2ff13b6` (`Palace/Audiobooks/LCP/LCPAudiobooks.swift` — recursive `hasLCPAcquisition` added; legacy `canOpenBook` body kept for source compat).
- 2026-05-XX — PP-4454 LCP PDF fix `16fc46900` (`Palace/PDF/LCP/LCPPDFs.swift` — recursive variant + sibling-acquisition iteration).
- 2026-06-05 — Detector + wipe + wall-failure entry land via `swarm_162a3219` Module D1.

## Related entries

- `2026-05-26` MBDC Phase 7 borrow-path siblings audit — covered the LCP variants risk for `MyBooks/Borrow*` but did not extend the detector class. This entry closes that observation with a structural detector.
- High-value SharedMind pin `reference_marketplace_lcp_mime_nesting.md` (MEMORY index) — the recursive-by-default recipe is the canonical lesson; this wall-failure makes it grep-enforceable.
