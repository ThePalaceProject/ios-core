"""Tests for scripts/differential_check.py.

Every test here encodes a real failure from the 3.3.0 regression campaign. The
tool exists because three-of-four preconditions holding produces a number that
looks measured and is not, so the tests are written around the two zeros that
actually got produced:

  - a baseline zero from a lane that was never rendered (UNEXERCISED-BASELINE)
  - a comparison attempted across an iPad and an iPhone (DEVICE-MISMATCH)

The refusal path matters more than the success path: a wrong REGRESSION call is
the expensive direction, and it is reached by comparing against a baseline that
never ran the code.
"""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "differential_check.py"

SIMCTL = {
    "devices": {
        "com.apple.CoreSimulator.SimRuntime.iOS-26-0": [
            {"udid": "AAAA0000-0000-0000-0000-000000000001", "name": "iPhone 16 Pro",
             "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro"},
            # Custom-named on purpose: a purpose-built baseline sim is renamed,
            # and comparing names instead of types refuses it. That was a real
            # false DEVICE-MISMATCH on the first pair this tool was asked to run.
            {"udid": "AAAA0000-0000-0000-0000-000000000002", "name": "baseline-iphone16pro-260",
             "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro"},
        ],
        "com.apple.CoreSimulator.SimRuntime.iOS-26-1": [
            {"udid": "BBBB0000-0000-0000-0000-000000000003", "name": "iPad Pro 11-inch (M5)",
             "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-11-inch-M5-12GB"},
        ],
        "com.apple.CoreSimulator.SimRuntime.iOS-18-0": [
            {"udid": "CCCC0000-0000-0000-0000-000000000004", "name": "iPhone 16 Pro",
             "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro"},
        ],
    }
}

CAND = "AAAA0000-0000-0000-0000-000000000001"
BASE = "AAAA0000-0000-0000-0000-000000000002"
IPAD = "BBBB0000-0000-0000-0000-000000000003"
IOS18 = "CCCC0000-0000-0000-0000-000000000004"


def make_recover(tmp_path: Path, per_udid: dict[str, str]) -> str:
    """A stub recovery script that prints canned output per UDID."""
    for udid, text in per_udid.items():
        (tmp_path / f"{udid}.txt").write_text(text)
    stub = tmp_path / "recover.sh"
    stub.write_text("#!/usr/bin/env bash\ncat \"%s/$1.txt\" 2>/dev/null || true\n" % tmp_path)
    stub.chmod(0o755)
    return str(stub)


def run(tmp_path: Path, cand_udid: str, base_udid: str, per_udid: dict[str, str],
        signature: str = "DECODE-FAIL", witness: str = "fulcrum") -> subprocess.CompletedProcess:
    sim = tmp_path / "simctl.json"
    sim.write_text(json.dumps(SIMCTL))
    return subprocess.run(
        [sys.executable, str(SCRIPT),
         "--candidate-udid", cand_udid, "--candidate-start", "s", "--candidate-end", "e",
         "--baseline-udid", base_udid, "--baseline-start", "s", "--baseline-end", "e",
         "--signature", signature, "--witness", witness,
         "--recover-cmd", make_recover(tmp_path, per_udid), "--simctl-json", str(sim)],
        capture_output=True, text=True)


def test_a_renamed_baseline_of_the_same_type_still_compares(tmp_path):
    """CAND and BASE differ in NAME and share a deviceTypeIdentifier.

    The first real pair this tool was handed refused with DEVICE-MISMATCH
    because the baseline sim had been given a descriptive name. Comparing the
    type identifier is the fix; this pins it.
    """
    r = run(tmp_path, CAND, BASE, {CAND: "fulcrum\nDECODE-FAIL\n", BASE: "fulcrum\n"})
    assert r.returncode == 0, r.stderr
    out = json.loads(r.stdout)
    assert out["comparable"] is True
    assert out["candidate"]["device"] != out["baseline"]["device"], "fixture must differ in name"
    assert out["candidate"]["device_type"] == out["baseline"]["device_type"]


def test_a_zero_signature_carries_the_info_level_caveat(tmp_path):
    """A zero signature is only meaningful for debug/error-level strings.

    An archive read is ~98% blind to info level, and this cost a real call: four
    log strings were reported non-existent across three device cells when they
    were merely info level. The tool cannot know a signature's level, so it
    flags the case rather than judging it.
    """
    r = run(tmp_path, CAND, BASE, {CAND: "fulcrum\n", BASE: "fulcrum\n"})
    assert r.returncode == 0, r.stderr
    out = json.loads(r.stdout)
    assert out["signature_candidate"] == 0 and out["signature_baseline"] == 0
    assert "zero_signature_caveat" in out
    assert "info level" in out["zero_signature_caveat"]


def test_a_nonzero_comparison_carries_no_zero_caveat(tmp_path):
    r = run(tmp_path, CAND, BASE, {CAND: "fulcrum\nDECODE-FAIL\n", BASE: "fulcrum\nDECODE-FAIL\n"})
    assert r.returncode == 0, r.stderr
    assert "zero_signature_caveat" not in json.loads(r.stdout)


def test_valid_comparison_emits_counts(tmp_path):
    r = run(tmp_path, CAND, BASE, {
        CAND: "fulcrum request\nDECODE-FAIL\nDECODE-FAIL\n",
        BASE: "fulcrum request\n",
    })
    assert r.returncode == 0, r.stderr
    out = json.loads(r.stdout)
    assert out["comparable"] is True
    assert out["signature_candidate"] == 2
    assert out["signature_baseline"] == 0


