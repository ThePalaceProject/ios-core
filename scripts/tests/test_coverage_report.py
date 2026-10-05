"""coverage-report.py: app, package and excluded source are measured separately,
and data that is missing, malformed or partial yields INCOMPLETE, never a number
that reads as a measurement.

The fixtures are xccov `--report --json` and llvm-cov export shapes reduced to
the fields the script reads.

prior-art-checked: tests for the existing coverage-report.py; nothing else in
the tree parses xccov or llvm-cov output.
"""

from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "coverage-report.py"
ROOT = "/ci/ios-core"

_spec = importlib.util.spec_from_file_location("coverage_report", SCRIPT)
cr = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cr)


def _file(rel, covered, executable, root=ROOT):
    return {
        "name": os.path.basename(rel),
        "path": f"{root}/{rel}",
        "coveredLines": covered,
        "executableLines": executable,
        "lineCoverage": covered / executable if executable else 0.0,
    }


def _target(name, files):
    return {
        "name": name,
        "coveredLines": sum(f["coveredLines"] for f in files),
        "executableLines": sum(f["executableLines"] for f in files),
        "lineCoverage": 0.0,
        "files": files,
    }


def _xccov(*targets):
    return {"targets": list(targets)}


APP_FILES = [
    _file("Palace/Book/TPPBook.swift", 80, 100),
    _file("Palace/Book/Views/Cells/BookCell.swift", 0, 50),
]
PKG_FILE = _file("Palace/Packages/PalaceAuth/Sources/PalaceAuth/Token.swift", 30, 40)


def _report(raw, **kw):
    kw.setdefault("exclude_patterns", ["Palace/**/Views/**/*.swift"])
    kw.setdefault("repo_root", ROOT)
    kw.setdefault("expected_packages", ["PalaceAuth"])
    return cr.build_report(raw, **kw)


def _llvm(files, root=ROOT):
    return {
        "type": "llvm.coverage.json.export",
        "version": "2.0.1",
        "data": [{
            "files": [
                {"filename": f"{root}/{rel}",
                 "summary": {"lines": {"count": n, "covered": c}}}
                for rel, c, n in files
            ],
        }],
    }


# --- complete data -----------------------------------------------------------

def test_package_source_in_the_app_target_is_reported_as_package_not_app():
    """Xcode links package objects into Palace.app, so the target name cannot
    tell them apart; the source path does. The app metric must keep the
    denominator it had before packages were instrumented."""
    r = _report(_xccov(_target("Palace.app", APP_FILES + [PKG_FILE])))
    assert r["status"] == "complete", r["incomplete_reasons"]
    assert (r["testable_covered_lines"], r["testable_executable_lines"]) == (80, 100)
    assert (r["covered_lines"], r["executable_lines"]) == (80, 150)
    auth = r["packages_app_suite"]["PalaceAuth"]
    assert (auth["covered_lines"], auth["executable_lines"]) == (30, 40)


def test_excluded_source_is_counted_separately_with_raw_counts():
    r = _report(_xccov(_target("Palace.app", APP_FILES + [PKG_FILE])))
    assert r["app"]["excluded_file_count"] == 1
    assert (r["app"]["excluded_covered_lines"], r["app"]["excluded_executable_lines"]) == (0, 50)
    assert r["excluded_executable_lines"] == 50


def test_exclusions_apply_to_package_views_and_are_reported_per_package():
    view = _file("Palace/Packages/PalaceAuth/Sources/PalaceAuth/Views/Forms/SignIn.swift", 0, 60)
    r = _report(_xccov(_target("Palace.app", APP_FILES + [PKG_FILE, view])))
    auth = r["packages_app_suite"]["PalaceAuth"]
    assert (auth["testable_covered_lines"], auth["testable_executable_lines"]) == (30, 40)
    assert (auth["covered_lines"], auth["executable_lines"]) == (30, 100)
    assert auth["excluded_executable_lines"] == 60


def test_package_with_zero_covered_lines_is_measured_at_zero_not_missing():
    zero = _file("Palace/Packages/PalaceAuth/Sources/PalaceAuth/Token.swift", 0, 40)
    r = _report(_xccov(_target("Palace.app", APP_FILES + [zero])))
    assert r["status"] == "complete", r["incomplete_reasons"]
    assert r["packages_app_suite"]["PalaceAuth"]["testable_coverage"] == 0.0
    assert r["packages_app_suite"]["PalaceAuth"]["executable_lines"] == 40


