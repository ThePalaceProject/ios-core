"""Tests for scripts/check-package-tests-wired.sh.

prior-art-checked: follows the scripts/tests/ pytest convention used by the
other gate tests. `harness capabilities` has no SPM test-wiring capability.

This gate exists because 144 package tests ran nowhere for four months while
reading as coverage. A gate against that failure mode which is itself only
hand-proved would be the same joke one level up, so every arm below asserts
BOTH directions: the red arm must actually go red, and the green arm must not.

Two real defects in the gate were found by writing these, not by reading it:
a commented-out step satisfied the match, and `grep -v | grep -q` turned
SIGPIPE into a false UNWIRED under `set -o pipefail`.
"""
import os
import re
import subprocess
from pathlib import Path

GATE = Path(__file__).resolve().parent.parent / "check-package-tests-wired.sh"

WF = ".github/workflows/unit-testing.yml"


def _tree(root: Path, workflow_body: str, packages: dict) -> Path:
    """packages: {name: n_test_files}. 0 means a Tests dir with no test file."""
    wf = root / WF
    wf.parent.mkdir(parents=True, exist_ok=True)
    wf.write_text(workflow_body)
    for name, n in packages.items():
        tests = root / "Palace" / "Packages" / name / "Tests"
        tests.mkdir(parents=True, exist_ok=True)
        (root / "Palace" / "Packages" / name / "Sources").mkdir(parents=True, exist_ok=True)
        for i in range(n):
            (tests / f"T{i}.swift").write_text(
                f"import XCTest\nfinal class T{i}: XCTestCase {{ func testThing() {{}} }}\n"
            )
        if n == 0:
            (tests / "README.md").write_text("scaffolding only\n")
    return root


def _run(root: Path) -> subprocess.CompletedProcess:
    return subprocess.run(["bash", str(GATE), str(root)], capture_output=True, text=True)


def _step(pkg: str) -> str:
    return f"      - name: Run {pkg} package tests\n        run: swift test --package-path Palace/Packages/{pkg}\n"


BASE = "name: unit-testing\njobs:\n  test:\n    steps:\n"


def test_wired_package_passes(tmp_path):
    root = _tree(tmp_path, BASE + _step("PalaceAuth"), {"PalaceAuth": 3})
    r = _run(root)
    assert r.returncode == 0, r.stdout + r.stderr
    assert "ok" in r.stdout


def test_unwired_package_fails(tmp_path):
    """The whole point. A package whose tests nothing runs must go red."""
    root = _tree(tmp_path, BASE + _step("PalaceAuth"), {"PalaceAuth": 3, "PalaceGhost": 2})
    r = _run(root)
    assert r.returncode == 1
    assert "UNWIRED" in r.stderr
    assert "PalaceGhost" in r.stderr
    assert "PalaceAuth" not in r.stderr


def test_commented_out_step_does_not_count_as_wired(tmp_path):
    """A reviewer's finding, measured not theorised.

    Anchoring the match to a real `swift test --package-path` invocation is not
    enough, because a commented-out step still CONTAINS that invocation. The
    realistic failure: someone comments out a flaky package step during an
    incident, the suite goes dark again, and the gate built to catch exactly
    that stays green.
    """
    body = BASE + "      # - run: swift test --package-path Palace/Packages/PalaceGhost\n"
    root = _tree(tmp_path, body, {"PalaceGhost": 2})
    r = _run(root)
    assert r.returncode == 1, "a commented-out step is not wiring\n" + r.stdout + r.stderr
    assert "PalaceGhost" in r.stderr


def test_bare_mention_does_not_count_as_wired(tmp_path):
    """Prose naming the path is not an invocation.

    The mention must be on a NON-comment line or this arm is inert: the comment
    strip alone already rejects a `#`-prefixed mention, so a commented fixture
    passes with or without the invocation anchor. Found by mutation — dropping
    the anchor to a bare path match left the commented version of this test
    green. A step's `name:` is the realistic shape.
    """
    body = BASE + "      - name: TODO wire Palace/Packages/PalaceGhost\n        run: echo skipped\n"
    root = _tree(tmp_path, body, {"PalaceGhost": 2})
    r = _run(root)
    assert r.returncode == 1, "a mention is not an invocation\n" + r.stdout + r.stderr
    assert "PalaceGhost" in r.stderr


def test_prefix_collision_does_not_count_as_wired(tmp_path):
    """Wiring PalaceAuthExtras must not mark PalaceAuth as covered."""
    root = _tree(tmp_path, BASE + _step("PalaceAuthExtras"),
                 {"PalaceAuth": 2, "PalaceAuthExtras": 2})
    r = _run(root)
    assert r.returncode == 1
    assert "PalaceAuth " in r.stderr or "PalaceAuth —" in r.stderr


