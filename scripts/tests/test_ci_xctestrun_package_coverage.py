"""ci-xctestrun-package-coverage.py: every local package target gets a coverage
entry that names its real binary as dynamic; other entries are left alone.

prior-art-checked: tests for the new rewrite step in the coverage pipeline.
"""

from __future__ import annotations

import importlib.util
import plistlib
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "ci-xctestrun-package-coverage.py"

_spec = importlib.util.spec_from_file_location("xctestrun_cov", SCRIPT)
mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(mod)

APP = {"Name": "Palace.app", "IsStatic": False, "Architecture": "arm64",
       "ProductPath": "__TESTROOT__/Debug-iphonesimulator/Palace.app/Palace",
       "Toolchains": ["com.apple.dt.toolchain.XcodeDefault"], "IncludeInReport": True,
       "BuildableIdentifier": "A:primary", "SourceFiles": ["Book/TPPBook.swift"],
       "SourceFilesCommonPathPrefix": "/r/Palace/"}
BROKEN = {"Name": "PalaceAuth", "IsStatic": True, "ProductPath": "__TESTROOT__/x", "SourceFiles": []}
THIRD = {"Name": "SwiftSoup", "IsStatic": True, "ProductPath": "__TESTROOT__/s", "SourceFiles": ["a.swift"]}


def _tree(tmp_path):
    repo = tmp_path / "repo"
    for pkg, target, files in (("PalaceAuth", "PalaceAuth", ["Token.swift", "Sub/Flow.swift"]),
                               ("PalaceTriageBot", "TriageBotCore", ["Core.swift"]),
                               ("PalaceEmpty", "PalaceEmpty", [])):
        d = repo / "Palace" / "Packages" / pkg / "Sources" / target
        d.mkdir(parents=True)
        for f in files:
            (d / f).parent.mkdir(parents=True, exist_ok=True)
            (d / f).write_text("")
    products = tmp_path / "Products"
    fw = products / "Debug-iphonesimulator" / "PackageFrameworks" / "PalaceAuth_-1F_PackageProduct.framework"
    fw.mkdir(parents=True)
    (fw / "PalaceAuth_-1F_PackageProduct").write_text("")
    xctestrun = products / "Palace.xctestrun"
    with open(xctestrun, "wb") as f:
        plistlib.dump({"__xctestrun_metadata__": {"CodeCoverageBuildableInfos": [APP, BROKEN, THIRD]},
                       "PalaceTests": {}}, f)
    return repo, xctestrun


def _infos(xctestrun):
    with open(xctestrun, "rb") as f:
        return {e["Name"]: e for e in plistlib.load(f)["__xctestrun_metadata__"]["CodeCoverageBuildableInfos"]}


def _run(xctestrun, repo):
    return subprocess.run([sys.executable, str(SCRIPT), str(xctestrun), "--repo-root", str(repo)],
                          capture_output=True, text=True)


def test_package_framework_entry_is_rewritten_as_dynamic_with_its_sources(tmp_path):
    repo, xctestrun = _tree(tmp_path)
    p = _run(xctestrun, repo)
    assert p.returncode == 0, p.stderr
    auth = _infos(xctestrun)["PalaceAuth"]
    assert auth["IsStatic"] is False
    assert auth["ProductPath"] == ("__TESTROOT__/Debug-iphonesimulator/PackageFrameworks/"
                                   "PalaceAuth_-1F_PackageProduct.framework/PalaceAuth_-1F_PackageProduct")
    assert auth["SourceFiles"] == ["Sub/Flow.swift", "Token.swift"]
    assert auth["SourceFilesCommonPathPrefix"] == f"{repo}/Palace/Packages/PalaceAuth/Sources/PalaceAuth/"


def test_target_without_a_framework_points_at_the_app_binary(tmp_path):
    repo, xctestrun = _tree(tmp_path)
    _run(xctestrun, repo)
    core = _infos(xctestrun)["TriageBotCore"]
    assert core["ProductPath"] == APP["ProductPath"]
    assert core["IsStatic"] is False


def test_other_entries_are_kept_unchanged_and_names_stay_unique(tmp_path):
    repo, xctestrun = _tree(tmp_path)
    _run(xctestrun, repo)
    with open(xctestrun, "rb") as f:
        infos = plistlib.load(f)["__xctestrun_metadata__"]["CodeCoverageBuildableInfos"]
    names = [e["Name"] for e in infos]
    assert sorted(names) == ["Palace.app", "PalaceAuth", "SwiftSoup", "TriageBotCore"]
    by = {e["Name"]: e for e in infos}
    assert by["Palace.app"] == APP and by["SwiftSoup"] == THIRD


def test_missing_metadata_fails(tmp_path):
    repo, xctestrun = _tree(tmp_path)
    with open(xctestrun, "wb") as f:
        plistlib.dump({"PalaceTests": {}}, f)
    assert _run(xctestrun, repo).returncode == 1


def test_no_package_sources_fails(tmp_path):
    _, xctestrun = _tree(tmp_path)
    assert _run(xctestrun, tmp_path / "empty").returncode == 1


def test_unreadable_xctestrun_is_an_input_error(tmp_path):
    bad = tmp_path / "bad.xctestrun"
    bad.write_text("not a plist")
    assert _run(bad, tmp_path).returncode == 2


def test_this_tree_has_a_source_directory_for_every_package():
    targets = mod.package_targets(str(REPO))
    packages = {p.parent.name for p in (REPO / "Palace" / "Packages").glob("*/Package.swift")}
    owners = {Path(src).parents[1].name for src in targets.values()}
    assert owners == packages