def test_duplicate_source_path_across_targets_is_counted_once():
    """Packages are linked into both Palace.app and PalaceTests.xctest. Summing
    both entries would double the denominator; the entry with the most covered
    lines is kept (a lower bound of the union) and the duplicate is recorded."""
    in_tests = _file("Palace/Packages/PalaceAuth/Sources/PalaceAuth/Token.swift", 35, 40)
    r = _report(_xccov(
        _target("Palace.app", APP_FILES + [PKG_FILE]),
        _target("PalaceTests.xctest", [in_tests]),
    ))
    auth = r["packages_app_suite"]["PalaceAuth"]
    assert (auth["covered_lines"], auth["executable_lines"]) == (35, 40)
    dup = r["duplicates"]
    assert len(dup) == 1
    assert dup[0]["path"] == "Palace/Packages/PalaceAuth/Sources/PalaceAuth/Token.swift"
    assert dup[0]["kept_target"] == "PalaceTests.xctest"
    assert sorted(dup[0]["targets"]) == ["Palace.app", "PalaceTests.xctest"]


def test_duplicate_app_file_does_not_inflate_the_app_metric():
    again = _file("Palace/Book/TPPBook.swift", 70, 100)
    r = _report(_xccov(_target("Palace.app", APP_FILES + [PKG_FILE]),
                       _target("Palace-noDRM.app", [again])))
    assert (r["testable_covered_lines"], r["testable_executable_lines"]) == (80, 100)


def test_test_sources_and_unattributed_files_stay_out_of_app_and_packages():
    test_src = _file("PalaceTests/TPPBookTests.swift", 90, 100)
    generated = {"name": "resource_bundle_accessor.swift",
                 "path": "/dd/Build/PalaceAuth.build/DerivedSources/resource_bundle_accessor.swift",
                 "coveredLines": 3, "executableLines": 4}
    r = _report(_xccov(_target("Palace.app", APP_FILES + [PKG_FILE, generated]),
                       _target("PalaceTests.xctest", [test_src])))
    assert r["executable_lines"] == 150
    assert r["packages_app_suite"]["PalaceAuth"]["executable_lines"] == 40
    assert r["unattributed"]["executable_lines"] == 104


def test_host_package_measurement_is_kept_separate_from_the_app_suite():
    """`swift test` on macOS and the iOS app suite use different instrumentation
    and platform conditionals; their counts are never added together."""
    host = _llvm([
        ("Palace/Packages/PalaceAuth/Sources/PalaceAuth/Token.swift", 38, 41),
        ("Palace/Packages/PalaceAuth/Tests/PalaceAuthTests/TokenTests.swift", 50, 50),
        ("Palace/Packages/PalaceAuth/.build/debug/runner.swift", 10, 10),
    ])
    r = _report(_xccov(_target("Palace.app", APP_FILES + [PKG_FILE])),
                host_packages={"PalaceAuth": host}, expected_host_packages=["PalaceAuth"])
    assert r["status"] == "complete", r["incomplete_reasons"]
    assert (r["packages_host"]["PalaceAuth"]["covered_lines"],
            r["packages_host"]["PalaceAuth"]["executable_lines"]) == (38, 41)
    assert r["packages_app_suite"]["PalaceAuth"]["executable_lines"] == 40


def test_module_files_carry_counts_and_package():
    r = _report(_xccov(_target("Palace.app", APP_FILES + [PKG_FILE])))
    token = next(f for f in r["files"] if f["name"] == "Token.swift")
    assert token["package"] == "PalaceAuth"
    assert (token["covered_lines"], token["executable_lines"]) == (30, 40)


# --- incomplete data ---------------------------------------------------------

def test_unreadable_coverage_is_incomplete():
    r = _report(None)
    assert r["status"] == "incomplete"
    assert r["incomplete_reasons"]


def test_no_targets_is_incomplete():
    r = _report(_xccov())
    assert r["status"] == "incomplete"
    assert any("application source" in x for x in r["incomplete_reasons"])


def test_app_with_no_executed_line_is_incomplete():
    """Zero covered lines across the whole app means no test executed against an
    instrumented build; it is not a 0% measurement."""
    files = [_file("Palace/Book/TPPBook.swift", 0, 100), PKG_FILE]
    r = _report(_xccov(_target("Palace.app", files)))
    assert r["status"] == "incomplete"
    assert any("no executed line" in x for x in r["incomplete_reasons"])


