#!/usr/bin/env python3
"""
Every bash test under scripts/tests/ must be invoked by a CI workflow.

WHY THIS EXISTS. `test_ratchet_aggregation_behaviour.sh` shipped invoked by
NOTHING. It is the check two reviewers between them walked through seven ways
when it asserted by grepping source text, and its replacement — the one that
catches all seven — ran zero times. Its only mention anywhere in the repo was a
COMMENT in a sibling test, which is a mention and not a call.

That is the same defect as the three decomposition ratchets that shipped with
baselines and passing unit tests while nothing invoked them, and it happened
inside the branch that exists to remove exactly this. Pytest collects `*.py`
under this directory automatically, so a Python test cannot be orphaned this
way; a bash test has to be named in a workflow by hand, and hands forget.

This is the check that cannot be forgotten, because it enumerates the directory
rather than a list someone maintains.
"""

import os
import re
import subprocess

import pytest
import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
WORKFLOW_DIR = os.path.join(REPO, ".github", "workflows")


def bash_tests() -> list[str]:
    out = subprocess.run(
        ["git", "-C", REPO, "ls-files", "scripts/tests/*.sh"],
        capture_output=True, text=True, check=True,
    ).stdout.split("\n")
    return [f for f in out if f]


def run_steps():
    """(workflow, job, step) for every step that has a `run:` script.

    Parsed as YAML rather than scanned as text. The first version of this file
    located the filename and then read a +-700 character window, which reached
    into the NEIGHBOURING step and borrowed its `::error::`/`exit 1` — so a
    genuinely fail-open gate passed. Three reviewers found the same thing; it is
    `assertions-match-things-adjacent-to-their-claim`, committed inside the gate
    written to prevent that class. A step is the unit; nothing outside it counts.
    """
    steps = []
    for name in sorted(os.listdir(WORKFLOW_DIR)):
        if not name.endswith((".yml", ".yaml")):
            continue
        with open(os.path.join(WORKFLOW_DIR, name), encoding="utf-8") as fh:
            doc = yaml.safe_load(fh)
        for job_name, job in (doc.get("jobs") or {}).items():
            for step in (job.get("steps") or []):
                if isinstance(step, dict) and "run" in step:
                    steps.append((name, job_name, step))
    return steps


# Every spelling of "skip if the file is absent".
#
# This has been widened twice by review. Recognising only `if [ -f` left
# `[[ -f ]]` and `test -f` open; then a bare `[ -f x ] && bash x || echo skip`
# (no `if`, no `test`) and the `-x` / `-s` / `-r` predicates were all still
# working bypasses. Match the TEST itself wherever it appears, not the statement
# that happens to introduce it.
_GUARD_RE = re.compile(r"(?:\[\[?|\btest\b)\s+!?\s*-[fedxsr]\s")

# A line that RUNS the script, as opposed to one that merely contains its name.
# `echo "…bash scripts/tests/X.sh…"` counted as an invocation until review; a
# comment was already excluded, but prose in an echo was not.
_INVOKE_RE_TMPL = r"(?:^|[;&|]|\bthen\b|\bdo\b|&&|\|\|)\s*(?:bash|sh|source|\./)\s*\S*{}"


def _invokes(step, basename: str) -> bool:
    """Does this step's script actually RUN `basename`?"""
    for line in step["run"].split("\n"):
        stripped = line.strip()
        if basename not in stripped or stripped.startswith("#"):
            continue
        if stripped.lstrip().startswith(("echo ", "printf ")):
            continue
        if re.search(_INVOKE_RE_TMPL.format(re.escape(basename)), stripped):
            return True
    return False


def invoking_steps(basename: str) -> list:
    """Steps whose script RUNS the file. A comment naming it does not count —
    that is how the ratchet-aggregation harness hid while invoked by nothing."""
    out = []
    for wf, job, step in run_steps():
        for line in step["run"].split("\n"):
            stripped = line.strip()
            if basename not in stripped or stripped.startswith("#"):
                continue
            if stripped.lstrip().startswith(("echo ", "printf ")):
                continue        # prose that names the file is not a call
            if re.search(_INVOKE_RE_TMPL.format(re.escape(basename)), stripped):
                out.append((wf, job, step))
                break
    return out


def fail_open_reasons(step) -> list:
    """Ways this step can silently not run the test it names.

    LIMIT, stated rather than implied: this models the guards that have actually
    been used to disable a gate here — a file-existence test with no failing
    arm, `if: false`, and `continue-on-error`. It does NOT model every way a
    step can swallow a failure (`|| true`, `set +e`, piping into another
    command). Those are real and are not covered; a reviewer enumerated them.
    Widening further starts approximating a shell interpreter, and the honest
    boundary is worth more than the appearance of completeness.
    """
    reasons = []
    if str(step.get("continue-on-error", "")).strip().lower() in ("true", "${{ true }}"):
        reasons.append("`continue-on-error: true` — the step cannot fail the job")
    cond = step.get("if")
    if cond is not None and str(cond).strip().lower() in ("false", "${{ false }}"):
        reasons.append(f"step `if:` is {cond!r}, so it never runs")
    script = step["run"]
    if _GUARD_RE.search(script) and "exit 1" not in script and "::error::" not in script:
        reasons.append("guarded by a file-existence test that does not fail")
    return reasons


