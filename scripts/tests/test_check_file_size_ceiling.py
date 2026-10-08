"""Tests for scripts/check-file-size-ceiling.sh.

prior-art-checked: this is a direct replacement for the deleted
test_check_godclass_loc_freeze.py, following the existing scripts/tests/
pytest convention. `harness capabilities` offers nothing for testing a repo
shell gate — its near matches are glyph tagging and SoD enforcement.

Replaces the six-file LOC freeze's tests. That gate watched six NAMED files;
this one watches every app-target Swift file against a ceiling.

Both directions are asserted throughout. A ceiling gate that cannot go red is
precisely the failure it exists to prevent — the freeze passed for nine weeks
while the 3.2.1/3.2.2/3.2.3 forward-port (PR #1348) raised four of the very
files it watched by +528 physical lines, because its escape hatch let the
baseline be raised instead of the code shrunk.
"""
import subprocess
from pathlib import Path

GATE = Path(__file__).resolve().parent.parent / "check-file-size-ceiling.sh"


# The fixture's OWN allowlist, injected via FILE_SIZE_ALLOWLIST_FILE. It used to
# be parsed out of the gate's heredoc, which coupled the test to the SUT and
# blinded it to two classes a reviewer measured: a typo'd allowlist path left 16
# of 17 arms green, and an inflated cap was invisible to fixture and live tree
# alike. Only the two live-tree arms read the gate's real allowlist, deliberately.
FIXTURE_ALLOWLIST = """\
981  Palace/Book/UI/BookDetail/BookDetailViewModel.swift
1226 Palace/MyBooks/MyBooksDownloadCenter.swift
# A SUB-CEILING pin: 371 is far under the 800 ceiling, so nothing but the pin
# itself can hold this file. Three critical-path caps have exactly this shape.
371  Palace/Accounts/Library/AccountsManager.swift
"""


def _allowlisted_paths(allowlist: str = FIXTURE_ALLOWLIST) -> list:
    out = []
    for line in allowlist.splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            out.append(line.split(None, 1)[1])
    return out


def _gate_allowlist() -> str:
    """The gate's REAL allowlist, for the arms that must assert on it."""
    text = GATE.read_text()
    return text.split("read -r -d '' ALLOWLIST <<'EOF'\n", 1)[1].split("\nEOF", 1)[0]


def _tree(root: Path, allowlist: str = FIXTURE_ALLOWLIST) -> Path:
    """A tree in which the GIVEN allowlist is valid.

    Every allowlisted path gets a one-line stub, because the gate fails on an
    entry pointing at a file that does not exist.
    """
    (root / "Palace").mkdir(parents=True, exist_ok=True)
    for rel in _allowlisted_paths(allowlist):
        f = root / rel
        f.parent.mkdir(parents=True, exist_ok=True)
        if not f.exists():
            f.write_text("let stub = 0\n")
    return root


def _swift(root: Path, rel: str, code_lines: int, comment_lines: int = 0, blanks: int = 0) -> Path:
    p = root / "Palace" / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    body = ["// leading doc"] * comment_lines + [""] * blanks + [f"let v{i} = {i}" for i in range(code_lines)]
    p.write_text("\n".join(body) + "\n")
    return p


def _run(root: Path, ceiling: str | None = "800",
         allowlist: str | None = FIXTURE_ALLOWLIST) -> subprocess.CompletedProcess:
    """ceiling=None omits FILE_SIZE_CEILING so the gate's own default applies.

    Every test here originally passed the env var, which made the default in
    `CEILING="${FILE_SIZE_CEILING:-800}"` unreachable: a reviewer changed it to
    5000 and the entire suite plus the live tree stayed green. The constant is
    the gate's actual production value, so at least one arm must not override
    it.
    """
    env = {"PATH": "/usr/bin:/bin:/usr/local/bin"}
    if ceiling is not None:
        env["FILE_SIZE_CEILING"] = ceiling
    if allowlist is not None:
        tmp = root / "_fixture_allowlist.txt"
        tmp.write_text(allowlist)
        env["FILE_SIZE_ALLOWLIST_FILE"] = str(tmp)
    return subprocess.run(
        ["bash", str(GATE), str(root)], capture_output=True, text=True, env=env
    )