def test_expected_package_absent_from_the_app_suite_is_incomplete():
    r = _report(_xccov(_target("Palace.app", APP_FILES + [PKG_FILE])),
                expected_packages=["PalaceAuth", "PalaceKeychain"])
    assert r["status"] == "incomplete"
    assert any("PalaceKeychain" in x for x in r["incomplete_reasons"])


def test_named_package_exemption_keeps_the_run_complete_but_is_reported():
    r = _report(_xccov(_target("Palace.app", APP_FILES + [PKG_FILE])),
                expected_packages=["PalaceAuth", "PalaceKeychain"],
                package_exemptions={"PalaceKeychain": "reason"})
    assert r["status"] == "complete", r["incomplete_reasons"]
    assert r["unmeasured_packages"] == {"PalaceKeychain": "reason"}


def test_expected_host_package_without_data_is_incomplete():
    r = _report(_xccov(_target("Palace.app", APP_FILES + [PKG_FILE])),
                host_packages={"PalaceAuth": None},
                expected_host_packages=["PalaceAuth", "PalaceLogging"])
    assert r["status"] == "incomplete"
    joined = " ".join(r["incomplete_reasons"])
    assert "PalaceAuth" in joined and "PalaceLogging" in joined


def test_host_package_file_with_no_package_source_is_incomplete():
    host = _llvm([("Palace/Packages/PalaceAuth/Tests/T.swift", 5, 5)])
    r = _report(_xccov(_target("Palace.app", APP_FILES + [PKG_FILE])),
                host_packages={"PalaceAuth": host}, expected_host_packages=["PalaceAuth"])
    assert r["status"] == "incomplete"


def test_incomplete_shards_mark_the_report_incomplete():
    r = _report(_xccov(_target("Palace.app", APP_FILES + [PKG_FILE])),
                incomplete_reasons=["shard 1 lost 3 classes"])
    assert r["status"] == "incomplete"
    assert "shard 1 lost 3 classes" in r["incomplete_reasons"]


def test_summary_renders_an_incomplete_report():
    text = cr.format_coverage_summary(_report(None))
    assert "INCOMPLETE" in text


# --- command line ------------------------------------------------------------

def _run(tmp_path, *args):
    out = tmp_path / "out.json"
    gh = tmp_path / "gh_output"
    gh.write_text("")
    env = dict(os.environ, GITHUB_OUTPUT=str(gh))
    p = subprocess.run([sys.executable, str(SCRIPT), *args, "--json", str(out),
                        "--repo-root", ROOT, "--expect-package", "PalaceAuth"],
                       capture_output=True, text=True, env=env)
    data = json.loads(out.read_text()) if out.exists() else None
    return p, data, gh.read_text()


def _write(tmp_path, name, obj):
    path = tmp_path / name
    path.write_text(obj if isinstance(obj, str) else json.dumps(obj))
    return str(path)


def test_cli_complete_run_exits_zero_and_publishes_status(tmp_path):
    xc = _write(tmp_path, "xc.json", _xccov(_target("Palace.app", APP_FILES + [PKG_FILE])))
    p, data, gh = _run(tmp_path, "--xccov-json", xc)
    assert p.returncode == 0, p.stderr
    assert data["status"] == "complete"
    assert "coverage_status=complete" in gh
    assert "app-suite|PalaceAuth|30|40" in gh


@pytest.mark.parametrize("content", ["", "{not json", "[]"])
def test_cli_malformed_or_empty_input_is_incomplete_not_a_crash(tmp_path, content):
    xc = _write(tmp_path, "xc.json", content)
    p, data, gh = _run(tmp_path, "--xccov-json", xc)
    assert p.returncode == 3, p.stderr
    assert "Traceback" not in p.stderr
    assert data["status"] == "incomplete"
    assert "coverage_status=incomplete" in gh


def test_cli_missing_result_bundle_is_incomplete(tmp_path):
    p, data, _ = _run(tmp_path, str(tmp_path / "absent.xcresult"))
    assert p.returncode == 3
    assert data["status"] == "incomplete"


def test_cli_missing_host_package_file_is_incomplete(tmp_path):
    xc = _write(tmp_path, "xc.json", _xccov(_target("Palace.app", APP_FILES + [PKG_FILE])))
    p, data, _ = _run(tmp_path, "--xccov-json", xc,
                      "--expect-host-package", "PalaceAuth",
                      "--host-package", f"PalaceAuth={tmp_path / 'nope.json'}")
    assert p.returncode == 3
    assert any("PalaceAuth" in r for r in data["incomplete_reasons"])


