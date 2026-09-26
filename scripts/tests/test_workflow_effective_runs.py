"""Tests for scripts/workflow_effective_runs.py.

prior-art-checked: follows the scripts/tests/ pytest convention. This module was
extracted from check-package-tests-wired.sh when a reviewer showed a grep over
workflow text could be satisfied by a step that cannot fail the build.

The module answers one question — "which `run:` bodies can actually fail this
build" — and the two defaults point deliberately opposite ways. Both directions
are asserted here, because getting either backwards is a silent hole.
"""
import subprocess
import sys
from pathlib import Path

MOD = Path(__file__).resolve().parent.parent / "workflow_effective_runs.py"
sys.path.insert(0, str(MOD.parent))
from workflow_effective_runs import effective_runs  # noqa: E402

BASE = "name: w\non: push\njobs:\n  test:\n    steps:\n"


def _step(body: str, **keys) -> str:
    out = "      - name: a step\n"
    for k, v in keys.items():
        out += f"        {k.replace('_', '-')}: {v}\n"
    return out + f"        run: {body}\n"


def test_plain_step_is_effective():
    assert effective_runs(BASE + _step("swift test --package-path P")) == [
        "swift test --package-path P"
    ]


def test_continue_on_error_true_is_dropped():
    """It runs and cannot redden the board, so it is not enforcement."""
    assert effective_runs(BASE + _step("make x", continue_on_error="true")) == []


def test_continue_on_error_false_is_kept():
    assert effective_runs(BASE + _step("make x", continue_on_error="false")) == ["make x"]


def test_continue_on_error_expression_is_dropped():
    """The UNSAFE direction here is the opposite of `if:`.

    A reviewer measured `continue-on-error: ${{ ... }}` reading as wired. An
    expression that evaluates true means the step cannot fail the build, so
    treating it as enforcement is exactly the false-green claim this gate
    exists to prevent. False red is survivable; false green is the defect.
    """
    assert effective_runs(BASE + _step("make x", continue_on_error="${{ github.event_name == 'push' }}")) == []


def test_if_false_is_dropped():
    assert effective_runs(BASE + _step("make x", **{"if": "false"})) == []


def test_if_expression_is_kept():
    """The opposite default, and equally deliberate.

    Guessing that a `${{ }}` condition is false would silently drop real
    coverage and redden a correctly wired tree — which is how a gate gets
    switched off by the people it is meant to help.
    """
    assert effective_runs(BASE + _step("make x", **{"if": "${{ !cancelled() }}"})) == ["make x"]


def test_block_scalar_run_is_captured_in_full():
    wf = BASE + (
        "      - name: multi\n"
        "        run: |\n"
        "          set -e\n"
        "          swift test --package-path P\n"
    )
    assert effective_runs(wf) == ["set -e", "swift test --package-path P"]


def test_step_without_run_contributes_nothing():
    assert effective_runs(BASE + "      - uses: actions/checkout@v4\n") == []


def test_later_step_is_not_swallowed_by_an_earlier_block_scalar():
    """Block-scalar termination: if the parser ran past the end of a `run: |`
    it would attribute the next step's body to the first, and a dropped step
    would take its wiring with it."""
    wf = BASE + (
        "      - name: one\n        run: |\n          echo one\n"
        "      - name: two\n        run: swift test --package-path P\n"
    )
    assert effective_runs(wf) == ["echo one", "swift test --package-path P"]


def test_ineffective_step_does_not_hide_the_next_one():
    wf = BASE + _step("dead", continue_on_error="true") + _step("swift test --package-path P")
    assert effective_runs(wf) == ["swift test --package-path P"]


def test_trailing_comment_on_a_key_does_not_defeat_the_literal_check():
    wf = BASE + _step("make x", continue_on_error="false  # deliberately blocking")
    assert effective_runs(wf) == ["make x"]


def test_job_level_continue_on_error_drops_every_step():
    """Silencing the JOB is the same move as silencing the step, one scope up.

    The extractor read step-level keys only, so `jobs.<id>.continue-on-error:
    true` still yielded its run bodies as enforcement. This repo already uses
    job-level `continue-on-error: true` once and job-level `if:` eight times.
    """
    wf = ("name: w\non: push\njobs:\n  test:\n    continue-on-error: true\n"
          "    steps:\n      - name: a\n        run: swift test --package-path P\n")
    assert effective_runs(wf) == []


def test_job_level_if_false_drops_every_step():
    wf = ("name: w\non: push\njobs:\n  test:\n    if: false\n"
          "    steps:\n      - name: a\n        run: swift test --package-path P\n")
    assert effective_runs(wf) == []