def _clean_env() -> dict:
    """Environment with BOTH injection seams scrubbed.

    The live-tree arms must measure the gate's REAL ceiling and REAL allowlist.
    They used to inherit ambient env, so a shell that had exported
    FILE_SIZE_ALLOWLIST_FILE or FILE_SIZE_CEILING — which every other arm in
    this file sets — silently redirected them. A reviewer grew AccountsManager
    to 3000 code lines and got 20/20 green with those exported, red without:
    the seam added for testability had become a way to switch the gate off.
    """
    import os
    env = {k: v for k, v in os.environ.items()
           if k not in {"FILE_SIZE_ALLOWLIST_FILE", "FILE_SIZE_CEILING"}}
    env.setdefault("PATH", "/usr/bin:/bin:/usr/local/bin")
    return env


def test_comments_and_blanks_do_not_count(tmp_path):
    """Counting CODE lines is the point: a doc-comment sweep must not trip the
    gate, or authors learn to fear commenting."""
    root = _tree(tmp_path)
    _swift(root, "Documented.swift", code_lines=700, comment_lines=400, blanks=200)
    r = _run(root)
    assert r.returncode == 0, r.stdout + r.stderr


def test_block_comment_bodies_do_not_count(tmp_path):
    """Block-comment bodies are not code.

    This case was LOST in the swap from the six-file freeze and a reviewer found
    it with a surviving mutant: deleting `if (s ~ "^/?[*]") next` from the gate
    left every other test green. The other comment test only emits `//` lines,
    so it cannot see this arm.

    The banner must be big enough that counting it CROSSES the ceiling. The
    first version of this test used 502 comment lines against a 100-line file
    and was inert — 602 is under 800, so the gate returned 0 either way and the
    mutant survived the test written to kill it.
    """
    root = _tree(tmp_path)
    p = root / "Palace" / "BlockCommented.swift"
    p.parent.mkdir(parents=True, exist_ok=True)
    banner = ["/*"] + [" * explanatory prose"] * 900 + [" */"]
    p.write_text("\n".join(banner + [f"let v{i} = {i}" for i in range(100)]) + "\n")
    r = _run(root)
    assert r.returncode == 0, (
        "902 block-comment lines + 100 code lines must count as 100\n" + r.stdout + r.stderr
    )


def test_import_lines_do_not_count(tmp_path):
    """An `import` declaration is not a code line.

    This is what lets an extraction touch a capped hub at all. Moving a helper
    into an SPM package costs every consuming file exactly one import and
    nothing else, so while imports counted, a file pinned at its measured size
    could not participate in the decomposition this gate exists to serve —
    there is no upward path on the allowlist by design. Phase B1 hit this on
    four hubs at once, each landing exactly 1 over.

    801 code lines + imports must still fail, which the next arm asserts, so
    this exclusion cannot be read as "the ceiling got looser".
    """
    root = _tree(tmp_path)
    p = root / "Palace" / "ManyImports.swift"
    p.parent.mkdir(parents=True, exist_ok=True)
    imports = [
        "import Foundation",
        "import Combine",
        "@testable import Palace",
        "@preconcurrency import PalaceNetwork",
        "  import PalaceUtilities",
    ] * 20  # 100 import lines
    p.write_text("\n".join(imports + [f"let v{i} = {i}" for i in range(800)]) + "\n")
    r = _run(root)
    assert r.returncode == 0, (
        "100 import lines + 800 code lines must count as 800\n" + r.stdout + r.stderr
    )


def test_import_exclusion_does_not_raise_the_ceiling(tmp_path):
    """The companion to the arm above: imports stop counting, code does not.

    Without this, deleting the `next` for imports and deleting the whole
    counter are indistinguishable — a gate that counts nothing also passes a
    file with 100 imports. 801 real code lines must still be red no matter how
    many imports sit above them.
    """
    root = _tree(tmp_path)
    p = root / "Palace" / "ImportsPlusOverage.swift"
    p.parent.mkdir(parents=True, exist_ok=True)
    imports = ["import Foundation"] * 100
    p.write_text("\n".join(imports + [f"let v{i} = {i}" for i in range(801)]) + "\n")
    r = _run(root)
    assert r.returncode == 1, (
        "801 code lines must fail regardless of the imports above them\n"
        + r.stdout + r.stderr
    )
    assert "OVER-CEILING" in r.stderr
    assert "801 code lines" in r.stderr, (
        "the reported count must be the code lines alone, not 901\n" + r.stderr
    )