def test_cli_host_package_directory_supplies_every_expected_package(tmp_path):
    hostdir = tmp_path / "host"
    hostdir.mkdir()
    (hostdir / "PalaceAuth.json").write_text(json.dumps(
        _llvm([("Palace/Packages/PalaceAuth/Sources/PalaceAuth/Token.swift", 38, 41)])))
    xc = _write(tmp_path, "xc.json", _xccov(_target("Palace.app", APP_FILES + [PKG_FILE])))
    p, data, gh = _run(tmp_path, "--xccov-json", xc, "--host-package-dir", str(hostdir),
                       "--expect-host-package", "PalaceAuth")
    assert p.returncode == 0, p.stderr
    assert data["packages_host"]["PalaceAuth"]["executable_lines"] == 41
    assert "host|PalaceAuth|38|41" in gh


def test_cli_incomplete_reason_flag(tmp_path):
    xc = _write(tmp_path, "xc.json", _xccov(_target("Palace.app", APP_FILES + [PKG_FILE])))
    p, data, _ = _run(tmp_path, "--xccov-json", xc, "--incomplete-reason", "shard 0 timed out")
    assert p.returncode == 3
    assert data["incomplete_reasons"] == ["shard 0 timed out"]


def test_expected_packages_default_to_every_local_package(tmp_path):
    for name in ("PalaceA", "PalaceB"):
        (tmp_path / "Palace" / "Packages" / name).mkdir(parents=True)
        (tmp_path / "Palace" / "Packages" / name / "Package.swift").write_text("")
    (tmp_path / "Palace" / "Packages" / "NotAPackage").mkdir()
    assert cr.discover_packages(str(tmp_path)) == ["PalaceA", "PalaceB"]


def test_every_local_package_is_discovered_in_this_tree():
    found = cr.discover_packages(str(REPO))
    on_disk = sorted(p.parent.name for p in (REPO / "Palace" / "Packages").glob("*/Package.swift"))
    assert found == on_disk and len(found) >= 12


def test_cli_expect_local_packages_names_every_package_missing(tmp_path):
    root = tmp_path / "repo"
    for name in ("PalaceAuth", "PalaceKeychain"):
        (root / "Palace" / "Packages" / name).mkdir(parents=True)
        (root / "Palace" / "Packages" / name / "Package.swift").write_text("")
    files = [_file("Palace/Book/TPPBook.swift", 80, 100, root=str(root)),
             _file("Palace/Packages/PalaceAuth/Sources/PalaceAuth/Token.swift", 30, 40, root=str(root))]
    xc = _write(tmp_path, "xc.json", _xccov(_target("Palace.app", files)))
    out = tmp_path / "out.json"
    p = subprocess.run([sys.executable, str(SCRIPT), "--xccov-json", xc, "--json", str(out),
                        "--repo-root", str(root), "--expect-local-packages"],
                       capture_output=True, text=True)
    data = json.loads(out.read_text())
    assert p.returncode == 3
    assert data["incomplete_reasons"] == ["package PalaceKeychain has no source in the app-suite coverage"]


def test_cli_without_expectations_reports_what_it_found(tmp_path):
    """A local Xcode run has no rewritten coverage metadata, so it expects no
    package; the app measurement alone is complete."""
    xc = _write(tmp_path, "xc.json", _xccov(_target("Palace.app", APP_FILES)))
    out = tmp_path / "out.json"
    p = subprocess.run([sys.executable, str(SCRIPT), "--xccov-json", xc, "--json", str(out),
                        "--repo-root", ROOT], capture_output=True, text=True)
    assert p.returncode == 0, p.stderr
    assert json.loads(out.read_text())["packages_app_suite"] == {}


def test_source_outside_the_checkout_is_never_app_source():
    """A sibling checkout's `.../Palace/Fonts/X.swift` must not join the app
    denominator just because its path contains `/Palace/`."""
    sibling = _file("Palace/Fonts/Font+PalaceUIKit.swift", 5, 55, root="/elsewhere/toolkit")
    r = _report(_xccov(_target("Palace.app", APP_FILES + [PKG_FILE]),
                       _target("PalaceUIKit.framework", [sibling])))
    assert r["executable_lines"] == 150
    assert r["unattributed"]["executable_lines"] == 55
