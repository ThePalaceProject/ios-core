"""
test_check_verify_tiers_drift.py — pytest for the tiered-parity manifest drift gate
(scripts/check-verify-tiers-drift.py).

Asserts BOTH directions (CLAUDE.md gate rule: a gate that only ever sees a
violation hides wiring bugs — the clean/aligned path MUST pass too):

  Invariant 1 (MetaTests equality):
    (a) manifest classes == `ls MetaTests/*.swift`          -> PASS
    (b) a class ON DISK missing from the manifest           -> FAIL (widens gap)
    (c) a class IN MANIFEST missing from disk (stale)       -> FAIL

  Invariant 2 (detector superset):
    (d) manifest detectors ⊇ CI-required                    -> PASS
    (e) manifest a strict SUPERSET (extra detectors)        -> PASS
    (f) a CI-required detector ABSENT from the manifest     -> FAIL

Every case builds a throwaway manifest + MetaTests dir + verify-pr.sh +
tooling-checks.yml in tmp_path and points the script at them via CLI flags, so
the test never depends on the live repo's current alignment.
"""

from __future__ import annotations

import json
import subprocess
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_SCRIPT = _REPO_ROOT / "scripts" / "check-verify-tiers-drift.py"


def _manifest(classes, detectors) -> dict:
    gates = [
        {"id": "build_for_testing", "kind": "xcodebuild-build-for-testing"},
        {
            "id": "metatests_isolation_lint",
            "kind": "xctest-classes",
            "classes": list(classes),
        },
    ]
    for d in detectors:
        gates.append(
            {
                "id": f"detector_{d}",
                "kind": "detector",
                "detector_script": d,
                "mode": "block",
                "scan_mode": "diff",
            }
        )
    return {"version": 1, "tiers": {"T1": {"name": "fast parity", "gates": gates}}}


def _write_scene(tmp_path: Path, disk_classes, manifest_classes,
                 verify_pr_detectors, manifest_detectors, tooling_detectors=()):
    metatests_dir = tmp_path / "MetaTests"
    metatests_dir.mkdir()
    for c in disk_classes:
        (metatests_dir / f"{c}.swift").write_text(f"final class {c}: XCTestCase {{}}\n")

    manifest_path = tmp_path / "verify-tiers.json"
    manifest_path.write_text(json.dumps(_manifest(manifest_classes, manifest_detectors)))

    verify_pr = tmp_path / "verify-pr.sh"
    lines = ["#!/usr/bin/env bash"]
    for d in verify_pr_detectors:
        lines.append(f'run_phase35_detector "{d.replace(".py","")}" "{d}" "block" \\')
        lines.append(f'  "desc for {d}" "diff"')
    verify_pr.write_text("\n".join(lines) + "\n")

    tooling = tmp_path / "tooling-checks.yml"
    tlines = ["name: Tooling Checks"]
    for d in tooling_detectors:
        tlines.append(f"      - run: python3 scripts/{d}")
    tooling.write_text("\n".join(tlines) + "\n")

    return manifest_path, metatests_dir, verify_pr, tooling


def _run(manifest_path, metatests_dir, verify_pr, tooling) -> subprocess.CompletedProcess:
    return subprocess.run(
        [
            "python3", str(_SCRIPT),
            "--manifest", str(manifest_path),
            "--metatests-dir", str(metatests_dir),
            "--verify-pr", str(verify_pr),
            "--tooling-checks", str(tooling),
        ],
        capture_output=True, text=True, timeout=30,
    )


def test_script_compiles():
    r = subprocess.run(["python3", "-c", f"import py_compile; py_compile.compile(r'{_SCRIPT}', doraise=True)"],
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stderr


def test_aligned_passes(tmp_path):
    # tooling adds a required detector; manifest must include it too for alignment
    scene = _write_scene(
        tmp_path,
        disk_classes=["AlphaLintTests", "BetaLintTests"],
        manifest_classes=["AlphaLintTests", "BetaLintTests"],
        verify_pr_detectors=["check-foo.py"],
        manifest_detectors=["check-foo.py", "check-contributor-surface.py"],
        tooling_detectors=["check-contributor-surface.py"],
    )
    r = _run(*scene)
    assert r.returncode == 0, f"expected PASS, got {r.returncode}: {r.stdout}{r.stderr}"
    assert "aligned" in r.stdout


def test_class_on_disk_missing_from_manifest_fails(tmp_path):
    scene = _write_scene(
        tmp_path,
        disk_classes=["AlphaLintTests", "BetaLintTests", "GammaLintTests"],
        manifest_classes=["AlphaLintTests", "BetaLintTests"],  # Gamma missing
        verify_pr_detectors=["check-foo.py"],
        manifest_detectors=["check-foo.py"],
    )
    r = _run(*scene)
    assert r.returncode == 1, f"expected FAIL: {r.stdout}"
    assert "GammaLintTests" in r.stdout
    assert "MISSING from T1 manifest" in r.stdout


def test_stale_class_in_manifest_fails(tmp_path):
    scene = _write_scene(
        tmp_path,
        disk_classes=["AlphaLintTests"],
        manifest_classes=["AlphaLintTests", "RemovedLintTests"],  # Removed not on disk
        verify_pr_detectors=["check-foo.py"],
        manifest_detectors=["check-foo.py"],
    )
    r = _run(*scene)
    assert r.returncode == 1, f"expected FAIL: {r.stdout}"
    assert "RemovedLintTests" in r.stdout
    assert "NOT on disk" in r.stdout


def test_ci_detector_absent_from_manifest_fails(tmp_path):
    scene = _write_scene(
        tmp_path,
        disk_classes=["AlphaLintTests"],
        manifest_classes=["AlphaLintTests"],
        verify_pr_detectors=["check-foo.py", "check-bar.py"],  # bar is CI-required
        manifest_detectors=["check-foo.py"],  # bar missing
    )
    r = _run(*scene)
    assert r.returncode == 1, f"expected FAIL: {r.stdout}"
    assert "check-bar.py" in r.stdout
    assert "ABSENT from T1 manifest" in r.stdout


def test_manifest_superset_of_detectors_passes(tmp_path):
    # manifest carries MORE detectors than CI requires — superset is allowed.
    scene = _write_scene(
        tmp_path,
        disk_classes=["AlphaLintTests"],
        manifest_classes=["AlphaLintTests"],
        verify_pr_detectors=["check-foo.py"],
        manifest_detectors=["check-foo.py", "check-extra1.py", "check-extra2.py"],
    )
    r = _run(*scene)
    assert r.returncode == 0, f"expected PASS: {r.stdout}"


def test_tooling_checks_direct_detector_required(tmp_path):
    # A detector invoked directly in tooling-checks.yml is CI-required even if it
    # is not a phase35 detector in verify-pr.sh.
    scene = _write_scene(
        tmp_path,
        disk_classes=["AlphaLintTests"],
        manifest_classes=["AlphaLintTests"],
        verify_pr_detectors=["check-foo.py"],
        manifest_detectors=["check-foo.py"],  # missing the tooling-checks one
        tooling_detectors=["check-contributor-surface.py"],
    )
    r = _run(*scene)
    assert r.returncode == 1, f"expected FAIL: {r.stdout}"
    assert "check-contributor-surface.py" in r.stdout