def test_continue_on_error_step_does_not_count_as_wired(tmp_path):
    """A step that cannot fail the build is not enforcement.

    This is the likeliest real shape of the incident the gate exists to catch:
    a package suite goes flaky, someone marks the step continue-on-error to
    unblock a release, and the tests are dark again while the step is still
    right there in the YAML. unit-testing.yml already uses continue-on-error
    14 times, so this is not exotic.
    """
    body = (BASE + "      - name: Run PalaceGhost package tests\n"
                   "        continue-on-error: true\n"
                   "        run: swift test --package-path Palace/Packages/PalaceGhost\n")
    root = _tree(tmp_path, body, {"PalaceGhost": 2})
    r = _run(root)
    assert r.returncode == 1, "a continue-on-error step cannot fail the build\n" + r.stdout
    assert "PalaceGhost" in r.stderr


def test_if_false_step_does_not_count_as_wired(tmp_path):
    """A step gated off never runs. Step-level `if:` appears 19 times in
    unit-testing.yml, so this is the other likely door."""
    body = (BASE + "      - name: Run PalaceGhost package tests\n"
                   "        if: false\n"
                   "        run: swift test --package-path Palace/Packages/PalaceGhost\n")
    root = _tree(tmp_path, body, {"PalaceGhost": 2})
    r = _run(root)
    assert r.returncode == 1, "an if:false step never runs\n" + r.stdout
    assert "PalaceGhost" in r.stderr


def test_expression_if_is_still_treated_as_wired(tmp_path):
    """The other direction, which matters just as much.

    Only a LITERAL false is provably dead. Guessing at a ${{ }} expression
    would silently drop real coverage and make the gate red on a correctly
    wired tree — which is how a gate gets switched off.
    """
    body = (BASE + "      - name: Run PalaceGhost package tests\n"
                   "        if: ${{ !cancelled() }}\n"
                   "        run: swift test --package-path Palace/Packages/PalaceGhost\n")
    root = _tree(tmp_path, body, {"PalaceGhost": 2})
    r = _run(root)
    assert r.returncode == 0, "a conditional step is still enforcement\n" + r.stdout + r.stderr


def test_invocation_inside_an_echo_does_not_count_as_wired(tmp_path):
    """Printing the command is not running it."""
    # UNQUOTED deliberately. With the path inside quotes the trailing `"` already
    # defeats the ([[:space:]]|$) boundary, so the arm would pass because of the
    # word-boundary check rather than the echo strip — inert, and it measured as
    # a surviving mutant when first written.
    body = (BASE + "      - name: Explain\n"
                   "        run: echo swift test --package-path Palace/Packages/PalaceGhost\n")
    root = _tree(tmp_path, body, {"PalaceGhost": 2})
    r = _run(root)
    assert r.returncode == 1, "an echoed command is not an invocation\n" + r.stdout
    assert "PalaceGhost" in r.stderr


def test_malformed_workflow_is_not_detected_and_can_read_as_wired(tmp_path):
    """The honest negative, and the arm that used to assert its opposite.

    This test previously claimed the gate "cannot be fooled into saying a
    package is wired" on malformed input. It passed — but only because its
    fixture's broken YAML happened to contain no `run:` body at all. Give the
    same malformed file a real invocation and the gate reports `ok`, exit 0.

    The extractor is stdlib-only (PyYAML is absent from /usr/bin/python3, so
    importing it broke the gate for any restricted-PATH run), which means it has
    no parse step and therefore no way to fail closed on malformed input. The
    compensating control is GitHub's own parser: a workflow it cannot parse
    never runs, so this gate's answer about a malformed file decides nothing.

    Pinning the REAL behaviour is what stops the claim drifting back. The same
    inverted claim was corrected in the module docstring and the commit body a
    round earlier and survived here, one file downstream.
    """
    body = ('name: w\non: push\njobs:\n  test:\n    steps:\n'
            '      - name: "unterminated\n'
            '        run: swift test --package-path Palace/Packages/PalaceGhost\n')
    root = _tree(tmp_path, body, {"PalaceGhost": 2})
    r = _run(root)
    assert r.returncode == 0, (
        "documenting the real behaviour: malformed YAML carrying a real "
        "invocation reads as WIRED\n" + r.stdout + r.stderr
    )
    assert "ok" in r.stdout


def test_malformed_workflow_without_an_invocation_still_reports_unwired(tmp_path):
    """The other half, so the arm above cannot be mistaken for a blanket pass."""
    root = _tree(tmp_path, "jobs:\n  test:\n    steps:\n   - bad: [indent\n",
                 {"PalaceGhost": 2})
    r = _run(root)
    assert r.returncode == 1, r.stdout + r.stderr
    assert "UNWIRED" in r.stderr


