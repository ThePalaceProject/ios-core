"""Tests for scripts/check-swift-sources-compiled.py.

Each finding kind has a fixture that fails on it alone, next to a clean
fixture of the same shape that passes, so a check that cannot fail cannot
pass this suite. The historical case replays the project as it stood before
the orphaned entries were removed.

prior-art-checked: follows the scripts/tests/ pytest convention for checks.
"""
import importlib.util
import itertools
import subprocess
import sys
from pathlib import Path
from typing import NamedTuple

import pytest

SCRIPTS = Path(__file__).resolve().parent.parent
CHECK = SCRIPTS / "check-swift-sources-compiled.py"
FIXTURES = Path(__file__).resolve().parent / "fixtures" / "swift_sources_compiled"


def _load_module():
    spec = importlib.util.spec_from_file_location("swift_sources_compiled", CHECK)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# --- Fixture builder ---------------------------------------------------------

class Project:
    """Builds a minimal pbxproj in Xcode's own text style: unquoted tokens,
    trailing /* comments */, a `//` header, one target with a Sources phase
    and a Resources phase."""

    def __init__(self, hex_ids=True):
        self._n = itertools.count(1)
        self._hex = hex_ids
        self.objects = {}
        self.sources = []
        self.resources = []
        self.main = self._id("MAINGROUP")
        self.objects[self.main] = {"isa": "PBXGroup", "children": [], "sourceTree": '"<group>"'}

    def _id(self, label):
        n = next(self._n)
        return f"{n:024X}" if self._hex else f"{label}{n:04d}FIXTURE"

    def group(self, path, parent=None):
        gid = self._id("GROUP")
        self.objects[gid] = {"isa": "PBXGroup", "children": [], "path": path,
                             "sourceTree": '"<group>"'}
        self.objects[parent or self.main]["children"].append(gid)
        return gid

    def ref(self, name, group=None, built=True, phase="sources", source_tree='"<group>"'):
        rid = self._id("FILEREF")
        self.objects[rid] = {"isa": "PBXFileReference", "lastKnownFileType": "sourcecode.swift",
                             "path": name, "sourceTree": source_tree}
        self.objects[group or self.main]["children"].append(rid)
        if built:
            bid = self._id("BUILDFILE")
            self.objects[bid] = {"isa": "PBXBuildFile", "fileRef": rid}
            (self.sources if phase == "sources" else self.resources).append(bid)
        return rid

    def text(self):
        root, target = self._id("PROJECT"), self._id("TARGET")
        src, res = self._id("SOURCES"), self._id("RESOURCES")
        objs = dict(self.objects)
        objs[src] = {"isa": "PBXSourcesBuildPhase", "files": list(self.sources)}
        objs[res] = {"isa": "PBXResourcesBuildPhase", "files": list(self.resources)}
        objs[target] = {"isa": "PBXNativeTarget", "name": "App", "buildPhases": [src, res]}
        objs[root] = {"isa": "PBXProject", "mainGroup": self.main, "targets": [target]}

        def val(v):
            if isinstance(v, list):
                return "(\n" + "".join(f"\t\t\t\t{x} /* item */,\n" for x in v) + "\t\t\t)"
            return v

        lines = ["// !$*UTF8*$!", "{", "\tarchiveVersion = 1;", "\tobjectVersion = 56;",
                 "\tobjects = {"]
        for oid, body in objs.items():
            fields = " ".join(f"{k} = {val(v)};" for k, v in body.items())
            lines.append(f"\t\t{oid} /* {body['isa']} */ = {{{fields}}};")
        lines += ["\t};", f"\trootObject = {root} /* Project object */;", "}"]
        return "\n".join(lines) + "\n"


class Result(NamedTuple):
    returncode: int
    stdout: str
    stderr: str


@pytest.fixture
def run(tmp_path, monkeypatch, capsys):
    """Run the check in-process against a fixture project with an empty
    allowlist; the shipped allowlist names a file only the real project has."""
    mod = _load_module()

    def _run(project, tracked, allowlist=None):
        monkeypatch.setattr(mod, "ALLOWLIST", allowlist or {})
        pbx = tmp_path / "project.pbxproj"
        pbx.write_text(project.text())
        files = tmp_path / "files.txt"
        files.write_text("\n".join(tracked) + "\n")
        rc = mod.main(["--root", str(tmp_path), "--pbxproj", str(pbx),
                       "--files-from", str(files)])
        out = capsys.readouterr()
        return Result(rc, out.out, out.err)

    return _run