def test_baseline_that_never_ran_the_path_is_refused(tmp_path):
    """The campaign's near-miss: 53 vs 0, where the baseline never rendered the lane.

    Without this refusal the tool reports 2 vs 0 and a human files a REGRESSION.
    """
    r = run(tmp_path, CAND, BASE, {
        CAND: "fulcrum request\nDECODE-FAIL\nDECODE-FAIL\n",
        BASE: "some other host request\n",   # no fulcrum: lane never rendered
    })
    assert r.returncode == 5
    out = json.loads(r.stdout)
    assert out["comparable"] is False
    assert out["reason"] == "UNEXERCISED-BASELINE"
    assert "signature_baseline" not in out, "a refused pair must not leak a count"


def test_unexercised_candidate_is_refused(tmp_path):
    r = run(tmp_path, CAND, BASE, {CAND: "nothing relevant\n", BASE: "fulcrum request\n"})
    assert r.returncode == 5
    assert json.loads(r.stdout)["reason"] == "UNEXERCISED-CANDIDATE"


def test_device_mismatch_is_refused_before_any_reading(tmp_path):
    """iPad candidate vs iPhone baseline — three clusters failed exactly this way."""
    r = run(tmp_path, IPAD, BASE, {IPAD: "fulcrum\nDECODE-FAIL\n", BASE: "fulcrum\n"})
    assert r.returncode == 5
    out = json.loads(r.stdout)
    assert out["reason"] == "DEVICE-MISMATCH"
    assert "signature_candidate" not in out


def test_os_mismatch_is_refused(tmp_path):
    """Same device model, different OS — iOS 18 cell against an iOS 26 baseline."""
    r = run(tmp_path, IOS18, BASE, {IOS18: "fulcrum\nDECODE-FAIL\n", BASE: "fulcrum\n"})
    assert r.returncode == 5
    assert json.loads(r.stdout)["reason"] == "OS-MISMATCH"


def test_incidental_witness_hits_do_not_count_as_exercising_the_path(tmp_path):
    """The defect the stub tests MISSED and the real data exposed.

    The first version of this tool checked witness > 0. Run against the actual
    campaign pair it PASSED: the baseline mentioned the witness host 3 times
    incidentally while never rendering the lane, so a 53-vs-0 comparison was
    emitted — the false REGRESSION the tool exists to prevent. Raw counts also
    cannot be compared, because the candidate window was 7k lines and the
    baseline 536k. Density is the check.

    Shape mirrors the real numbers: candidate ~0.14 witness/kloc, baseline
    ~0.006, a ratio of ~25.
    """
    cand = "fulcrum request\nDECODE-FAIL\n" + ("filler\n" * 12)
    base = ("filler\n" * 500) + "incidental fulcrum mention\n"
    r = run(tmp_path, CAND, BASE, {CAND: cand, BASE: base})
    assert r.returncode == 5, "a baseline that never really ran the path must be refused"
    out = json.loads(r.stdout)
    assert out["reason"] == "WITNESS-DISPROPORTIONATE"
    assert "signature_baseline" not in out, "a refused pair must not leak a count"


def test_min_witness_can_require_a_real_exercise(tmp_path):
    """`--min-witness 1` is the weak default; a caller who knows the path can demand more."""
    both_thin = {CAND: "fulcrum\nDECODE-FAIL\n", BASE: "fulcrum\n"}
    assert run(tmp_path, CAND, BASE, both_thin).returncode == 0
    sim = tmp_path / "simctl.json"; sim.write_text(json.dumps(SIMCTL))
    r = subprocess.run(
        [sys.executable, str(SCRIPT),
         "--candidate-udid", CAND, "--candidate-start", "s", "--candidate-end", "e",
         "--baseline-udid", BASE, "--baseline-start", "s", "--baseline-end", "e",
         "--signature", "DECODE-FAIL", "--witness", "fulcrum", "--min-witness", "10",
         "--recover-cmd", make_recover(tmp_path, both_thin), "--simctl-json", str(sim)],
        capture_output=True, text=True)
    assert r.returncode == 5
    assert json.loads(r.stdout)["reason"] == "UNEXERCISED-CANDIDATE"


def test_every_refusal_says_it_is_not_a_finding(tmp_path):
    """A refusal must not be quotable as evidence about the builds.

    The campaign hit this directly: a WITNESS-DISPROPORTIONATE on a cluster whose
    URL evidence is unreadable means "this data cannot answer the question", not
    "the baseline never rendered the lane". Identical output, opposite meanings —
    so the tool carries the disclaimer instead of relying on the reader.
    """
    cases = [
        (IPAD, BASE, {IPAD: "fulcrum\nDECODE-FAIL\n", BASE: "fulcrum\n"}),          # device
        (IOS18, BASE, {IOS18: "fulcrum\nDECODE-FAIL\n", BASE: "fulcrum\n"}),        # os
        (CAND, BASE, {CAND: "fulcrum\nDECODE-FAIL\n", BASE: "nothing\n"}),          # unexercised
    ]
    for cand_udid, base_udid, per in cases:
        r = run(tmp_path, cand_udid, base_udid, per)
        assert r.returncode == 5
        out = json.loads(r.stdout)
        assert "not_a_finding" in out, f"{out['reason']} refusal lacks the disclaimer"
        assert "not evidence" in out["not_a_finding"]
        assert "not about the builds" in r.stderr


def test_refusal_never_shares_an_exit_code_with_a_valid_comparison(tmp_path):
    ok = run(tmp_path, CAND, BASE, {CAND: "fulcrum\nDECODE-FAIL\n", BASE: "fulcrum\n"})
    bad = run(tmp_path, CAND, BASE, {CAND: "fulcrum\nDECODE-FAIL\n", BASE: "nothing\n"})
    assert ok.returncode == 0 and bad.returncode == 5
