"""enforce_coverage_floors.py: an incomplete report can never pass, module and
package floors compare raw line counts, and a genuine violation fails.

prior-art-checked: tests for the existing enforce_coverage_floors.py.
"""

from __future__ import annotations

import importlib
import json
import subprocess
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "enforce_coverage_floors.py"
sys.path.insert(0, str(REPO / "scripts"))
ecf = importlib.import_module("enforce_coverage_floors")


def _scope(covered, executable):
    return {"testable_covered_lines": covered, "testable_executable_lines": executable,
            "testable_coverage": 100.0 * covered / executable if executable else 0.0}


def _coverage(status="complete", testable=60.0, files=(), packages=None, host=None, reasons=(),
              expected=("PalaceAuth",), expected_host=("PalaceAuth",)):
    return {
        "expected_packages": list(expected),
        "expected_host_packages": list(expected_host),
        "status": status,
        "incomplete_reasons": list(reasons),
        "testable_coverage": testable,
        "targets": [],
        "files": [{"name": n, "path": f"Palace/X/{n}", "covered_lines": c, "executable_lines": e,
                   "coverage": 100.0 * c / e if e else 0.0} for n, c, e in files],
        "packages_app_suite": packages or {},
        "packages_host": host or {},
    }


def _run(tmp_path, coverage, floors):
    cov = tmp_path / "coverage.json"
    flo = tmp_path / "floors.json"
    cov.write_text(coverage if isinstance(coverage, str) else json.dumps(coverage))
    flo.write_text(json.dumps(floors))
    return subprocess.run([sys.executable, str(SCRIPT), str(cov), "--floors", str(flo)],
                          capture_output=True, text=True)


FLOORS = {"overall": 0.5, "modules": {"TPPBook": 0.5},
          "packages": {"PalaceAuth": 0.5}, "host_packages": {"PalaceAuth": 0.5}}
GOOD = dict(files=[("TPPBook.swift", 80, 100)],
            packages={"PalaceAuth": _scope(30, 40)}, host={"PalaceAuth": _scope(38, 41)})


def test_complete_report_meeting_every_floor_passes(tmp_path):
    p = _run(tmp_path, _coverage(**GOOD), FLOORS)
    assert p.returncode == 0, p.stdout + p.stderr
    assert "pkg:PalaceAuth" in p.stdout and "host:PalaceAuth" in p.stdout


def test_incomplete_report_exits_three_even_when_every_floor_is_met(tmp_path):
    p = _run(tmp_path, _coverage(status="incomplete", reasons=["shard 1 lost 3 classes"], **GOOD), FLOORS)
    assert p.returncode == 3
    assert "INCOMPLETE" in p.stdout + p.stderr
    assert "shard 1 lost 3 classes" in p.stdout + p.stderr
    assert "Coverage gate: PASS" not in p.stdout


def test_report_without_a_status_is_incomplete(tmp_path):
    cov = _coverage(**GOOD)
    del cov["status"]
    assert _run(tmp_path, cov, FLOORS).returncode == 3


@pytest.mark.parametrize("content", ["", "{bad", "{}"])
def test_malformed_or_empty_coverage_file_is_an_input_error(tmp_path, content):
    assert _run(tmp_path, content, FLOORS).returncode == 2


def test_missing_coverage_file_is_an_input_error(tmp_path):
    flo = tmp_path / "floors.json"
    flo.write_text(json.dumps(FLOORS))
    p = subprocess.run([sys.executable, str(SCRIPT), str(tmp_path / "absent.json"), "--floors", str(flo)],
                       capture_output=True, text=True)
    assert p.returncode == 2


def test_module_below_its_floor_fails(tmp_path):
    p = _run(tmp_path, _coverage(**dict(GOOD, files=[("TPPBook.swift", 40, 100)])), FLOORS)
    assert p.returncode == 1
    assert any(ln.split()[:1] == ["TPPBook"] and ln.split()[-1] == "FAIL" for ln in p.stdout.splitlines())


def _row(stdout, name):
    return next(ln.split() for ln in stdout.splitlines() if ln.split()[:1] == [name])


