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


def real_skip_details() -> list[tuple[str, str]]:
    """(key, detail) for every skip the script ACTUALLY emits.

    The census test used to invent details (`f"not run ({flag})"`), which the
    script emits for `--mutation-only`/`--quick` only. The two opt-in arms —
    "Not run (pass --simdrive to enable)" — say the OPPOSITE, and inventing
    strings meant no test ever saw them. That is how a census which failed every
    ordinary run, including the documented `--quick`, survived 378 green pytests.
    Derive the fixtures; do not author them.
    """
    with open(VPR, encoding="utf-8") as fh:
        text = fh.read()
    return re.findall(r'record "([a-z_0-9]+)" "skip" "([^"]*)"', text)


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


def test_an_ordinary_run_emitting_the_scripts_own_skip_reasons_passes():
    """THE REGRESSION THIS FILE EXISTS FOR NOW.

    Every skip detail the script really emits, on a plain run with no flags.
    The first census treated "Not run (pass --simdrive to enable)" as a claim
    that --simdrive HAD been passed, so an ordinary run — and `--quick`, the
    documented pre-PR command that the pre-push hook gates on — came back
    BLOCKED. Two reviewers measured it; no test did, because the fixtures were
    invented rather than derived.
    """
    # Only the details an ORDINARY run can emit. A key's mode-specific arms
    # ("Skipped (--mutation-only)") are unreachable without the flag, so feeding
    # them here would assert that an impossible state is fine — the opposite of
    # the point. What remains is exactly the set that broke: the opt-in arms.
    MODE_FLAGS = ("--mutation-only", "--quick", "--simdrive", "--chaos", "--diff-baseline")
    def reachable_without_flags(detail: str) -> bool:
        for flag in MODE_FLAGS:
            if flag in detail and f"pass {flag}" not in detail and "opt-in" not in detail:
                return False
        return True

    # Prefer the opt-in arm where a key has one: a dict comprehension keeps the
    # LAST detail per key, which silently dropped exactly the arms this test is
    # about. The control below caught that.
    details: dict[str, str] = {}
    for k, d in real_skip_details():
        if not reachable_without_flags(d):
            continue
        prefer = ("pass --" in d) or ("opt-in" in d)
        if k not in details or prefer:
            details[k] = d
    assert any("pass --simdrive" in d or "opt-in" in d for d in details.values()), (
        "the opt-in arms are missing from the fixture — this test would then be "
        "blind to exactly the defect it exists for"
    )
    results = [rec(k, "skip", details[k]) if k in details else rec(k)
               for k in every_declared_key()]
    for argv in ([], ["--quick"]):
        fails, out = drive(results, argv=argv)
        assert fails == 0, f"an honest run with argv={argv} was blocked:\n{out}"


@pytest.mark.parametrize("flag,detail", [
    ("--mutation-only", "Skipped (--mutation-only)"),
    ("--quick", "Skipped (--quick mode)"),
])
def test_present_polarity_reasons_are_censused(flag, detail):
    """These arms mean "skipped BECAUSE the flag was given", so the reason is
    impossible without it — and legitimate with it."""
    keys = every_declared_key()
    results = [rec(k, "skip", detail) if k == "mutation" else rec(k) for k in keys]
    fails, out = drive(results, argv=[])
    assert fails >= 1, f"{flag} reason not censused\n{out}"
    ok, out_ok = drive(results, argv=[flag])
    assert ok == 0, f"{flag} legitimately given should not fail\n{out_ok}"


@pytest.mark.parametrize("detail", [
    "Not run (pass --simdrive to enable)",
    "not run (opt-in; pass --chaos to enable)",
])
def test_optin_polarity_reasons_are_exempt(detail):
    """The flag's ABSENCE is the reason. Flagging these blocked every real run."""
    keys = every_declared_key()
    results = [rec(k, "skip", detail) if k == "simdrive" else rec(k) for k in keys]
    fails, out = drive(results, argv=[])
    assert fails == 0, f"opt-in reason wrongly censused:\n{out}"


def test_a_pass_detail_claiming_a_flag_is_censused_too():
    """`--diff-baseline` records `pass`, never `skip`. A skip-only loop left it
    enumerated but unguarded — the appearance of coverage without the fact."""
    keys = every_declared_key()
    results = [rec(k, "pass", "flake-triaged per --diff-baseline") if k == "unit_tests"
               else rec(k) for k in keys]
    fails, out = drive(results, argv=[])
    assert fails >= 1, f"a pass detail claiming an unpassed flag was not censused\n{out}"
    ok, _ = drive(results, argv=["--diff-baseline"])
    assert ok == 0


def test_success_is_recorded_so_a_disabled_block_is_visible():
    """Silent on success means a run where the block was disabled outright is
    byte-identical to one where it passed."""
    fails, out = drive([rec(k) for k in every_declared_key()])
    assert fails == 0, out
    assert "leg_accounting" in out and "accounted for" in out, (
        "the accounting passed without saying so — a disabled block looks the same"
    )
