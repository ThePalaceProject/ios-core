# Module D1 — LCP acquisition-chain recursive-walk detector

**Owner module:** scripts/ + verify-pr.sh + .claude/settings.json
**Risk:** critical_path (touches DRM dispatch — same class as PP-4407 PR #958 + PP-4454 PR #1008)
**Est LOC:** ~250

## Background

PP-4407 (audiobooks won't play) and PP-4454 (LCP PDFs fail to open) are the SAME class:
- LCP acquisition predicates that inspect only `defaultAcquisition.type` fail when Marketplace OPDS 2.0 feeds wrap the real type in `indirectAcquisitions[]`. The fix in both PRs: recursive walk via `hasLCPAcquisition` / `indirectChainContainsLCP`.
- Future content-types could repeat: any new `canOpenBook`-style predicate that looks at the top-level acquisition only.

## Scope (in)

| File | Change | Est LOC |
|------|--------|---------|
| `scripts/check-lcp-acquisition-recursive.py` (NEW) | Detector. Identifies any function in `Palace/MyBooks/` or `Palace/Reader2/` or `Palace/Reader3/` whose body matches the unsafe pattern: references `defaultAcquisition` AND references an LCP MIME literal (`application/vnd.readium.lcp.license.v1.0+json` or any `lcp` MIME) AND does NOT reference `indirectAcquisitions` OR `hasLCPAcquisition`. Annotation escape: `// no-lcp-recursive: <reason>`. | +130 |
| `scripts/test_check_lcp_acquisition_recursive.py` (NEW) | pytest: 5 tests — violation fixture, clean-with-indirectAcquisitions fixture, clean-with-hasLCPAcquisition fixture, annotated fixture, no-LCP-in-scope (false-positive immunity) fixture. | +60 |
| `scripts/tests/fixtures/lcp_acquisition/*.swift` (NEW) | 4 fixture files mirroring the LCPAudiobooks / LCPPDFs / BookFileManager shapes. | +25 |
| `scripts/verify-pr.sh` | Wire-in (run_m1_check). | +4 |
| `.claude/settings.json` | Hook entry. | +3 |
| `scripts/hooks/pre-commit-lcp-acquisition-recursive.sh` (NEW) | Wrapper. | +10 |
| `.forgeos/wall-failures/2026-06-05-pp4407-lcp-acquisition-recursive.md` (NEW) | Wall-failure entry retrofitting PP-4407 + PP-4454 as a single class. Per Module A's TEMPLATE convention. `detector_script: scripts/check-lcp-acquisition-recursive.py`, `detector_status: built`. | +15 |
| `.forgeos/wall-failures/INDEX.md` | One line. | +1 |

## Predicted survivors

Scan target dirs first:
```bash
grep -rln "defaultAcquisition\|hasLCPAcquisition" Palace/ --include="*.swift"