@pytest.mark.parametrize("covered,code,status", [
    (500, 0, "PASS"),     # at the floor (0.5 of 1000 lines)
    (486, 0, "WITHIN"),   # 1.4 points under
    (485, 0, "WITHIN"),   # exactly the tolerance under
    (484, 1, "FAIL"),     # 1.6 points under
])
def test_app_module_fails_only_beyond_the_tolerance(tmp_path, covered, code, status):
    """Run-to-run variance on identical code reached 1.2 points (#1601)."""
    p = _run(tmp_path, _coverage(**dict(GOOD, files=[("TPPBook.swift", covered, 1000)])), FLOORS)
    assert p.returncode == code, p.stdout + p.stderr
    assert _row(p.stdout, "TPPBook")[3] == status


def test_overall_fails_only_beyond_the_tolerance(tmp_path):
    assert _run(tmp_path, _coverage(testable=48.6, **GOOD), FLOORS).returncode == 0
    assert _run(tmp_path, _coverage(testable=48.4, **GOOD), FLOORS).returncode == 1


def test_tolerance_is_one_and_a_half_points():
    assert ecf.APP_FLOOR_TOLERANCE == pytest.approx(0.015)


@pytest.mark.parametrize("scope", ["packages", "host"])
def test_package_five_points_below_its_floor_is_reported_but_does_not_fail(tmp_path, scope):
    """Package measurements vary between runs of identical code; they are advisory."""
    low = {"PalaceAuth": _scope(18, 40)}  # 45%, floor 50%
    p = _run(tmp_path, _coverage(**dict(GOOD, **{scope: low})), FLOORS)
    assert p.returncode == 0, p.stdout + p.stderr
    prefix = "pkg:" if scope == "packages" else "host:"
    assert _row(p.stdout, prefix + "PalaceAuth")[3:] == ["FAIL", "advisory"]
    assert "advisory" in p.stdout.split("Coverage gate:")[1]


def test_package_module_below_its_floor_is_advisory(tmp_path):
    floors = dict(FLOORS, package_modules={"TPPBookRegistry": 0.5})
    low = _coverage(**dict(GOOD, files=[("TPPBook.swift", 80, 100), ("TPPBookRegistry.swift", 1, 10)]))
    p = _run(tmp_path, low, floors)
    assert p.returncode == 0, p.stdout + p.stderr
    assert _row(p.stdout, "TPPBookRegistry")[3:] == ["FAIL", "advisory"]


def test_app_violation_fails_even_when_an_advisory_package_is_also_low(tmp_path):
    both = _coverage(**dict(GOOD, files=[("TPPBook.swift", 40, 100)], packages={"PalaceAuth": _scope(10, 40)}))
    assert _run(tmp_path, both, FLOORS).returncode == 1


@pytest.mark.parametrize("scope,key,prefix", [
    ("packages", "packages", "pkg:"), ("host_packages", "host", "host:")])
def test_a_scope_removed_from_advisory_blocks_again(monkeypatch, scope, key, prefix):
    """ADVISORY_SCOPES decides the behaviour, not just the label."""
    cov = _coverage(**dict(GOOD, **{key: {"PalaceAuth": _scope(18, 40)}}))
    monkeypatch.setattr(ecf, "ADVISORY_SCOPES", tuple(s for s in ecf.ADVISORY_SCOPES if s != scope))
    rows, ok = ecf.evaluate(cov, FLOORS, baseline_only=False)
    row = next(r for r in rows if r["module"] == prefix + "PalaceAuth")
    assert not ok and row["status"] == "FAIL" and not row["advisory"]


def test_package_module_removed_from_advisory_blocks_again(monkeypatch):
    cov = _coverage(**dict(GOOD, files=[("TPPBook.swift", 80, 100), ("TPPBookRegistry.swift", 1, 10)]))
    monkeypatch.setattr(ecf, "ADVISORY_SCOPES", ("packages", "host_packages"))
    _, ok = ecf.evaluate(cov, dict(FLOORS, package_modules={"TPPBookRegistry": 0.5}), baseline_only=False)
    assert not ok


def test_within_rows_are_named_in_the_summary(tmp_path):
    p = _run(tmp_path, _coverage(**dict(GOOD, files=[("TPPBook.swift", 490, 1000)])), FLOORS)
    assert p.returncode == 0
    assert "Within the 1.5-point tolerance: TPPBook" in p.stdout


