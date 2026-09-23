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
    literal = re.findall(r'record "([a-z_0-9]+)" "skip" "([^"]*)"', text)
    # `run_phase35_detector` records through `record "$key" …`, so a literal-key
    # regex cannot see those sites and their keys silently fall back to an
    # invented detail. Pick them up separately rather than let the derivation
    # narrow without saying so.
    dynamic = [("<phase35>", d) for d in
               re.findall(r'record "\$key" "skip" "([^"]*)"', text)]
    return literal + dynamic


def real_pass_details() -> list[tuple[str, str]]:
    """(key, detail) for every `pass` the script actually emits.

    The census inspects pass entries as well as skips, and the pass half was
    still hand-authored — the invented-fixture shape that hid the round-7 defect
    behind 378 green tests. Two reviewers said "derive it or drop the claim".
    """
    with open(VPR, encoding="utf-8") as fh:
        text = fh.read()
    return re.findall(r'record "([a-z_0-9]+)" "pass" "([^"]*)"', text)


def every_declared_key() -> list[str]:
    with open(VPR, encoding="utf-8") as fh:
        text = fh.read()
    keys = set(re.findall(r'(?:record|run_phase35_detector) "([a-z_0-9]+)"', text))
    keys.discard("leg_accounting")
    keys.discard("leg_accounting_reason")
    return sorted(keys)


def test_the_derivation_has_not_silently_narrowed():
    """A derived fixture with no floor derives nothing and passes.

    The regex missed the two dynamic-key sites, so ten phase-3.5 detectors fell
    back to an invented detail — the same keys that were round 5's attack-C
    hole. `EXPECTED_KEYS` has a floor in the script; this had none, which is the
    silent-narrowing shape one level out.
    """
    details = real_skip_details()
    assert len(details) >= 60, (
        f"derived only {len(details)} skip details; the extraction has narrowed "
        f"and every fixture built from it is quietly thinner than it claims"
    )
    # A TOTAL floor cannot see the narrowing mode that actually happened: the
    # literal-key regex yields 67 on its own, so dropping the two dynamic-key
    # sites entirely leaves the total comfortably above any round number. Pin
    # the arm, not the sum.
    dynamic = [d for k, d in details if k == "<phase35>"]
    literal = [d for k, d in details if k != "<phase35>"]
    # COUNT, not presence: there are two `record "$key" "skip"` sites, and
    # dropping one of them survived a bare `assert dynamic`.
    assert len(dynamic) >= 2, (
        f"derived only {len(dynamic)} dynamic-key skip details; expected both "
        f"`record \"$key\" \"skip\"` sites"
    )
    assert len(literal) >= 60, (
        f"derived only {len(literal)} literal-key skip details — the literal arm "
        f"has narrowed, which a total floor cannot see"
    )
    assert dynamic, (
        "no dynamic-key (`record \"$key\"`) skip sites were derived. Those are "
        "the phase-3.5 detectors — round 5's attack-C hole — and a literal-key "
        "regex cannot see them."
    )


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