def test_workflow_with_no_steps_is_an_error(tmp_path):
    """A workflow file that declares no steps at all is not a workflow, and
    must not be read as a clean scan."""
    root = _tree(tmp_path, "name: nothing\non: push\n", {"PalaceGhost": 2})
    r = _run(root)
    assert r.returncode == 2, r.stdout + r.stderr
    assert "ERROR" in r.stderr


def test_allowlisted_package_passes_unwired(tmp_path):
    """PalaceKeychain is the live entry: it hangs under macOS swift test, and
    the mechanism is recorded rather than the package silently skipped."""
    root = _tree(tmp_path, BASE + _step("PalaceAuth"),
                 {"PalaceAuth": 1, "PalaceKeychain": 4})
    r = _run(root)
    assert r.returncode == 0, r.stdout + r.stderr
    assert "allowed" in r.stdout and "PalaceKeychain" in r.stdout


def test_empty_tests_dir_is_scaffolding_not_a_dark_suite(tmp_path):
    root = _tree(tmp_path, BASE, {"PalaceEmpty": 0})
    r = _run(root)
    assert r.returncode == 0, r.stdout + r.stderr
    assert "PalaceEmpty" not in r.stderr
    # Distinct from the broken-scan case below: a Tests DIRECTORY was found, it
    # just holds no test file. Collapsing the two zeroes would redden a tree
    # with nothing wrong with it.
    assert "NO package test targets" not in r.stderr


def test_missing_workflow_is_an_error_not_a_pass(tmp_path):
    """Absence must not render as success — the recurring failure in this repo."""
    (tmp_path / "Palace" / "Packages" / "PalaceGhost" / "Tests").mkdir(parents=True)
    (tmp_path / "Palace" / "Packages" / "PalaceGhost" / "Tests" / "T.swift").write_text(
        "func testX() {}\n"
    )
    r = _run(tmp_path)
    assert r.returncode == 2
    assert "ERROR" in r.stderr


def test_many_wired_packages_still_pass(tmp_path):
    """Regression guard for a SIGPIPE bug that made the gate size-dependent.

    `grep -vE ... | grep -q ...` reads as equivalent to a single match and is
    not: grep -q exits at the first hit, the upstream grep takes SIGPIPE (141),
    and `set -o pipefail` promotes that to a FAILED check for a package that IS
    wired. It only reproduces once the workflow is long enough that the upstream
    still has output buffered — on a three-line fixture it passes. So this arm
    pads the workflow past that threshold deliberately.
    """
    pkgs = [f"PalacePkg{i}" for i in range(6)]
    # Two properties make this arm able to fail, and it was inert without both:
    #   - the padding must SURVIVE the comment strip, or there is nothing left
    #     to buffer (an all-comment filler made the mutant pass);
    #   - the wired steps must come BEFORE the padding, so `grep -q` matches
    #     early and closes the pipe while the upstream still has output to
    #     write. With the steps last, the upstream is already done and no
    #     SIGPIPE occurs.
    # 3000 lines is comfortably past the 64KB pipe buffer.
    filler = "".join(f"      - name: padding step {i} to outrun the pipe buffer\n"
                     for i in range(3000))
    body = BASE + "".join(_step(p) for p in pkgs) + filler
    root = _tree(tmp_path, body, {p: 2 for p in pkgs})
    r = _run(root)
    assert r.returncode == 0, (
        "wired packages must pass regardless of workflow size\n" + r.stdout + r.stderr
    )


def test_missing_packages_dir_is_an_error_not_a_pass(tmp_path):
    """No Palace/Packages is not "every package is wired".

    The gate used to exit 0 here while its sibling ceiling gate exits 2 on the
    same shape, and the asymmetry was reachable: a reviewer relocated
    Palace/Packages to Palace/Modules and got exit 0 with every package test
    still dark.
    """
    wf = tmp_path / WF
    wf.parent.mkdir(parents=True, exist_ok=True)
    wf.write_text(BASE)
    r = _run(tmp_path)
    assert r.returncode == 2, r.stdout + r.stderr
    assert "ERROR" in r.stderr


def test_scanning_no_tests_directories_at_all_is_an_error(tmp_path):
    """"Scanned nothing" and "scanned everything and found it clean" both used
    to print OK and exit 0.

    Two reviewer mutants exploited exactly that — never incrementing `checked`,
    and globbing */Test instead of */Tests. Palace/Packages/*/Tests has held
    test files continuously since 2026-05, so zero means the scan broke.
    """
    root = tmp_path
    (root / "Palace" / "Packages" / "PalaceThing" / "Sources").mkdir(parents=True)
    wf = root / WF
    wf.parent.mkdir(parents=True, exist_ok=True)
    wf.write_text(BASE)
    r = _run(root)
    assert r.returncode == 2, "a scan that saw nothing must not report OK\n" + r.stdout
    assert "NO package test targets" in r.stderr