def test_incomplete_report_still_exits_three_with_advisory_packages_low(tmp_path):
    cov = _coverage(status="incomplete", reasons=["no test result bundle"],
                    **dict(GOOD, packages={"PalaceAuth": _scope(1, 40)}))
    assert _run(tmp_path, cov, FLOORS).returncode == 3


def test_package_with_a_floor_but_no_data_is_missing_and_fails(tmp_path):
    p = _run(tmp_path, _coverage(**dict(GOOD, packages={})), FLOORS)
    assert p.returncode == 1
    assert any(ln.startswith("pkg:PalaceAuth") and "MISSING" in ln for ln in p.stdout.splitlines())


def test_violation_rows_keep_the_four_column_shape_verify_pr_parses(tmp_path):
    """verify-pr.sh reads failing modules with `NF == 4 && $4 == "FAIL"`; an
    advisory row has a fifth column so it is shown but not counted."""
    p = _run(tmp_path, _coverage(**dict(GOOD, files=[("TPPBook.swift", 40, 100)],
                                        packages={"PalaceAuth": _scope(10, 40)})), FLOORS)
    assert len(_row(p.stdout, "TPPBook")) == 4
    assert len(_row(p.stdout, "pkg:PalaceAuth")) == 5


def test_module_matching_several_files_uses_line_counts_not_a_mean_of_percentages():
    """A 10-line file at 100% and a 990-line file at 0% is 1% covered, not 50%."""
    cov = _coverage(files=[("TPPBook.swift", 10, 10), ("TPPBook.swift", 0, 990)])
    assert ecf.find_module_coverage(cov, "TPPBook") == pytest.approx(0.01)


def test_package_floor_compares_testable_line_counts():
    cov = _coverage(packages={"PalaceAuth": _scope(1, 3)})
    def status(floor):
        rows, _ = ecf.evaluate(cov, {"overall": 0.0, "modules": {}, "packages": {"PalaceAuth": floor}},
                               baseline_only=False)
        return next(r["status"] for r in rows if r["module"] == "pkg:PalaceAuth")
    assert status(0.3333) == "PASS"
    assert status(0.34) == "FAIL"


def test_report_that_collected_no_package_data_compares_app_floors_only(tmp_path):
    """A local Xcode run measures the app only; its package floors are not
    compared (CI expects them, so missing data there is INCOMPLETE instead)."""
    cov = _coverage(files=[("TPPBook.swift", 80, 100)], expected=(), expected_host=())
    floors = dict(FLOORS, package_modules={"TPPBookRegistry": 0.5})
    p = _run(tmp_path, cov, floors)
    assert p.returncode == 0, p.stdout + p.stderr
    assert "pkg:" not in p.stdout and "host:" not in p.stdout and "TPPBookRegistry" not in p.stdout
    assert "not compared" in p.stderr


def test_report_that_collected_app_suite_packages_still_fails_a_missing_one(tmp_path):
    cov = _coverage(files=[("TPPBook.swift", 80, 100)], packages={}, host={"PalaceAuth": _scope(38, 41)})
    p = _run(tmp_path, cov, FLOORS)
    assert p.returncode == 1
    assert any(ln.startswith("pkg:PalaceAuth") and "MISSING" in ln for ln in p.stdout.splitlines())


def test_package_module_with_no_data_fails_when_packages_were_collected(tmp_path):
    floors = dict(FLOORS, package_modules={"TPPBookRegistry": 0.5})
    absent = _coverage(**GOOD)
    p = _run(tmp_path, absent, floors)
    assert p.returncode == 1
    assert any(ln.startswith("TPPBookRegistry") and "MISSING" in ln for ln in p.stdout.splitlines())


def test_ambiguous_module_match_is_an_input_error_not_a_violation(tmp_path):
    cov = _coverage(**GOOD)
    cov["files"] += [{"name": "TPPBook.swift", "coverage": 10.0}, {"name": "TPPBook.swift", "coverage": 90.0}]
    p = _run(tmp_path, cov, FLOORS)
    assert p.returncode == 2
    assert "Traceback" not in p.stderr