def app_project(hex_ids=True):
    """Palace/A.swift and PalaceTests/ATests.swift, both compiled."""
    p = Project(hex_ids)
    p.group("Palace")
    p.group("PalaceTests")
    p.ref("A.swift", _palace_group(p))
    p.ref("ATests.swift", _tests_group(p))
    return p, ["Palace/A.swift", "PalaceTests/ATests.swift", "Palace/Info.plist"]


def _palace_group(p):
    return p.objects[p.main]["children"][0]


def _tests_group(p):
    return p.objects[p.main]["children"][1]


# --- Clean paths -------------------------------------------------------------

@pytest.mark.parametrize("hex_ids", [True, False], ids=["hex-ids", "hand-written-ids"])
def test_clean_project_passes(run, hex_ids):
    p, tracked = app_project(hex_ids)
    r = run(p, tracked)
    assert r.returncode == 0, r.stdout + r.stderr
    assert "2 tracked file(s) checked, 0 findings" in r.stdout


def test_nested_group_and_source_root_paths_resolve(run):
    """A file is found through nested group paths and through SOURCE_ROOT."""
    p = Project()
    palace = p.group("Palace")
    reader = p.group("Reader", palace)
    p.ref("Page.swift", reader)
    p.ref("Palace/Root.swift", source_tree="SOURCE_ROOT")
    r = run(p, ["Palace/Reader/Page.swift", "Palace/Root.swift"])
    assert r.returncode == 0, r.stdout + r.stderr


def test_swift_package_sources_are_not_required_in_the_project(run):
    p, tracked = app_project()
    tracked += ["Palace/Packages/Kit/Package.swift", "Palace/Packages/Kit/Sources/Kit.swift"]
    r = run(p, tracked)
    assert r.returncode == 0, r.stdout + r.stderr