@pytest.mark.parametrize("n_keys", [0, 1, 5, 29])
def test_the_vacuity_floor_rejects_an_implausibly_small_derivation(n_keys, tmp_path):
    """The floor that stops an empty derivation passing was not itself pinned.

    A reviewer changed `-lt 30` to `-lt 1` and all fifteen tests stayed green,
    then drove the block with five keys and got `[PASS] 5/5 legs accounted for`
    while 31 legs went unreconciled. A floor nothing tests is a number, not a
    guard.
    """
    stub = tmp_path / "stub-verify-pr.sh"
    stub.write_text("\n".join(f'record "leg{i}" "pass" "x"' for i in range(n_keys)),
                    encoding="utf-8")
    results = [rec(f"leg{i}") for i in range(n_keys)]
    fails, out = drive(results, argv=[], script_path=str(stub))
    assert fails >= 1, (
        f"a {n_keys}-leg derivation was accepted as a full accounting:\n{out}"
    )


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

    # EVERY reachable (key, detail) pair, driven one at a time. A dict keyed by
    # leg keeps one detail per key and drops the rest — it silently discarded the
    # opt-in arms once already, and two reviewers flagged it again as the shape
    # this file has been wrong about twice. There is no reason to collapse: the
    # census inspects entries independently, so the pairs can be too.
    reachable = [(k, d) for k, d in real_skip_details() if reachable_without_flags(d)]
    assert any("pass --simdrive" in d or "opt-in" in d for _, d in reachable), (
        "the opt-in arms are missing from the fixture — this test would then be "
        "blind to exactly the defect it exists for"
    )
    keys = every_declared_key()
    for key, detail in reachable:
        target = key if key in keys else "simdrive"
        results = [rec(k, "skip", detail) if k == target else rec(k) for k in keys]
        for argv in ([], ["--quick"]):
            fails, out = drive(results, argv=argv)
            assert fails == 0, (
                f"an honest run with argv={argv} was blocked by "
                f"{target}={detail!r}:\n{out}"
            )


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
    # WITNESS FOR THE `opt-in` ARM ITSELF. Both cases above also contain
    # `pass --<flag>`, so they exempt through the OTHER clause and deleting the
    # opt-in clause left every test green — the round-7 defect's own guard, half
    # pinned. This one has no `pass --`, so only the opt-in clause can exempt it.
    "not run (opt-in; --chaos enables it)",
])
def test_optin_polarity_reasons_are_exempt(detail):
    """The flag's ABSENCE is the reason. Flagging these blocked every real run."""
    keys = every_declared_key()
    results = [rec(k, "skip", detail) if k == "simdrive" else rec(k) for k in keys]
    fails, out = drive(results, argv=[])
    assert fails == 0, f"opt-in reason wrongly censused:\n{out}"


def test_the_optin_exemption_is_scoped_to_the_flag_under_test():
    """A bare `*"opt-in"*` clause would exempt an entry for ALL five flags.

    The exemption runs inside a per-flag loop, so an unscoped spelling lets one
    "opt-in" anywhere in a detail blanket-exempt every other flag in the same
    entry. Both reviewers reverted the scoping and got 21/21 green — a fifth
    half-pinned guard, added in the commit that existed to pin the others.

    This detail is exempt for --chaos (opt-in) and NOT for --mutation-only, so
    only a flag-scoped exemption censuses it correctly.
    """
    keys = every_declared_key()
    detail = "not run (opt-in; --chaos enables it) - Skipped (--mutation-only)"
    results = [rec(k, "skip", detail) if k == "chaos" else rec(k) for k in keys]
    fails, out = drive(results, argv=[])
    assert fails >= 1, (
        "an unscoped opt-in exemption let an impossible --mutation-only claim "
        f"through on the strength of an unrelated --chaos opt-in:\n{out}"
    )
    assert "--mutation-only" in out


def test_a_pass_detail_claiming_a_flag_is_censused_too():
    """`--diff-baseline` records `pass`, never `skip`. A skip-only loop left it
    enumerated but unguarded — the appearance of coverage without the fact."""
    keys = every_declared_key()
    # DERIVED, not invented: the script's own pass details that name a flag.
    flagged = [(k, d) for k, d in real_pass_details()
               if any(f in d for f in ("--mutation-only", "--quick", "--simdrive",
                                       "--chaos", "--diff-baseline"))
               and "pass --" not in d and "opt-in" not in d]
    assert flagged, (
        "no derived pass detail names a flag — this test would assert nothing. "
        "If the script stopped emitting one, delete this test rather than let "
        "it pass vacuously."
    )
    for key, detail in flagged:
        target = key if key in keys else "unit_tests"
        results = [rec(k, "pass", detail) if k == target else rec(k) for k in keys]
        flag = next(f for f in ("--mutation-only", "--quick", "--simdrive",
                                "--chaos", "--diff-baseline") if f in detail)
        fails, out = drive(results, argv=[])
        assert fails >= 1, f"pass detail {detail!r} claiming {flag} was not censused\n{out}"
        ok, _ = drive(results, argv=[flag])
        assert ok == 0, f"pass detail {detail!r} wrongly censused with {flag} given"


def test_success_is_recorded_so_a_disabled_block_is_visible():
    """Silent on success means a run where the block was disabled outright is
    byte-identical to one where it passed."""
    fails, out = drive([rec(k) for k in every_declared_key()])
    assert fails == 0, out
    assert "leg_accounting" in out and "accounted for" in out, (
        "the accounting passed without saying so — a disabled block looks the same"
    )