@pytest.mark.parametrize("path", bash_tests())
def test_bash_test_is_invoked_by_a_workflow(path):
    basename = os.path.basename(path)
    assert invoking_steps(basename), (
        f"{path} is not invoked by any workflow — it runs zero times.\n"
        f"A test nothing calls is indistinguishable from a test that always passes."
    )


@pytest.mark.parametrize("path", bash_tests())
def test_bash_test_invocation_fails_closed(path):
    """A TRACKED file's absence means the gate was deleted, not that it is
    optional. Skipping turns a removed test into a green check."""
    basename = os.path.basename(path)
    problems = []
    for wf, job, step in invoking_steps(basename):
        for reason in fail_open_reasons(step):
            problems.append(f"{wf}:{job}:{step.get('name', '<unnamed>')} — {reason}")
    assert not problems, f"{path} can silently not run:\n  " + "\n  ".join(problems)


# --- Negative controls -----------------------------------------------------
#
# The enumeration above had a control; the fail-closed predicate did NOT, which
# is exactly why it shipped passing a fail-open gate. These drive the predicate
# against synthetic steps so a future weakening of it fails here rather than in
# production.

@pytest.mark.parametrize("script", [
    'if [ -f x.sh ]; then\n  bash x.sh\nelse\n  echo "skipping"\nfi\n',
    'if [[ -f x.sh ]]; then\n  bash x.sh\nelse\n  echo "skipping"\nfi\n',
    'test -f x.sh && bash x.sh || echo "skipping"\n',
    # Bare `[` with no `if` and no `test` — reviewer-measured bypass.
    '[ -f x.sh ] && bash x.sh || echo "skipping"\n',
    '[[ -f x.sh ]] && bash x.sh || echo "skipping"\n',
    # Predicates other than -f. All mean the same thing here.
    'if [ -x x.sh ]; then\n  bash x.sh\nelse\n  echo "skip"\nfi\n',
    'if [ -s x.sh ]; then\n  bash x.sh\nelse\n  echo "skip"\nfi\n',
    'if [ -r x.sh ]; then\n  bash x.sh\nelse\n  echo "skip"\nfi\n',
])
def test_predicate_catches_every_fail_open_guard_spelling(script):
    assert fail_open_reasons({"run": script}), (
        "a fail-open guard was not recognised — this spelling is a working bypass"
    )


def test_predicate_catches_continue_on_error():
    """Already used in five of this repo's workflows, so it is not hypothetical."""
    assert fail_open_reasons({"continue-on-error": True, "run": "bash x.sh\n"}), (
        "`continue-on-error: true` was not recognised — the step cannot fail the job"
    )


def test_predicate_catches_a_step_disabled_at_the_yaml_level():
    assert fail_open_reasons({"if": False, "run": "bash x.sh\n"}), (
        "`if: false` on the step was not recognised — the step never runs"
    )


@pytest.mark.parametrize("step", [
    {"run": 'if [ ! -f x.sh ]; then\n  echo "::error::gone"\n  exit 1\nfi\nbash x.sh\n'},
    {"run": "bash x.sh\n"},
    {"if": "github.event_name == 'pull_request'", "run": "bash x.sh\n"},
])
def test_predicate_accepts_genuinely_fail_closed_steps(step):
    assert not fail_open_reasons(step), (
        "a correct step was flagged — a predicate that false-positives gets disabled"
    )


def test_a_name_mentioned_in_prose_is_not_an_invocation():
    """`echo "…bash scripts/tests/X.sh…"` counted as a call until review.

    The docstring claimed a mention is not a call; that held for `#` comments
    and not for an echo, which is the same class as a detector satisfied by an
    incidental mention of the thing it looks for.
    """
    step = {"run": 'echo "run bash scripts/tests/x.sh yourself"\n'}
    assert not _invokes(step, "x.sh"), "prose naming the file counted as a call"


def test_a_real_call_is_still_recognised():
    """Control for the above — over-tightening makes every test look orphaned."""
    for script in ("bash scripts/tests/x.sh\n",
                   "  bash scripts/tests/x.sh\n",
                   "if true; then\n  bash scripts/tests/x.sh\nfi\n",
                   "./scripts/tests/x.sh\n"):
        assert _invokes({"run": script}, "x.sh"), f"real call not recognised: {script!r}"


def test_there_is_at_least_one_bash_test():
    """Control. If the glob silently returned nothing, every parametrised test
    above would vacuously pass and this file would assert precisely nothing —
    the failure mode it exists to catch, in itself."""
    assert len(bash_tests()) >= 5, (
        f"expected several bash tests, found {len(bash_tests())} — the "
        f"enumeration is broken, so the checks above are vacuous"
    )