def test_package_sources_are_in_scope(tmp_path):
    """Excluding Palace/Packages/** was a laundering path, proven not argued.

    A reviewer relocated an allowlisted hub into Palace/Packages/X/Sources/ at
    1500 code lines and the gate returned 0 — the ceiling AND the recorded cap
    both evaporated with no signal. Phases B-F of this campaign are precisely
    the motion of app code into packages, so the exclusion switched the gate off
    exactly where the work happens. Package boundaries constrain
    dependency DIRECTION, which is an orthogonal axis to file size.
    """
    root = _tree(tmp_path)
    _swift(root, "Packages/PalaceThing/Sources/Big.swift", 2000)
    r = _run(root)
    assert r.returncode == 1, "package source over the ceiling must go red\n" + r.stdout
    assert "Big.swift" in r.stderr


def test_package_tests_are_out_of_scope(tmp_path):
    """Test files are long for legitimate reasons — table-driven cases, fixture
    data. The ceiling is about production hubs."""
    root = _tree(tmp_path)
    _swift(root, "Packages/PalaceThing/Tests/BigTests.swift", 2000)
    r = _run(root)
    assert r.returncode == 0, r.stdout + r.stderr
    assert "BigTests.swift" not in r.stderr


def test_stale_allowlist_entry_fails(tmp_path):
    """An allowlist entry whose file is gone must be loud, not silent.

    The scan is driven by `find`, so a cap for a path that no longer exists is
    simply never consulted. Combined with the package blind spot above, moving a
    hub out from under its entry erased both the ceiling and the cap with zero
    signal. Absence must not render as success.
    """
    root = _tree(tmp_path)
    victim = root / _allowlisted_paths()[0]
    victim.unlink()
    r = _run(root)
    assert r.returncode == 1
    assert "STALE-ALLOWLIST" in r.stderr
    assert victim.name in r.stderr


def test_valid_allowlist_reports_no_stale_entry(tmp_path):
    """The clean arm of the check above — a detector that always fires is not a
    detector. Every allowlisted path present means no STALE line at all."""
    root = _tree(tmp_path)
    r = _run(root)
    assert "STALE-ALLOWLIST" not in r.stderr, r.stderr


def test_shrunk_allowlisted_file_reports_the_new_number(tmp_path):
    """A ratchet only ratchets if shrinking is visible and tightenable."""
    root = _tree(tmp_path)
    _swift(root, "Book/UI/BookDetail/BookDetailViewModel.swift", 400)
    r = _run(root)
    assert r.returncode == 0
    assert "SHRANK" in r.stdout
    assert "981 -> 400" in r.stdout
    # Pins the exact marker `test_live_allowlist_has_zero_slack` filters stdout
    # on. Without this, rewording the advisory makes that arm match nothing and
    # pass on every tree — real slack ships green while the gate still prints it.
    # Measured by a reviewer: gate and map raised together plus a reworded
    # advisory gave 25 passed. "SHRANK" and "981 -> 400" both survive a reword,
    # so neither pins it; this is the coupling, so this is where it is held.
    assert "(ratchet this down)" in r.stdout


def test_missing_palace_dir_is_an_error_not_a_pass(tmp_path):
    """Absence must not render as success — the recurring failure in this repo."""
    r = _run(tmp_path)
    assert r.returncode == 2
    assert "ERROR" in r.stderr


def test_default_ceiling_is_800_and_800_passes(tmp_path):
    """The gate's DEFAULT ceiling, with no env override — 800 is allowed."""
    root = _tree(tmp_path)
    _swift(root, "Exactly800.swift", 800)
    r = _run(root, ceiling=None)
    assert r.returncode == 0, "800 is at the ceiling, not over it\n" + r.stdout + r.stderr


def test_default_ceiling_is_800_and_801_fails(tmp_path):
    """801 over the DEFAULT constant must go red.

    Paired with the test above this pins the constant itself: raising it to any
    other value fails one of the two. Previously every arm passed
    FILE_SIZE_CEILING explicitly, so `:-800` was asserted by nothing and a
    mutant setting it to 5000 survived the whole suite.
    """
    root = _tree(tmp_path)
    _swift(root, "Exactly801.swift", 801)
    r = _run(root, ceiling=None)
    assert r.returncode == 1, "801 must exceed the default ceiling\n" + r.stdout
    assert "Exactly801.swift" in r.stderr
    # The OVER-CEILING label lived in test_file_over_ceiling_fails, which a
    # reviewer measured as contributing zero kills beyond this arm. The label is
    # the one thing it uniquely held, so it moves here and that arm is dropped.
    assert "OVER-CEILING" in r.stderr


