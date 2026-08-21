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


def drive(results: list[str], argv: list[str] | None = None,
          script_path: str | None = None) -> tuple[int, str]:
    """Run the block against a synthetic RESULTS array.

    Supplies SCRIPT_PATH and ORIGINAL_ARGV rather than rewriting the expressions
    under review. The previous version substituted `"$0"` -> `"$1"` with an
    absolute path, which is precisely the expression that was broken — so the
    test could only ever drive the working configuration and was structurally
    blind to the defect a reviewer then found by hand.
    """
    array = " ".join(f"'{r}'" for r in results)
    argv_text = " ".join(f"'{a}'" for a in (argv or []))
    script = (
        "#!/usr/bin/env bash\n"
        f'SCRIPT_PATH="{script_path if script_path is not None else VPR}"\n'
        f"ORIGINAL_ARGV=({argv_text})\n"
        "FAIL_COUNT=0\nPASS_COUNT=0\n"
        f"RESULTS=({array})\n"
        + accounting_block()
        + '\necho "FAIL_COUNT=$FAIL_COUNT"\n'
    )
    proc = subprocess.run(["bash", "-s"], input=script, capture_output=True, text=True)
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


def test_an_empty_derivation_fails_instead_of_passing_vacuously():
    """`$0` stopped resolving after the script's own `cd`, so the owed set came
    back empty — zero owed legs means zero missing means green, silently. A
    reviewer measured exactly that with `cd scripts && ./verify-pr.sh`."""
    fails, out = drive([rec("build")], script_path="/nonexistent/verify-pr.sh")
    assert fails >= 1, out
    assert "derivation broken" in out or "derived only" in out


def test_attack_b_impossible_skip_reason_is_caught():
    """Inverting `[ "$MUTATION_ONLY" = "true" ]` sends an ORDINARY run down the
    skip arm: the key is recorded, so the reconciliation passes. The reason is
    what gives it away — a leg cannot be skipped for --mutation-only on a run
    that is not --mutation-only."""
    keys = every_declared_key()
    results = [rec(k, "skip", "not run (--mutation-only)") if k == "build" else rec(k)
               for k in keys]
    fails, out = drive(results, argv=[])
    assert fails >= 1, out
    assert "build" in out


def test_that_same_skip_is_legitimate_on_a_real_mutation_only_run():
    """Control for the above — the check must key on the MODE, not the string."""
    keys = every_declared_key()
    results = [rec(k, "skip", "not run (--mutation-only)") if k == "build" else rec(k)
               for k in keys]
    fails, out = drive(results, argv=["--mutation-only"])
    assert fails == 0, out


@pytest.mark.parametrize("flag", ["--quick", "--simdrive", "--chaos", "--diff-baseline"])
def test_every_mode_flag_is_censused_not_just_mutation_only(flag):
    """The first version checked only `--mutation-only`, so inverting the guard
    on `--quick` or `--simdrive` was attack B on an unchecked leg. A reviewer
    drove both and got FAIL_COUNT=0."""
    keys = every_declared_key()
    results = [rec(k, "skip", f"not run ({flag})") if k == "mutation" else rec(k)
               for k in keys]
    fails, out = drive(results, argv=[])
    assert fails >= 1, f"{flag} skip-reason not censused\n{out}"

    fails_ok, out_ok = drive(results, argv=[flag])
    assert fails_ok == 0, f"{flag} legitimately passed should not fail\n{out_ok}"


def test_success_is_recorded_so_a_disabled_block_is_visible():
    """Silent on success means a run where the block was disabled outright is
    byte-identical to one where it passed."""
    fails, out = drive([rec(k) for k in every_declared_key()])
    assert fails == 0, out
    assert "leg_accounting" in out and "accounted for" in out, (
        "the accounting passed without saying so — a disabled block looks the same"
    )