def test_job_level_if_expression_is_kept():
    """Same asymmetry as at step level, carried up unchanged: an expression
    condition stays effective, because guessing it false drops real coverage."""
    wf = ("name: w\non: push\njobs:\n  test:\n    if: ${{ github.event_name == 'push' }}\n"
          "    steps:\n      - name: a\n        run: swift test --package-path P\n")
    assert effective_runs(wf) == ["swift test --package-path P"]


def test_a_dead_job_does_not_silence_a_live_sibling():
    """Span arithmetic: the dead job's range must end where the next job starts."""
    wf = ("name: w\non: push\njobs:\n"
          "  dead:\n    if: false\n    steps:\n      - run: echo nope\n"
          "  live:\n    steps:\n      - run: swift test --package-path P\n")
    assert effective_runs(wf) == ["swift test --package-path P"]


def test_job_level_continue_on_error_after_steps_still_counts():
    """YAML key order is free, and the scan must not assume otherwise.

    An earlier version stopped reading job-level keys at `steps:`, on the
    reasoning that they "precede steps in practice". Moving one line below
    `steps:` reopened the exact false-green the job-scope pass exists to close.
    """
    wf = ("name: w\non: push\njobs:\n  test:\n    steps:\n"
          "      - name: a\n        run: swift test --package-path P\n"
          "    continue-on-error: true\n")
    assert effective_runs(wf) == []


def test_job_level_if_false_after_steps_still_counts():
    wf = ("name: w\non: push\njobs:\n  test:\n    steps:\n"
          "      - name: a\n        run: swift test --package-path P\n"
          "    if: false\n")
    assert effective_runs(wf) == []


def test_a_column_zero_comment_does_not_truncate_a_dead_jobs_SPAN():
    """The span-end half of the comment problem, and only that half.

    An earlier title claimed the general property ("a comment at column 0 has
    no structure"), which the code did not honour: there are THREE boundary
    decisions in the module and this arm exercises one. The other two have
    their own arms below. Naming the half it proves is the point — a reviewer
    found the general claim standing over a fixture that could not support it.
    """
    wf = ("name: w\non: push\njobs:\n  dead:\n    if: false\n    steps:\n"
          "      - run: echo one\n"
          "# a column-zero comment, mid-job\n"
          "      - run: swift test --package-path P\n")
    assert effective_runs(wf) == []


def test_comment_trailing_a_job_id_does_not_hide_its_job_keys():
    """The comment skip had landed in only ONE of the two loops walking a job.

    `_ineffective_job_spans` skipped comments; `_job_is_ineffective` did not,
    and a comment has indentation — so a comment at or left of the job's indent
    ended the key scan and a job-level `continue-on-error: true` below it was
    never seen. A trailing comment on the job id defeats it a second way: the
    key's VALUE is then non-empty, so the line is not recognised as a job start
    at all. Both routes produce a false green in the gate whose own docstring
    says false green is the defect.
    """
    wf = ("name: w\non: push\njobs:\n  test: # the package test job\n"
          "    continue-on-error: true\n    steps:\n"
          "      - run: swift test --package-path P\n")
    assert effective_runs(wf) == []


def test_quoted_job_id_is_still_a_job():
    """`"test":` is legal YAML and used to slip every job-level key through."""
    wf = ('name: w\non: push\njobs:\n  "test":\n    continue-on-error: true\n'
          '    steps:\n      - run: swift test --package-path P\n')
    assert effective_runs(wf) == []


def test_four_space_indented_workflow_is_handled():
    """Job depth is derived, not assumed to be two spaces."""
    wf = ("name: w\non: push\njobs:\n    test:\n        continue-on-error: true\n"
          "        steps:\n          - run: swift test --package-path P\n")
    assert effective_runs(wf) == []


def test_a_dead_job_followed_by_TWO_live_jobs_drops_only_the_dead_one():
    """Span termination, with more than one follower.

    Every job fixture was dead-first with a single follower, so a mutant
    turning the span `break` into `continue` survived — it only misbehaves once
    a second live job exists, where it swallows the first.
    """
    wf = ("name: w\non: push\njobs:\n"
          "  dead:\n    if: false\n    steps:\n      - run: echo x\n"
          "  live1:\n    steps:\n      - run: swift test --package-path A\n"
          "  live2:\n    steps:\n      - run: swift test --package-path B\n")
    assert effective_runs(wf) == ["swift test --package-path A",
                                  "swift test --package-path B"]