def test_allowlisted_file_exactly_at_cap_passes(tmp_path):
    """n == cap is the live operating point — four entries are pinned at their
    measured size — so the boundary must be asserted, not assumed."""
    root = _tree(tmp_path)
    _swift(root, "Book/UI/BookDetail/BookDetailViewModel.swift", 981)
    r = _run(root, ceiling=None)
    assert r.returncode == 0, "a file exactly at its cap is not over it\n" + r.stderr
    # The other allowlist stubs are 1 line each, so a SHRANK block is expected;
    # what must NOT appear is this file being reported as shrunk at n == cap.
    assert "BookDetailViewModel.swift: 981 ->" not in r.stdout, r.stdout


def test_allowlisted_file_one_over_cap_fails(tmp_path):
    """cap+1 must go red.

    With entries pinned AT their measured size, an off-by-one in the comparison
    hands every one of them a free line. A reviewer's mutant changing
    `-gt "$cap"` to `-gt "$((cap+1))"` survived the whole suite, because the
    only over-cap fixture was 1100 against a cap of 981.
    """
    root = _tree(tmp_path)
    _swift(root, "Book/UI/BookDetail/BookDetailViewModel.swift", 982)
    r = _run(root, ceiling=None)
    assert r.returncode == 1, "982 > 981 must fail\n" + r.stdout + r.stderr
    assert "OVER-ALLOWLIST" in r.stderr


def test_sub_ceiling_pin_is_enforced(tmp_path):
    """A pin far BELOW the ceiling must still bind.

    This is the class a reviewer found unheld: deleting `371 AccountsManager`
    from the allowlist left all 13 arms green while the file grew to 571,
    because 571 is under the 800 ceiling and no fixture knew the pin existed.
    Three critical-path caps (AccountsManager 371, TPPSignInBusinessLogic 638,
    BorrowOperation 521) have exactly this shape, and a previous review round
    is the reason they are there at all — "present but unenforced" was the
    worst of the three possible states.
    """
    root = _tree(tmp_path)
    _swift(root, "Accounts/Library/AccountsManager.swift", 372)
    r = _run(root, ceiling=None)
    assert r.returncode == 1, (
        "372 > its pin of 371 must fail even though 372 is far under the "
        "ceiling\n" + r.stdout + r.stderr
    )
    assert "OVER-ALLOWLIST" in r.stderr


def test_removing_a_sub_ceiling_pin_removes_the_only_protection(tmp_path):
    """The counterpart: with the pin gone, the same file sails.

    Asserting this explicitly is what makes the arm above meaningful — it shows
    the pin is the ONLY thing holding the file, so deleting one is a real
    regression rather than a tidy-up.
    """
    without_pin = "\n".join(
        line for line in FIXTURE_ALLOWLIST.splitlines()
        if "AccountsManager.swift" not in line
    ) + "\n"
    root = _tree(tmp_path, allowlist=without_pin)
    _swift(root, "Accounts/Library/AccountsManager.swift", 571)
    r = _run(root, ceiling=None, allowlist=without_pin)
    assert r.returncode == 0, r.stdout + r.stderr


