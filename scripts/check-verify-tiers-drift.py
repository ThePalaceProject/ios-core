#!/usr/bin/env python3
"""
check-verify-tiers-drift.py — assert scripts/verify-tiers.json stays aligned with
CI reality, so the local T1 fast-parity tier can never silently diverge from what
CI actually gates.

Two invariants (the "the tooling is under CI too" contract, extended to the
tiered-parity manifest):

  1. METATESTS EQUALITY
     The T1 `metatests_isolation_lint` gate's `classes` list MUST equal, as a set,
     the class basenames of `PalaceTests/MetaTests/*.swift`. Adding a 10th
     isolation-lint class without adding it to the manifest would silently widen
     the CI/local gap (a narrow -only-testing spot-check never loads MetaTests, so
     the new lint would only fail on the ~40-min CI). This invariant forbids that.

  2. DETECTOR SUPERSET
     The set of `detector_script`s referenced by T1 gates MUST be a SUPERSET of the
     detectors CI runs, drawn from:
       (a) scripts/verify-pr.sh — the run_phase35_detector(...) invocations, and
       (b) .github/workflows/tooling-checks.yml — direct `scripts/check-*.{py,sh}`
           invocations.
     So a detector added to CI can't be missing from the fast local tier.

Exit 0 when aligned; 1 (and a report) on drift.
"""
import argparse
import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
MANIFEST = REPO_ROOT / "scripts" / "verify-tiers.json"
METATESTS_DIR = REPO_ROOT / "PalaceTests" / "MetaTests"
VERIFY_PR = REPO_ROOT / "scripts" / "verify-pr.sh"
TOOLING_CHECKS = REPO_ROOT / ".github" / "workflows" / "tooling-checks.yml"


def fs_metatest_classes(metatests_dir: Path) -> set:
    """Class basenames from PalaceTests/MetaTests/*.swift (filename == primary class)."""
    return {p.stem for p in metatests_dir.glob("*.swift")}


def manifest_t1_metatest_classes(manifest: dict) -> set:
    for gate in manifest["tiers"]["T1"]["gates"]:
        if gate.get("id") == "metatests_isolation_lint":
            return set(gate.get("classes", []))
    return set()


def manifest_t1_detectors(manifest: dict) -> set:
    return {
        g["detector_script"]
        for g in manifest["tiers"]["T1"]["gates"]
        if g.get("kind") == "detector" and g.get("detector_script")
    }


# The manifest-drift meta-gate itself is NOT a code detector that belongs in a
# tier — exclude it (and other pure meta-tooling) from the required set so its own
# reference in tooling-checks.yml doesn't create a self-referential drift.
_SELF = {"check-verify-tiers-drift.py"}


def ci_required_detectors(verify_pr: Path, tooling_checks: Path) -> set:
    required = set()
    if verify_pr.exists():
        text = verify_pr.read_text()
        # run_phase35_detector "id" "check-foo.py" ...  → 2nd quoted token
        for m in re.finditer(r'run_phase35_detector\s+"[^"]+"\s+"([^"]+)"', text):
            required.add(m.group(1))
    if tooling_checks.exists():
        text = tooling_checks.read_text()
        # direct detector-script invocations (not scripts/tests/test_*)
        for m in re.finditer(r'scripts/(check-[a-zA-Z0-9_-]+\.(?:py|sh))', text):
            required.add(m.group(1))
    return required - _SELF


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Assert verify-tiers.json matches CI reality.")
    ap.add_argument("--manifest", default=str(MANIFEST))
    ap.add_argument("--metatests-dir", default=str(METATESTS_DIR))
    ap.add_argument("--verify-pr", default=str(VERIFY_PR))
    ap.add_argument("--tooling-checks", default=str(TOOLING_CHECKS))
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args(argv)

    manifest = json.loads(Path(args.manifest).read_text())
    problems = []

    # Invariant 1: MetaTests equality
    fs_classes = fs_metatest_classes(Path(args.metatests_dir))
    mf_classes = manifest_t1_metatest_classes(manifest)
    missing_from_manifest = fs_classes - mf_classes
    stale_in_manifest = mf_classes - fs_classes
    if missing_from_manifest:
        problems.append(
            "MetaTests classes on disk but MISSING from T1 manifest "
            "(local tier would skip them): " + ", ".join(sorted(missing_from_manifest))
        )
    if stale_in_manifest:
        problems.append(
            "MetaTests classes in T1 manifest but NOT on disk "
            "(stale -only-testing target): " + ", ".join(sorted(stale_in_manifest))
        )

    # Invariant 2: detector superset
    mf_detectors = manifest_t1_detectors(manifest)
    ci_detectors = ci_required_detectors(Path(args.verify_pr), Path(args.tooling_checks))
    missing_detectors = ci_detectors - mf_detectors
    if missing_detectors:
        problems.append(
            "Detectors CI runs but ABSENT from T1 manifest "
            "(fast local tier would miss them): " + ", ".join(sorted(missing_detectors))
        )

    if problems:
        if not args.quiet:
            print("DRIFT: scripts/verify-tiers.json is out of sync with CI reality:")
            for p in problems:
                print("  - " + p)
            print("\nFix: update scripts/verify-tiers.json T1 gates to match, then re-run.")
        return 1

    if not args.quiet:
        print(
            f"OK: verify-tiers.json aligned — {len(mf_classes)} MetaTests classes match disk; "
            f"T1 detectors ({len(mf_detectors)}) ⊇ CI-required ({len(ci_detectors)})."
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