def test_a_live_job_BEFORE_a_dead_one_survives():
    """Ordering, the other way round.

    No fixture put a live job first, so a mutant loosening the job-scan bound
    survived — with that order the live job's run vanishes instead.
    """
    wf = ("name: w\non: push\njobs:\n"
          "  live:\n    steps:\n      - run: swift test --package-path A\n"
          "  dead:\n    if: false\n    steps:\n      - run: echo x\n")
    assert effective_runs(wf) == ["swift test --package-path A"]


def test_a_banner_comment_above_a_job_does_not_disable_job_scope():
    """The `in_jobs` tracker — the THIRD boundary decision, unpatched for two rounds.

    It treated any column-0 line as leaving the `jobs:` mapping, comments
    included, so a `# ----` banner switched job-scope detection off for every
    job after it. A reviewer measured it end-to-end through the gate: with the
    banner, a `continue-on-error: true` job's steps were reported as
    enforcement (exit 0, "ok"); with the banner deleted and the file otherwise
    identical, UNWIRED. That banner shape is this repo's own (ledger.yml:712),
    and the blast radius is larger than the span bug — every subsequent job,
    not one.
    """
    wf = ("name: w\non: push\njobs:\n"
          "# ----------------------------------------\n"
          "  test:\n    continue-on-error: true\n    steps:\n"
          "      - run: swift test --package-path P\n")
    assert effective_runs(wf) == []


def test_a_banner_comment_does_not_swallow_a_LIVE_job():
    """The other direction: skipping comments must not lose real coverage."""
    wf = ("name: w\non: push\njobs:\n"
          "# ----------------------------------------\n"
          "  live:\n    steps:\n      - run: swift test --package-path P\n")
    assert effective_runs(wf) == ["swift test --package-path P"]


def test_a_standalone_comment_between_a_job_id_and_its_keys():
    """The `_job_is_ineffective` comment skip, which nothing held.

    Round four added that skip and a reviewer showed 28/28 arms stayed green
    with it deleted: the existing fixture used a comment TRAILING the job id,
    which `_strip_comment` handles in a different function entirely. A
    standalone comment on its own line is the route the skip actually exists
    for, at column 0 and at the job's own indent.
    """
    for comment_indent in ("", "  "):
        wf = ("name: w\non: push\njobs:\n  test:\n"
              f"{comment_indent}# a note about this job\n"
              "    continue-on-error: true\n    steps:\n"
              "      - run: swift test --package-path P\n")
        assert effective_runs(wf) == [], f"leaked with comment at indent {len(comment_indent)}"


def test_blank_lines_do_not_end_any_boundary_scan():
    """`_skippable`'s BLANK half, which nothing held until a reviewer mutated it.

    The predicate is `not stripped or stripped.startswith("#")`. Every arm
    written for it exercised the comment half; changing it to
    `stripped.startswith("#")` left the suite 31/31 green while producing a
    false green in all four shapes below. The code was always correct — the
    coverage was not, and a blank line is a far commoner construct in YAML than
    the `# ----` banner that motivated the comment half.

    It matters more after the hoist than before it. One line is now the single
    definition behind all three boundary decisions, so a later "simplify, the
    indent check already handles blanks" edit would ship three false greens at
    once with a green board.
    """
    shapes = {
        "blank between a job id and its continue-on-error":
            "name: w\non: push\njobs:\n  test:\n\n"
            "    continue-on-error: true\n    steps:\n"
            "      - run: swift test --package-path P\n",
        "blank between a job id and its if:false":
            "name: w\non: push\njobs:\n  test:\n\n"
            "    if: false\n    steps:\n"
            "      - run: swift test --package-path P\n",
        "blank inside a dead job's span":
            "name: w\non: push\njobs:\n  dead:\n    if: false\n    steps:\n"
            "      - run: echo x\n\n      - run: swift test --package-path P\n",
        "blank between jobs: and the first job":
            "name: w\non: push\njobs:\n\n  test:\n"
            "    continue-on-error: true\n    steps:\n"
            "      - run: swift test --package-path P\n",
    }
    for label, wf in shapes.items():
        assert effective_runs(wf) == [], f"blank line leaked enforcement: {label}"


def test_a_blank_line_does_not_swallow_a_LIVE_job():
    """The other direction, so skipping blanks cannot lose real coverage."""
    wf = ("name: w\non: push\njobs:\n\n  live:\n    steps:\n\n"
          "      - run: swift test --package-path P\n")
    assert effective_runs(wf) == ["swift test --package-path P"]