def test_allowlisted_package_that_vanished_is_reported(tmp_path):
    """Dead debt: an allowlist entry for a package that no longer exists.

    Fail-closed rather than laundering (the scan is filesystem-driven), so this
    warns rather than failing — but it must not be silent, or the recorded
    mechanism outlives the thing it excused.
    """
    root = _tree(tmp_path, BASE + _step("PalaceAuth"), {"PalaceAuth": 1})
    r = _run(root)
    assert r.returncode == 0, r.stdout + r.stderr
    assert "PalaceKeychain" in r.stdout and "no longer exists" in r.stdout


def test_unwired_package_with_exactly_one_test_file_fails(tmp_path):
    """The boundary of the scaffolding threshold.

    `[ "$n_tests" -gt 0 ]` separates a real suite from an empty Tests directory.
    A reviewer changed it to `-gt 1` and all 19 arms stayed green: every fixture
    whose verdict depends on the count used 0, 2, 3 or 4 files, and the live
    tree's smallest package has 2. The gate then printed "OK — 0 package test
    target(s)" with a dark one-file suite sitting there. One file is a suite.
    """
    root = _tree(tmp_path, BASE, {"PalaceGhost": 1})
    r = _run(root)
    assert r.returncode == 1, "a single-file test target is still a test target\n" + r.stdout
    assert "PalaceGhost" in r.stderr


def test_live_allowlist_is_exactly_palacekeychain():
    """ADDING to this allowlist is the silent weakening, and nothing watched it.

    The ceiling gate got an exact-membership assertion; this one did not. A new
    entry here turns a package's suite dark with a one-line edit and no test
    would notice — the direction that actually loses coverage. Removal is safe
    by construction (the gate then demands real wiring), so this pins the set.
    """
    text = GATE.read_text()
    body = text.split("ALLOWLIST=(\n", 1)[1].split("\n)", 1)[0]
    names = {line.strip().lstrip('"').split("|", 1)[0]
             for line in body.splitlines() if line.strip().startswith('"')}
    assert names == {"PalaceKeychain"}, (
        f"wiring allowlist membership changed to {names}. Each entry is a package "
        "whose tests run NOWHERE; adding one needs a recorded mechanism and a line here."
    )


def test_a_missing_extractor_is_an_error_not_a_pass(tmp_path):
    """The gate shells to `workflow_effective_runs.py`; losing it must not pass.

    Flipping that guard from `exit 2` to `exit 0` left the whole suite green: the
    gate then printed its ERROR line and reported success with every package
    dark. tooling-checks.yml already guards each gate's OWN absence for exactly
    this reasoning — a check nothing can run is a check that reports a pass.
    """
    root = _tree(tmp_path, BASE + _step("PalaceGhost"), {"PalaceGhost": 2})
    import shutil
    fake_scripts = tmp_path / "scripts"
    fake_scripts.mkdir(parents=True, exist_ok=True)
    shutil.copy(GATE, fake_scripts / GATE.name)          # gate without its extractor
    r = subprocess.run(["bash", str(fake_scripts / GATE.name), str(root)],
                       capture_output=True, text=True)
    assert r.returncode == 2, (
        "a gate that cannot find its extractor must error, not pass\n" + r.stdout + r.stderr
    )
    assert "ERROR" in r.stderr


def test_live_repo_passes():
    """The real tree must be clean — and must be SEEN.

    Both gates ARE named steps in tooling-checks.yml now, so this is no longer
    the only CI enforcement — an earlier version of this docstring said it was
    and was left behind when those steps landed. What this arm still uniquely
    holds is the COUNT: a scan that silently stopped finding anything exits 0
    and prints OK, and no synthetic fixture can know the tree's true number.
    """
    repo = Path(__file__).resolve().parent.parent.parent
    env = {k: v for k, v in os.environ.items() if not k.startswith("FILE_SIZE_")}
    env.setdefault("PATH", "/usr/bin:/bin:/usr/local/bin")
    r = subprocess.run(["bash", str(GATE), str(repo)], capture_output=True, text=True,
                       env=env)
    assert r.returncode == 0, r.stdout + r.stderr
    m = re.search(r"OK — (\d+) package test target", r.stdout)
    assert m, "gate did not report a scanned count\n" + r.stdout
    assert int(m.group(1)) >= 5, (
        f"only {m.group(1)} package test target(s) seen; the tree has had at "
        "least 5 since 2026-05 — a shrinking count means the scan broke\n" + r.stdout
    )