def test_live_allowlist_pins_the_critical_paths(tmp_path):
    """The gate's REAL allowlist must still carry the critical-path caps.

    The arms above prove the MECHANISM enforces a sub-ceiling pin. Nothing else
    proves these particular pins are present, and every one of them is under
    the ceiling, so if an entry were dropped the tree would stay green while
    two CLAUDE.md critical paths (sign-in, borrow) silently regained hundreds
    of lines of headroom.

    The map pins with `==`, not `<=`. A cap can drift THREE ways, and `<=` saw
    only two of them:

      1. an entry ADDED or REMOVED    - held by the membership assert below
      2. the GATE's cap raised alone  - held by `<=` and by `==`
      3. the MAP's value raised alone - invisible to `<=`, held by `==`

    (3) is not hypothetical. The B1 rebase auto-merged this file without a
    conflict, taking the previous phase's higher numbers into the map while the
    gate kept its own lower ones. Every real cap was then BELOW its expectation,
    `<=` stayed green, and the map licensed all nine caps to climb back -
    `AccountsManager` 367 -> 372, a critical path. `<=` was the one assertion
    in this file that did not pin, and it was the one that missed.

    The cost of `==` is that ratcheting a cap DOWN now takes a one-line edit
    here in the same commit. That is the intended trade: a down-ratchet is
    already a deliberate act, and the failure message names the edit.

    What `==` does NOT catch is a TWO-SIDED edit moving gate and map together.
    No second hardcoded copy can, because both copies are what is being edited.
    `test_live_allowlist_has_zero_slack` catches that edit only when the file
    did NOT grow. If the file genuinely grew and both numbers were raised to its
    new measured size, every in-tree check agrees and the raise ships green —
    see that arm's docstring for why nothing here can close it.
    """
    body = _gate_allowlist()
    caps = {}
    for line in body.splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            cap, path = line.split(None, 1)
            caps[path] = int(cap)

    expected = {
        "Palace/Audiobooks/AudiobookSessionManager.swift": 1183,
        "Palace/MyBooks/MyBooksDownloadCenter.swift": 1172,
        "Palace/AppInfrastructure/AudiobookMorphingPlayerView.swift": 1044,
        "Palace/Book/UI/BookDetail/BookDetailViewModel.swift": 867,
        "Palace/Utilities/Localization/Strings.swift": 871,
        "Palace/Accounts/Library/AccountsManager.swift": 367,
        "Palace/SignInLogic/TPPSignInBusinessLogic.swift": 633,
        "Palace/MyBooks/BorrowOperation.swift": 514,
        "Palace/Packages/PalaceTriageBot/Sources/TriageBotCore/Reducer/"
        "ConversationReducer.swift": 847,
    }
    # All nine, not just the three critical paths. A RAISED cap on any entry is
    # the same defect as a deleted one, and for the five entries that sit ABOVE
    # the 800 ceiling nothing but this map holds them at all.
    for path, recorded in expected.items():
        assert path in caps, f"{path} lost its cap"
        assert caps[path] == recorded, (
            f"{path} cap is {caps[path]}, expected {recorded}. This map pins "
            "the gate's caps EXACTLY: a raise is the defect it exists to "
            "catch, and a genuine ratchet down edits both in the same commit."
        )
    assert set(caps) == set(expected), (
        f"allowlist membership changed: {set(caps) ^ set(expected)}. A new entry "
        "needs a line here and the phase that will retire it."
    )


def test_live_allowlist_has_zero_slack():
    """Every allowlisted cap must EQUAL its file's measured size.

    This is the only arm that measures the tree rather than comparing two
    hardcoded copies of the same numbers, so it sees a TWO-SIDED edit — gate and
    expected map raised together — in the case where the file did not grow.

    It does NOT close that channel, and an earlier version of this docstring
    said it did. A reviewer measured the survivor: add 5 real code lines to
    AccountsManager, raise gate AND map 367 -> 372, and the file now measures
    exactly its new cap. No slack, no advisory, `==` satisfied, gate exit 0, all
    arms green. That is the accretion-plus-justified-raise shape this gate's own
    header cites from PR #1348, and it is the shape the freeze died of.

    Nothing inside the tree can catch it, because every in-tree record of the
    old value is editable in the same commit. Closing it needs the caps compared
    against the BASE branch's committed copy (`git show
    origin/develop:scripts/check-file-size-ceiling.sh`), which the PR cannot
    rewrite. That is not done here — it turns on whether origin/develop is
    reliably fetched in CI and on a local run, and a ratchet that silently skips
    when the ref is missing is worse than none.

    It reads the gate's own SHRANK advisory instead of re-implementing
    `loc_of`. A re-implementation drifts from the counter it is meant to check,
    and the arm directly below this one exists because those counting rules are
    exactly what changes.

    The advisory is printed today and feeds nothing: it does not touch the exit
    code, so slack on the live tree is invisible to the entire suite. Asserting
    it empty turns the printed suggestion into the ratchet the allowlist
    already claims to be.
    """
    repo = Path(__file__).resolve().parent.parent.parent
    r = subprocess.run(["bash", str(GATE), str(repo)], capture_output=True, text=True,
                       env=_clean_env())
    assert r.returncode == 0, r.stdout + r.stderr
    slack = [ln.strip() for ln in r.stdout.splitlines() if "(ratchet this down)" in ln]
    assert not slack, (
        "allowlisted files are smaller than their caps. Lower each cap to the "
        "measured size in BOTH check-file-size-ceiling.sh and the expected map "
        "above:\n  " + "\n  ".join(slack)
    )