def test_the_gates_own_workflow_yields_its_exact_run_count():
    """Pins the extractor against the one file the gate actually reads.

    A reviewer generated 254 mutants and found 13 that change this file's
    effective-run count while all 76 arms stayed green — clustered in
    `_step_blocks` and the run-body accumulation, the step-level half nothing
    was measuring. One arm pinning the exact count kills 13 of the 14.

    This is the THIRD form of a guard whose first two were inert: an aggregate
    (sum > 500, max > 100) that one large workflow satisfied alone, and a
    per-all-16 version whose "legitimately zero" heuristic excused
    unit-testing.yml itself. Per-file against the gate's own input is the form
    that is red-capable, which is why it is here after the other two were
    deleted rather than alongside them.

    When this number legitimately changes — a step added or removed — update it
    deliberately and say so in the commit. That is the cost of the arm, and it
    is the point: a silent change to what the gate can see is exactly what the
    other two forms failed to catch.
    """
    from pathlib import Path
    wf = Path(__file__).resolve().parent.parent.parent / ".github" / "workflows" / "unit-testing.yml"
    runs = effective_runs(wf.read_text())
    assert len(runs) == 120, (
        f"unit-testing.yml now yields {len(runs)} effective run lines, expected 120. "
        "If a step was added or removed this is correct — update the number. "
        "If nothing changed in the workflow, the extractor's view of it did."
    )


def test_malformed_yaml_is_NOT_detected_and_that_is_documented():
    """The honest negative. This module cannot fail closed on malformed input.

    A reviewer measured it: a file PyYAML rejects still yields its run bodies
    here, because a line-regex scanner has no parse step to fail. An earlier
    docstring claimed fail-closed, which was inverted. The compensating control
    is GitHub's own parser — a workflow it cannot parse never runs, so this
    gate's answer about a malformed file decides nothing.

    Pinning the real behaviour stops someone "fixing" it into a false claim.
    """
    wf = ('name: w\non: push\njobs:\n  test:\n    steps:\n'
          '      - name: "unterminated\n        run: swift test --package-path P\n')
    assert effective_runs(wf) == ["swift test --package-path P"]


def test_cli_rejects_a_file_with_no_steps(tmp_path):
    f = tmp_path / "w.yml"
    f.write_text("name: nothing\non: push\n")
    r = subprocess.run([sys.executable, str(MOD), str(f)], capture_output=True, text=True)
    assert r.returncode == 2
    assert "ERROR" in r.stderr


def test_cli_rejects_a_missing_file(tmp_path):
    r = subprocess.run([sys.executable, str(MOD), str(tmp_path / "nope.yml")],
                       capture_output=True, text=True)
    assert r.returncode == 2


def test_runs_without_pyyaml():
    """The whole reason this module exists rather than importing yaml.

    /usr/bin/python3 has no PyYAML, so the first version of this check exited 2
    on any restricted-PATH run — a git hook, a fresh checkout, a contributor who
    never pip-installed. CLAUDE.md requires verify-pr.sh to run unaided.
    """
    probe = (
        "import sys; sys.modules['yaml'] = None; sys.path.insert(0, %r);"
        "import workflow_effective_runs as m;"
        "print(m.effective_runs('jobs:\\n t:\\n  steps:\\n   - run: swift test --package-path P\\n'))"
        % str(MOD.parent)
    )
    r = subprocess.run(["/usr/bin/python3", "-c", probe], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    assert "swift test --package-path P" in r.stdout


def test_live_workflow_yields_the_expected_package_steps():
    """Against the real file, because a synthetic fixture cannot catch a parser
    that silently stops matching this repo's actual indentation style.

    This arm and `test_ineffective_step_does_not_hide_the_next_one` are what
    hold the over-reach class: widening job detection to `indent > jobs_indent`
    collapsed unit-testing.yml to zero effective runs, and both of these go red
    on it. A third arm was written to generalise that guard across all 16
    workflows and is deliberately NOT here — it asserted aggregates (sum > 500,
    max > 100) that one large workflow satisfied on its own while three others
    went dark, and the per-file rewrite then excused unit-testing.yml because
    the heuristic distinguishing a dead JOB from 12 ineffective STEPS counted
    both. Two inert versions of a redundant guard is a worse trade than naming
    the two arms that already work.
    """
    wf = MOD.parent.parent / ".github" / "workflows" / "unit-testing.yml"
    runs = "\n".join(effective_runs(wf.read_text()))
    for pkg in ["PalaceAuth", "PalaceLogging", "PalaceReadingPosition", "PalaceTriageBot"]:
        assert f"--package-path Palace/Packages/{pkg}" in runs, f"{pkg} step not seen"