def test_live_repo_passes():
    r = subprocess.run([sys.executable, str(CHECK), "--root", str(SCRIPTS.parent)],
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
    checked = int(r.stdout.split("(")[1].split()[0])
    assert checked > 1000, r.stdout


# --- Each finding fails on its own -------------------------------------------

def test_tracked_file_with_no_reference_fails(run):
    p, tracked = app_project()
    r = run(p, tracked + ["PalaceTests/OrphanTests.swift"])
    assert r.returncode == 1
    assert "PalaceTests/OrphanTests.swift: unreferenced" in r.stdout
    assert "ruby scripts/pbxproj_add_swift.rb FILE" in r.stdout


def test_uitest_file_with_no_reference_fails(run):
    p, tracked = app_project()
    r = run(p, tracked + ["PalaceUITests/JourneyTests.swift"])
    assert r.returncode == 1
    assert "PalaceUITests/JourneyTests.swift: unreferenced" in r.stdout


@pytest.mark.parametrize("hex_ids", [True, False], ids=["hex-ids", "hand-written-ids"])
def test_reference_without_build_file_fails(run, hex_ids):
    p, tracked = app_project(hex_ids)
    p.ref("B.swift", _palace_group(p), built=False)
    r = run(p, tracked + ["Palace/B.swift"])
    assert r.returncode == 1
    assert "Palace/B.swift: not compiled" in r.stdout
    assert "Palace/A.swift" not in r.stdout


def test_build_file_outside_a_sources_phase_is_not_compiled(run):
    """A Swift file copied as a resource is in the target but never compiled."""
    p, tracked = app_project()
    p.ref("B.swift", _palace_group(p), phase="resources")
    r = run(p, tracked + ["Palace/B.swift"])
    assert r.returncode == 1
    assert "Palace/B.swift: not compiled" in r.stdout


def test_reference_to_missing_file_fails(run):
    p, tracked = app_project()
    p.ref("Gone.swift", _tests_group(p))
    r = run(p, tracked)
    assert r.returncode == 1
    assert "PalaceTests/Gone.swift: dangling" in r.stdout
    assert "pbxproj_remove_swift.rb PalaceTests/Gone.swift" in r.stdout


def test_doubled_path_reference_names_its_real_twin(run):
    """A group-relative ref that repeats its group's path resolves to a missing
    file; the message points at the compiled file it duplicates."""
    p, tracked = app_project()
    p.ref("Palace/A.swift", _palace_group(p), built=False)
    r = run(p, tracked)
    assert r.returncode == 1
    assert "Palace/Palace/A.swift: dangling" in r.stdout
    assert "stale duplicate of Palace/A.swift" in r.stdout


@pytest.mark.parametrize("hex_ids", [True, False], ids=["hex-ids", "hand-written-ids"])
def test_second_unbuilt_reference_to_a_compiled_file_fails(run, hex_ids):
    p, tracked = app_project(hex_ids)
    extra = p.ref("ATests.swift", _tests_group(p), built=False)
    r = run(p, tracked)
    assert r.returncode == 1
    assert "PalaceTests/ATests.swift: duplicate" in r.stdout
    assert extra in r.stdout


def test_reference_outside_the_repo_fails(run):
    p, tracked = app_project()
    p.ref("/Users/someone/Elsewhere.swift", source_tree='"<absolute>"')
    r = run(p, tracked)
    assert r.returncode == 1
    assert "Elsewhere.swift: unresolvable" in r.stdout


# --- Allowlist ---------------------------------------------------------------

SECRET = {"Palace/Secret.swift": ("dangling", "generated at setup")}


def test_allowlisted_finding_is_suppressed(run):
    p, tracked = app_project()
    p.ref("Secret.swift", _palace_group(p))
    r = run(p, tracked, SECRET)
    assert r.returncode == 0, r.stdout


def test_allowlist_entry_matching_no_finding_fails(run):
    p, tracked = app_project()
    r = run(p, tracked, SECRET)
    assert r.returncode == 1
    assert "Palace/Secret.swift: stale allowlist entry" in r.stdout


def test_allowlist_entry_does_not_hide_a_different_finding(run):
    """An entry for one kind of finding leaves other kinds on that path visible."""
    p, tracked = app_project()
    r = run(p, tracked + ["Palace/Secret.swift"], SECRET)
    assert r.returncode == 1
    assert "Palace/Secret.swift: unreferenced" in r.stdout
    assert "Palace/Secret.swift: stale allowlist entry" in r.stdout


def test_shipped_allowlist_entries_each_suppress_a_live_finding():
    mod = _load_module()
    root = SCRIPTS.parent
    project = mod.parse_pbxproj((root / mod.PBXPROJ).read_text())
    raw, _ = mod.find_problems(project, mod._tracked(str(root)), {})
    raw_keys = {(f.path, f.kind) for f in raw}
    assert mod.ALLOWLIST, "expected the APIKeys.swift entry"
    for path, (kind, reason) in mod.ALLOWLIST.items():
        assert (path, kind) in raw_keys, f"{path} no longer needs its entry"
        assert reason.strip()


# --- --list-compiled (used by pre-push-test-gate.sh) -------------------------

def _list_compiled(tmp_path, capsys, project, target):
    pbx = tmp_path / "project.pbxproj"
    pbx.write_text(project.text())
    rc = _load_module().main(["--root", str(tmp_path), "--pbxproj", str(pbx),
                              "--list-compiled", target])
    out = capsys.readouterr()
    return Result(rc, out.out, out.err)


def test_list_compiled_prints_only_the_targets_sources_phase(tmp_path, capsys):
    """Unbuilt references and Swift files in a resources phase are not listed."""
    p, _ = app_project()
    p.ref("Unbuilt.swift", _tests_group(p), built=False)
    p.ref("Copied.swift", _tests_group(p), phase="resources")
    r = _list_compiled(tmp_path, capsys, p, "App")
    assert r.returncode == 0, r.stderr
    assert r.stdout.split() == ["Palace/A.swift", "PalaceTests/ATests.swift"]


def test_list_compiled_unknown_target_is_an_error(tmp_path, capsys):
    p, _ = app_project()
    r = _list_compiled(tmp_path, capsys, p, "PalaceTests")
    assert r.returncode == 2
    assert r.stdout == ""
    assert "no native target named 'PalaceTests'" in r.stderr


def test_list_compiled_target_with_no_swift_is_an_error(tmp_path, capsys):
    """An empty list would make the gate treat every test file as unbuilt."""
    p = Project()
    p.group("Palace")
    p.ref("A.swift", _palace_group(p), built=False)
    r = _list_compiled(tmp_path, capsys, p, "App")
    assert r.returncode == 2
    assert "compiles no Swift files" in r.stderr


# --- Errors are not passes ---------------------------------------------------

def test_empty_scope_is_an_error_not_a_pass(run):
    p, _ = app_project()
    r = run(p, ["README.md"])
    assert r.returncode == 2
    assert "nothing was checked" in r.stderr


def test_unparseable_project_is_an_error(tmp_path):
    pbx = tmp_path / "project.pbxproj"
    pbx.write_text("// !$*UTF8*$!\n{ objects = { A = { isa = PBXGroup; };\n")
    files = tmp_path / "files.txt"
    files.write_text("Palace/A.swift\n")
    r = subprocess.run([sys.executable, str(CHECK), "--pbxproj", str(pbx),
                        "--files-from", str(files)], capture_output=True, text=True)
    assert r.returncode == 2
    assert "ERROR" in r.stderr


def test_parser_reads_quoting_comments_and_slashes():
    mod = _load_module()
    text = ('// !$*UTF8*$!\n{ objects = { X /* c */ = { a = "q\\"uote"; '
            'b = /bin/sh; c = ( 1, 2, ); }; }; rootObject = X; }\n')
    parsed = mod.parse_pbxproj(text)
    assert parsed["objects"]["X"] == {"a": 'q"uote', "b": "/bin/sh", "c": ["1", "2"]}


# --- The historical instance -------------------------------------------------

# Palace.xcodeproj at d5c6726b0, the parent of the commit that removed the
# orphaned entries. The fixture keeps every object on the path to each finding,
# with original IDs, and the matching slice of `git ls-tree` output.
HISTORICAL_FINDINGS = {
    ("PalaceTests/Accessibility/BookImageViewAccessibilityTests.swift", "not compiled"),
    ("PalaceTests/Accessibility/PDFAccessibilityToolbarTests.swift", "not compiled"),
    ("PalaceTests/Network/NetworkClientTests.swift", "not compiled"),
    ("PalaceTests/Reader2/Typography/TypographyServiceIntegrationTests.swift", "not compiled"),
    ("PalaceTests/Reader2/Typography/TypographySettingsTests.swift", "not compiled"),
    ("PalaceTests/Utilities/ExtensionCoverageTests.swift", "not compiled"),
    ("PalaceTests/Reader/ReaderSettingsTests.swift", "dangling"),
    ("Palace/Reader2/UI/Palace/Reader2/UI/KeyboardNavigationHandler.swift", "dangling"),
    ("PalaceTests/Mocks/PalaceTests/Mocks/MockVisualNavigator.swift", "dangling"),
    ("PalaceTests/Reader/PalaceTests/Reader/KeyboardNavigationHandlerTests.swift", "dangling"),
    ("PalaceTests/Book/TPPBookAuthorTests.swift", "duplicate"),
    ("PalaceTests/Book/TPPBookLocationTests.swift", "duplicate"),
    ("Palace/Utilities/Extensions/Array+SafeAccess.swift", "unreferenced"),
    ("Palace/Utilities/JWK/JWK.swift", "unreferenced"),
    ("Palace/Utilities/SwiftUI/HTMLTextView.swift", "unreferenced"),
    ("Palace/Utilities/SwiftUI/View+DismissKeyboard.swift", "unreferenced"),
    ("PalaceTests/Book/BookButtonMapperTests.swift", "unreferenced"),
    ("PalaceTests/CodeReviewFixesTests.swift", "unreferenced"),
}


def test_historical_project_reports_every_known_orphan():
    mod = _load_module()
    project = mod.parse_pbxproj((FIXTURES / "historical.pbxproj").read_text())
    tracked = (FIXTURES / "historical-files.txt").read_text().splitlines()
    findings, _ = mod.find_problems(project, tracked, mod.ALLOWLIST)
    assert {(f.path, f.kind) for f in findings} == HISTORICAL_FINDINGS


def test_historical_project_fails_from_the_command_line():
    r = subprocess.run(
        [sys.executable, str(CHECK), "--pbxproj", str(FIXTURES / "historical.pbxproj"),
         "--files-from", str(FIXTURES / "historical-files.txt")],
        capture_output=True, text=True,
    )
    assert r.returncode == 1
    assert "(18):" in r.stdout
    assert "BKTST00012F27000000FR03" in r.stdout


# --- Wiring ------------------------------------------------------------------

def test_ci_runs_the_check_as_an_effective_step():
    """The tooling workflow invokes it outside comments, echo lines and
    disabled steps, with no flag that narrows the scan."""
    r = subprocess.run(
        [sys.executable, str(SCRIPTS / "workflow_effective_runs.py"),
         str(SCRIPTS.parent / ".github" / "workflows" / "tooling-checks.yml")],
        capture_output=True, text=True, check=True,
    )
    calls = [l.strip() for l in r.stdout.splitlines()
             if l.strip().startswith("python3 scripts/check-swift-sources-compiled.py")]
    assert calls == ["python3 scripts/check-swift-sources-compiled.py"], r.stdout


def test_verify_pr_records_the_check_as_a_leg():
    text = (SCRIPTS / "verify-pr.sh").read_text()
    assert "python3 scripts/check-swift-sources-compiled.py 2>&1" in text
    for status in ("pass", "fail", "skip"):
        assert f'record "swift_sources_compiled" "{status}"' in text
