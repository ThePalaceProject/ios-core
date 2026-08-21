#!/usr/bin/env python3
"""
verify-pr.sh must notice a leg that did not run at all.

WHY THIS EXISTS. Every check in `verify-pr.sh` reports itself, and the summary
is built from what reported. So a leg that never executes contributes nothing
and is indistinguishable from a leg that ran clean. Review demonstrated three
ways to reach that state while leaving the code present and `bash -n` clean:
wrapping the section in `if false; then … fi`, inverting an outer guard, and
moving the block into a function nobody calls.

The script answers by declaring the legs it owes and reconciling before the
summary. This drives that reconciliation directly — lifting the block and
running it against synthetic result sets — because the block itself shipped with
no test at all, in the branch that exists to enforce CLAUDE.md's rule that a new
gate does not land faster than it can be verified.

The fourth case matters most and was found last: a `skip` satisfies the
reconciliation on purpose, so inverting `[ "$MUTATION_ONLY" = "true" ]` sends an
ordinary run down the skip arm and the leg accounts for itself while doing
nothing. That is caught by checking the skip REASON against the mode in force.
"""

import os
import re
import subprocess

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
VPR = os.path.join(REPO, "scripts", "verify-pr.sh")


def accounting_block() -> str:
    """Lift the reconciliation out of verify-pr.sh."""
    with open(VPR, encoding="utf-8") as fh:
        text = fh.read()
    start = text.index("# --- Every leg must ACCOUNT for itself")
    end = text.index('# Summary\necho ""')
    block = text[start:end]
    assert "MISSING_KEYS" in block, "extraction range has drifted"
    assert "EXPECTED_KEYS=" in block, "extraction range has drifted"
    return block


def drive(results: list[str], mutation_only: str = "false") -> tuple[int, str]:
    """Run the block against a synthetic RESULTS array. Returns (FAIL_COUNT, output)."""
    array = " ".join(f"'{r}'" for r in results)
    script = (
        "#!/usr/bin/env bash\n"
        f"MUTATION_ONLY={mutation_only}\n"
        "FAIL_COUNT=0\n"
        f"RESULTS=({array})\n"
        + accounting_block()
        + "\necho \"FAIL_COUNT=$FAIL_COUNT\"\n"
    )
    # `$0` must be verify-pr.sh: the owed set is derived from its own call sites.
    proc = subprocess.run(["bash", "-s", VPR], input=script.replace('"$0"', '"$1"'),
                          capture_output=True, text=True)
    out = proc.stdout + proc.stderr
    m = re.search(r"FAIL_COUNT=(\d+)", out)
    return (int(m.group(1)) if m else -1), out


def rec(key: str, status: str = "pass", detail: str = "x") -> str:
    return f'{{"check":"{key}","status":"{status}","detail":"{detail}"}}'


def every_declared_key() -> list[str]:
    with open(VPR, encoding="utf-8") as fh:
        text = fh.read()
    keys = set(re.findall(r'(?:record|run_phase35_detector) "([a-z_0-9]+)"', text))
    keys.discard("leg_accounting")
    keys.discard("leg_accounting_reason")
    return sorted(keys)


def test_the_owed_set_is_derived_not_a_short_hardcoded_list():
    """The first version hardcoded 13 of 36 keys, leaving 23 legs unguarded."""
    keys = every_declared_key()
    assert len(keys) >= 30, f"expected the full leg set, derived only {len(keys)}"


def test_control_all_legs_reported_passes():
    fails, out = drive([rec(k) for k in every_declared_key()])
    assert fails == 0, out


def test_attack_a_declared_leg_records_nothing_is_caught():
    """`if false; then … fi`, or a block moved into an uncalled function."""
    keys = every_declared_key()
    fails, out = drive([rec(k) for k in keys if k != "doc_hygiene"])
    assert fails >= 1, out
    assert "doc_hygiene" in out


def test_attack_c_undeclared_leg_records_nothing_is_caught():
    """The hardcoded list omitted `intent_recorded` — a blocking gate whose
    siblings were declared. Derivation covers every key or none."""
    keys = every_declared_key()
    assert "intent_recorded" in keys, "intent_recorded is not being derived"
    fails, out = drive([rec(k) for k in keys if k != "intent_recorded"])
    assert fails >= 1, out
    assert "intent_recorded" in out


def test_a_legitimate_skip_still_accounts_for_itself():
    """`skip` means "ran nothing and said so", which is reported, not missing."""
    keys = every_declared_key()
    results = [rec(k, "skip", "driver unavailable") if k == "chaos" else rec(k)
               for k in keys]
    fails, out = drive(results)
    assert fails == 0, out


def test_attack_b_impossible_skip_reason_is_caught():
    """Inverting `[ "$MUTATION_ONLY" = "true" ]` sends an ORDINARY run down the
    skip arm: the key is recorded, so the reconciliation passes. The reason is
    what gives it away — a leg cannot be skipped for --mutation-only on a run
    that is not --mutation-only."""
    keys = every_declared_key()
    results = [rec(k, "skip", "not run (--mutation-only)") if k == "build" else rec(k)
               for k in keys]
    fails, out = drive(results, mutation_only="false")
    assert fails >= 1, out
    assert "build" in out


def test_that_same_skip_is_legitimate_on_a_real_mutation_only_run():
    """Control for the above — the check must key on the MODE, not the string."""
    keys = every_declared_key()
    results = [rec(k, "skip", "not run (--mutation-only)") if k == "build" else rec(k)
               for k in keys]
    fails, out = drive(results, mutation_only="true")
    assert fails == 0, out