def test_every_skip_in_loc_of_is_ANCHORED(tmp_path):
    """All three skips in `loc_of` are anchored, and all three anchors bind.

    `loc_of` skips a line that IS a comment, a block-comment body, or an import.
    Each rule is anchored with `^` after whitespace-stripping, so it matches the
    line's start rather than anywhere in it. Drop any one anchor and the rule
    becomes "skip any line CONTAINING this", which silently manufactures slack
    on files pinned at exactly their cap.

    All three were measured reachable on the live tree, and the loosening is not
    theoretical:

        ^//        4 at-cap hubs lose lines (AudiobookSessionManager,
                   AccountsManager, BookDetailViewModel, MyBooksDownloadCenter)
        ^/?[*]     5 hubs, including BorrowOperation
        ^import    2 hubs — `NSLog("Cannot import ADEPT")` in
                   MyBooksDownloadCenter and a localized string in Strings.swift

    Three of those files are CLAUDE.md critical paths. `shrunk` is advisory and
    is not counted into `total`, so `test_live_repo_passes` cannot see any of it.

    This arm covers all three rather than one each, because the previous version
    pinned ONLY the import anchor while its two siblings five lines away stayed
    unheld — the exact shape recorded in
    `.forgeos/wall-failures/2026-09-27-corrected-claim-survives-its-siblings.md`,
    committed in the change that was hardening this very function. A fourth skip
    added later has one obvious place to be pinned.
    """
    # Each payload is CODE whose text contains the skipped token away from the
    # line's start, so only the anchor keeps it counted.
    payloads = [
        ("slash", "^//     (a URL literal)",    'let u = "https://example.com"'),
        ("star",  "^/?[*]  (a multiplication)", "let area = w * h"),
        ("imp",   "^import (a logged string)",  'NSLog("Cannot import ADEPT")'),
    ]
    for key, label, line in payloads:
        root = _tree(tmp_path / key)
        p = root / "Palace" / "Anchored.swift"
        p.parent.mkdir(parents=True, exist_ok=True)
        body = [f"let v{i} = {i}" for i in range(800)] + [line]
        p.write_text("\n".join(body) + "\n")
        r = _run(root, ceiling=None)
        assert r.returncode == 1, (
            f"{label}: 801 code lines must exceed the default ceiling — the "
            f"anchor stopped binding\n" + r.stdout + r.stderr
        )
        assert "801 code lines" in r.stderr, (
            f"{label}: counted {r.stderr.strip()[:120]!r}, expected 801 — the "
            "payload line was skipped\n"
        )


def test_live_repo_passes():
    """The real tree must be clean, or the gate lands already-red and gets
    switched off within a week.

    Both gates ARE named steps in tooling-checks.yml, so this is not the only
    CI enforcement. What it still uniquely holds is an allowlist entry pointing
    at a path that does not exist, since the fixtures inject their own allowlist
    and only this arm reads the real one.

    (An earlier version asserted the opposite and a correction was APPENDED
    below it, leaving both claims in one docstring with the wrong one first.
    Correcting by appending is its own failure mode — replace the text.)
    """
    repo = Path(__file__).resolve().parent.parent.parent
    r = subprocess.run(["bash", str(GATE), str(repo)], capture_output=True, text=True,
                       env=_clean_env())
    assert r.returncode == 0, r.stdout + r.stderr


def test_duplicate_allowlist_path_is_rejected(tmp_path):
    """A duplicate entry with a raised cap ABOVE the real one silently wins.

    Measured by a reviewer: `allowed_max()` is first-match-wins while the
    live-allowlist test's parser is last-match-wins, so the two disagreed and
    AccountsManager went 371 -> 621 with the gate at exit 0 and every arm green.
    Rejecting duplicates makes the two readings agree by construction instead of
    by both happening to pick the same line.
    """
    dupe = ("621  Palace/Accounts/Library/AccountsManager.swift\n"
            "371  Palace/Accounts/Library/AccountsManager.swift\n")
    root = _tree(tmp_path, allowlist=dupe)
    r = _run(root, ceiling=None, allowlist=dupe)
    assert r.returncode == 1, r.stdout + r.stderr
    assert "DUPLICATE-ALLOWLIST" in r.stderr


