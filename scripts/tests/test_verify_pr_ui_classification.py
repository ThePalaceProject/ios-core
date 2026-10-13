#!/usr/bin/env python3
"""
verify-pr.sh's accessibility leg must examine a screen whatever its file is named.

PP-5028. The leg chose files by name (View, Cell, Controller, a UI/ folder), so
`TPPReaderSettingsVC.swift` and `SignInWebSheet.swift` were never examined. The
selector now also takes any file that declares a SwiftUI view or a view
controller subclass, the same path-plus-content pairing PP-4976 gave the
audiobook gate.

The tree census below uses a separate Python parser as the oracle, so the shell
predicate is not checked against a copy of itself.
"""

import os
import re
import subprocess
import tempfile

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
VPR = os.path.join(REPO, "scripts", "verify-pr.sh")


def _slice(start_marker: str, end_marker: str) -> str:
    with open(VPR, encoding="utf-8") as fh:
        text = fh.read()
    start = text.index(start_marker)
    end = text.index(end_marker, start)
    return text[start:end]


def classifier_block() -> str:
    block = _slice("# WHAT COUNTS AS A SCREEN.", "# `--ignore-submodules=none`")
    assert "UI_BY_NAME" in block and "UI_BY_DECL" in block, "extraction range has drifted"
    return block


def accessibility_leg() -> str:
    block = _slice('echo "--- Accessibility ---"', "# 6b. Ledger PR-drift check")
    assert 'record "accessibility"' in block, "extraction range has drifted"
    return block


def run(changed: list[str], tail: str, cwd: str = REPO) -> str:
    """Run the real shell block against a changed-file list."""
    script = (
        "#!/usr/bin/env bash\n"
        "CHANGED_SWIFT=$(cat <<'EOF'\n" + "\n".join(changed) + "\nEOF\n)\n"
        + classifier_block()
        + tail
    )
    proc = subprocess.run(["bash", "-s"], input=script, capture_output=True,
                          text=True, cwd=cwd)
    assert proc.returncode == 0, proc.stderr
    return proc.stdout


def classify(changed: list[str], cwd: str = REPO) -> list[str]:
    out = run(changed, '\nprintf "%s\\n" "$CHANGED_UI"\n', cwd)
    return [line for line in out.split("\n") if line.strip()]


def _exists(path: str) -> None:
    assert os.path.exists(os.path.join(REPO, path)), f"fixture file moved: {path}"


# --- Screens the name-based selection missed --------------------------------

@pytest.mark.parametrize("path", [
    "Palace/Reader2/ReaderSettings/TPPReaderSettingsVC.swift",
    "Palace/SignInLogic/SignInWebSheet.swift",
    "Palace/Settings/DeveloperSettings/DeveloperSettingsRows.swift",
])
def test_a_screen_whose_name_does_not_say_view_is_selected(path):
    _exists(path)
    assert classify([path]) == [path]


def test_names_that_already_matched_still_match():
    path = "Palace/Settings/AccountDetailView.swift"
    _exists(path)
    assert classify([path]) == [path]


# --- Over-firing ------------------------------------------------------------

@pytest.mark.parametrize("path", [
    # Name says View, but it is a view model: the suffix list still applies.
    "Palace/SignInLogic/SignInWebSheetViewModel.swift",
    # Takes UIViewController as a `class func` parameter; declares no screen.
    "Palace/ErrorHandling/TPPPresentationUtils.swift",
    "Palace/Utilities/Localization/Strings.swift",
])
def test_files_that_are_not_screens_are_not_selected(path):
    _exists(path)
    assert classify([path]) == []


def test_an_empty_change_list_selects_nothing():
    assert classify([]) == []


def test_a_deleted_file_is_selected_only_by_name():
    assert classify(["Palace/Gone/GoneView.swift", "Palace/Gone/GoneVC.swift"]) == \
        ["Palace/Gone/GoneView.swift"]


# --- Whole tree, against an independent parser ------------------------------

_DECL = re.compile(r"\b(?:struct|class|extension)\s+[A-Za-z_][\w.]*(?:<[^>]*>)?\s*:([^{]*)\{", re.S)
_SCREEN = re.compile(r"(?<!\w)(View|\w*(?:ViewController|NavigationController|"
                     r"TabBarController|HostingController|VC))(?!\w)")


def _declares_screen(path: str) -> bool:
    with open(os.path.join(REPO, path), encoding="utf-8") as fh:
        src = re.sub(r"//[^\n]*", "", fh.read())
    return any(_SCREEN.search(m.group(1)) for m in _DECL.finditer(src))


def test_every_file_in_the_tree_that_declares_a_screen_is_selected():
    tracked = subprocess.run(["git", "ls-files", "Palace/*.swift"], cwd=REPO,
                             capture_output=True, text=True, check=True).stdout.split()
    production = [p for p in tracked if "Tests/" not in p]
    screens = {p for p in production if _declares_screen(p)}
    assert len(screens) > 50, "oracle found too few screens to mean anything"
    assert "Palace/Reader2/ReaderSettings/TPPReaderSettingsVC.swift" in screens

    missed = screens - set(classify(production))
    assert not missed, f"screens the selector does not examine: {sorted(missed)}"


# --- End to end: the leg fails a newly reached screen -----------------------

LEG_TAIL = (
    '\nMUTATION_ONLY=false\n'
    'record() { echo "RECORD $1 $2 $3"; }\n'
)


def test_the_leg_fails_an_unannotated_screen_named_vc():
    with tempfile.TemporaryDirectory() as tmp:
        rel = "Palace/Reader/FooVC.swift"
        os.makedirs(os.path.join(tmp, "Palace/Reader"))
        with open(os.path.join(tmp, rel), "w", encoding="utf-8") as fh:
            fh.write("final class FooVC: UIViewController {\n"
                     "  let b = UIButton(type: .system)\n}\n")
        out = run([rel], LEG_TAIL + accessibility_leg(), cwd=tmp)
    assert "RECORD accessibility fail 1 UI files" in out, out


@pytest.mark.parametrize("path", [
    "Palace/SignInLogic/SignInWebSheet.swift",
    "Palace/Settings/DeveloperSettings/DeveloperSettingsRows.swift",
])
def test_the_screens_the_old_selection_missed_pass_the_leg(path):
    """The two files PP-5028 found unexamined, each with buttons; both must pass now."""
    _exists(path)
    out = run([path], LEG_TAIL + accessibility_leg())
    assert "RECORD accessibility pass" in out, out