def test_write_baseline_records_package_floors_rounded_down(tmp_path):
    cov = _coverage(**dict(GOOD, packages={"PalaceAuth": _scope(2, 3)}, host={"PalaceAuth": _scope(1, 3)}))
    covf, flo = tmp_path / "c.json", tmp_path / "f.json"
    covf.write_text(json.dumps(cov))
    flo.write_text(json.dumps(FLOORS))
    p = subprocess.run([sys.executable, str(SCRIPT), str(covf), "--floors", str(flo), "--write-baseline"],
                       capture_output=True, text=True)
    assert p.returncode == 0, p.stderr
    written = json.loads(flo.read_text())
    assert written["packages"] == {"PalaceAuth": 0.6666}
    assert written["host_packages"] == {"PalaceAuth": 0.3333}


def test_write_baseline_keeps_package_modules_and_exemptions(tmp_path):
    cov = _coverage(**dict(GOOD, files=[("TPPBook.swift", 80, 100), ("TPPBookRegistry.swift", 7, 9)]))
    floors = dict(FLOORS, package_modules={"TPPBookRegistry": 0.5}, unmeasured={"X": "why"})
    covf, flo = tmp_path / "c.json", tmp_path / "f.json"
    covf.write_text(json.dumps(cov))
    flo.write_text(json.dumps(floors))
    subprocess.run([sys.executable, str(SCRIPT), str(covf), "--floors", str(flo), "--write-baseline"],
                   capture_output=True, text=True, check=True)
    written = json.loads(flo.read_text())
    assert written["package_modules"] == {"TPPBookRegistry": 0.7777}
    assert written["unmeasured"] == {"X": "why"}


def test_write_baseline_refuses_incomplete_data(tmp_path):
    covf, flo = tmp_path / "c.json", tmp_path / "f.json"
    covf.write_text(json.dumps(_coverage(status="incomplete", **GOOD)))
    flo.write_text(json.dumps(FLOORS))
    p = subprocess.run([sys.executable, str(SCRIPT), str(covf), "--floors", str(flo), "--write-baseline"],
                       capture_output=True, text=True)
    assert p.returncode == 3
    assert json.loads(flo.read_text()) == FLOORS


@pytest.mark.parametrize("expected,expected_host,shown,hidden", [
    (("PalaceAuth",), (), "pkg:PalaceAuth", "host:PalaceAuth"),
    ((), ("PalaceAuth",), "host:PalaceAuth", "pkg:PalaceAuth"),
])
def test_each_package_floor_follows_its_own_measurement(tmp_path, expected, expected_host, shown, hidden):
    floors = dict(FLOORS, package_modules={"TPPBookRegistry": 0.5})
    cov = _coverage(**dict(GOOD, expected=expected, expected_host=expected_host,
                           files=[("TPPBook.swift", 80, 100), ("TPPBookRegistry.swift", 9, 10)]))
    p = _run(tmp_path, cov, floors)
    rows = [ln.split()[0] for ln in p.stdout.splitlines() if ln.strip()]
    assert shown in rows and hidden not in rows
    assert ("TPPBookRegistry" in rows) == bool(expected)


def test_write_baseline_from_a_local_report_keeps_the_package_floors(tmp_path):
    """A local report collects no package data; rewriting the baseline from it
    must not delete the floors CI compares."""
    cov = _coverage(**dict(GOOD, expected=(), expected_host=(),
                           files=[("TPPBook.swift", 80, 100), ("TPPBookRegistry.swift", 9, 10)]))
    floors = dict(FLOORS, package_modules={"TPPBookRegistry": 0.5})
    covf, flo = tmp_path / "c.json", tmp_path / "f.json"
    covf.write_text(json.dumps(cov))
    flo.write_text(json.dumps(floors))
    subprocess.run([sys.executable, str(SCRIPT), str(covf), "--floors", str(flo), "--write-baseline"],
                   capture_output=True, text=True, check=True)
    written = json.loads(flo.read_text())
    assert written["packages"] == FLOORS["packages"]
    assert written["host_packages"] == FLOORS["host_packages"]
    assert written["package_modules"] == {"TPPBookRegistry": 0.5}