def test_non_numeric_cap_is_rejected(tmp_path):
    """A cap that is not a number compares as garbage rather than failing."""
    bad = "abc  Palace/Accounts/Library/AccountsManager.swift\n"
    root = _tree(tmp_path, allowlist=bad)
    r = _run(root, ceiling=None, allowlist=bad)
    assert r.returncode == 1, r.stdout + r.stderr
    assert "MALFORMED-ALLOWLIST" in r.stderr


def test_cap_with_no_path_is_rejected(tmp_path):
    root = _tree(tmp_path, allowlist="")
    r = _run(root, ceiling=None, allowlist="420\n")
    assert r.returncode == 1, r.stdout + r.stderr
    assert "MALFORMED-ALLOWLIST" in r.stderr


def test_missing_allowlist_file_is_an_error_not_a_pass(tmp_path):
    """The seam's own absence path.

    An injected allowlist that does not exist must not fall back to the
    built-in one, or the seam becomes a way to run the gate with no allowlist
    semantics at all while it still prints OK.
    """
    root = _tree(tmp_path)
    r = subprocess.run(
        ["bash", str(GATE), str(root)], capture_output=True, text=True,
        env={"PATH": "/usr/bin:/bin:/usr/local/bin",
             "FILE_SIZE_ALLOWLIST_FILE": str(tmp_path / "nope.txt")},
    )
    assert r.returncode == 2, r.stdout + r.stderr
    assert "ERROR" in r.stderr


def test_live_arm_ignores_an_exported_seam(monkeypatch, tmp_path):
    """The seam must not be able to switch the live-tree check off.

    A reviewer grew AccountsManager to 3000 code lines and got 20/20 green with
    FILE_SIZE_ALLOWLIST_FILE and FILE_SIZE_CEILING exported, red without: the
    live arm inherited ambient env, so the mechanism added for testability had
    become a way to disable the gate. This asserts the scrub directly — with
    both vars exported to permissive values, the live arm must still measure
    the gate's real ceiling and real allowlist.
    """
    permissive = tmp_path / "permissive.txt"
    permissive.write_text("999999 Palace/Nothing.swift\n")
    monkeypatch.setenv("FILE_SIZE_ALLOWLIST_FILE", str(permissive))
    monkeypatch.setenv("FILE_SIZE_CEILING", "999999")

    env = _clean_env()
    assert "FILE_SIZE_ALLOWLIST_FILE" not in env
    assert "FILE_SIZE_CEILING" not in env

    repo = Path(__file__).resolve().parent.parent.parent
    r = subprocess.run(["bash", str(GATE), str(repo)], capture_output=True, text=True,
                       env=env)
    assert r.returncode == 0, r.stdout + r.stderr
    # Proof the scrub actually mattered: the permissive allowlist names one file
    # that does not exist, so had it been honoured the gate would have reported
    # STALE-ALLOWLIST for it.
    assert "Palace/Nothing.swift" not in r.stderr
    assert "no app-target file over 800" in r.stdout


# FOUR ARMS REMOVED 2026-09-27, measured not guessed.
#
# A reviewer ran seven predicate mutants (the default 800, cap off-by-one,
# -gt -> -ge, shrink -lt -> -le, ceiling off-by-one, total -gt 0) against this
# suite and against this suite minus the four below: identical kill results, all
# seven, both ways. They were the looser predecessors of boundary arms added
# later, kept alongside them instead of replaced by them.
#
#   test_small_files_pass                   (50)   -> ..._800_passes
#   test_file_over_ceiling_fails            (900)  -> ..._801_fails
#                                                     (its OVER-CEILING assertion moved there)
#   test_allowlisted_file_under_cap_passes  (900)  -> ..._exactly_at_cap_passes
#   test_allowlisted_file_over_cap_fails    (1100) -> ..._one_over_cap_fails
#
# The last one's own docstring conceded that its 1100-vs-981 fixture let the
# off-by-one live. Adding a boundary arm beside the arm it supersedes is how a
# suite grows without gaining signal.
