"""Order re-rolling in `scripts/find-test-polluter.sh`.

`Palace.xcscheme` sets `testExecutionOrdering = "random"`, so selecting
`-only-testing:SUSPECT -only-testing:VICTIM` does not make the suspect run
first. A pair that ran in the wrong order can neither implicate nor clear the
suspect, and the script correctly refuses to judge it.

Without a re-roll that refusal is the common case, not the edge case. A real
search on 2026-10-14 (victim `TestTargetHermeticityRegressionTests`, seven
suspects) judged two and left five `INCONCLUSIVE: did not finish before the
victim started`, reporting INCOMPLETE — so a victim already proven flaky by
`ci-test-history` got no polluter verdict at all, from a tool whose whole job is
to produce one.

These tests drive `run_pair_in_order` as a shell fragment lifted from the real
file, stubbing the run and the order reading, so they assert the retry DECISION
without launching Xcode. They sit beside the existing
`test_find_test_polluter_verdicts.py`, which uses the same fragment-extraction
approach for the classifier and the decision table.

prior-art-checked: this is a pytest for one repo script's retry predicate, run
by tooling-checks.yml alongside the other `scripts/tests/` files. The harness
capabilities the hook offered (glyphs push/harm, gc, bridge rails, memory
writes) are disk, provenance and coordination tools; none of them tests a shell
function, and `harness capabilities` lists no pytest runner for repo scripts.
"""

import subprocess
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "find-test-polluter.sh"


def _fragment() -> str:
    text = SCRIPT.read_text()
    start = text.index("# >>> run_pair_in_order BEGIN")
    end = text.index("# <<< run_pair_in_order END")
    return text[start:end]


def _run(order_sequence, attempts_cap=6):
    """Drive the loop with a scripted sequence of order_state readings.

    `order_sequence` is consumed one entry per roll; the stub echoes the next
    one each time it is called.
    """
    orders = " ".join(order_sequence)
    script = f"""
set -uo pipefail
ORDER_ATTEMPTS={attempts_cap}
PAIR_VERDICT=""; PAIR_ORDER=""; PAIR_ATTEMPTS=0
ORDERS=({orders})
# The roll counter lives in a FILE, not a variable: `order_state` is invoked
# inside a command substitution, so a shell-variable increment happens in a
# subshell and is discarded — every roll would then read the first entry.
COUNTER=$(mktemp)
echo 0 > "$COUNTER"
log_for() {{ printf '%s' "/tmp/$1.log"; }}
# Each roll consumes the next scripted order reading.
order_state() {{
  local i; i=$(cat "$COUNTER")
  echo "${{ORDERS[$i]:-exhausted}}"
  echo $((i + 1)) > "$COUNTER"
}}
# Stub the runner, not `run_pair_tests`: the fragment defines the latter itself,
# so a stub of that name is overwritten when the fragment is sourced below.
run_tests() {{ echo "ran:pass"; }}
{_fragment()}
run_pair_in_order "pair-S" "S" "V"
echo "VERDICT=$PAIR_VERDICT ORDER=$PAIR_ORDER ATTEMPTS=$PAIR_ATTEMPTS"
"""
    proc = subprocess.run(["bash", "-c", script], capture_output=True, text=True)
    assert proc.returncode == 0, f"fragment errored: {proc.stderr}"
    return proc.stdout.strip().splitlines()[-1]


def test_wrong_order_is_retried_until_the_suspect_runs_first():
    """The defect: one wrong-order roll used to end the pair as unjudgeable."""
    assert _run(["wrong-order", "wrong-order", "ok"]) == (
        "VERDICT=ran:pass ORDER=ok ATTEMPTS=3"
    )


def test_a_first_roll_in_the_right_order_does_not_re_roll():
    """Retrying a judgeable pair would multiply the runtime of every search."""
    assert _run(["ok"]) == "VERDICT=ran:pass ORDER=ok ATTEMPTS=1"


def test_retrying_stops_at_the_cap_and_stays_unjudged():
    """The cap must not be exceeded, and must not fake a verdict when reached.

    Reporting `ok` here would clear a suspect the tool never managed to test.
    """
    assert _run(["wrong-order"] * 10, attempts_cap=3) == (
        "VERDICT=ran:pass ORDER=wrong-order ATTEMPTS=3"
    )


def test_an_absent_class_is_not_re_rolled():
    """Only wrong-order is a dice problem.

    A suspect or victim missing from the log, or a log with no per-case lines,
    is a different fault that another roll cannot fix; burning the budget on it
    hides the real cause behind a slower run.
    """
    for unretryable in ("first-absent", "second-absent", "order-unobservable"):
        out = _run([unretryable, "ok"])
        assert out == f"VERDICT=ran:pass ORDER={unretryable} ATTEMPTS=1", out
