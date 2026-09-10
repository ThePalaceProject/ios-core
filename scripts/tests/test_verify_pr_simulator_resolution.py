#!/usr/bin/env python3
"""
test_verify_pr_simulator_resolution.py — self-verify verify-pr.sh's simulator
resolution and its test-execution timeouts.

prior-art-checked: this is a repo-local pytest in the established
`scripts/tests/test_*.py` family (65 siblings), directly modelled on
`test_xcode_test_optimized_simulator_selection.py`, which does the same job for
the CI script. The harness tools surfaced at capture time (bridge spawn, glyphs
push, memory files, the critical-path push hook) solve unrelated problems and
none of them can gate a shell script that outside contributors run unaided —
which is the whole requirement here, per CLAUDE.local.md's rule that
harness-free tooling belongs in the shared repo.

WHY THIS EXISTS. `verify-pr.sh` used to build with
`-destination "id=${HARNESS_SESSION_SIM_UDID:-<a hardcoded UDID>}"`, unchecked.
That UDID exists on one machine. Everywhere else the destination resolves to
nothing — and an unresolvable destination does NOT yield `BUILD FAILED`. The
build tool prints "The requested device could not be found" and neither verdict
string, so the script recorded "Build did not complete" and four legs went red
pointing at the diff. Measured 2026-09-10: two consecutive full runs lost that
way, plus a confident wrong diagnosis (machine load) layered on top, because
nothing in the output named the simulator.

The second half guards a sibling asymmetry found the same day:
`xcode-test-optimized.sh` (the CI path) has always bounded test execution, while
`verify-pr.sh` (the local pre-push path) did not. A test with an unbounded await
therefore failed in CI after 300s and hung FOREVER locally — ten hours at 0%
CPU, indistinguishable from slow progress.

The resolver is exercised against a stubbed device list, so these assert the
DECISION without launching Xcode.
"""

from __future__ import annotations

import subprocess
import textwrap
from pathlib import Path

import pytest

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_SCRIPT = _REPO_ROOT / "scripts" / "verify-pr.sh"

# One available iPhone plus noise, in `simctl list devices available` shape.
_AVAILABLE = textwrap.dedent(
    """\
    == Devices ==
    -- iOS 26.0 --
        iPhone 16 Pro (AAAAAAAA-1111-2222-3333-444444444444) (Shutdown)
        iPad Pro 13-inch (M5) (BBBBBBBB-1111-2222-3333-444444444444) (Shutdown)
    """
)

_NONE_AVAILABLE = "== Devices ==\n"


def _run_resolver(available_output: str, want: str) -> subprocess.CompletedProcess:
    """Extract resolve_sim_id from the script and run it against a stubbed device list."""
    source = _SCRIPT.read_text()
    start = source.index("resolve_sim_id() {")
    end = source.index("\n}", start) + 2
    func = source[start:end]

    program = f"""
    xcrun() {{ printf '%s' "$STUB_OUTPUT"; }}
    {func}
    resolve_sim_id "{want}"
    """
    return subprocess.run(
        ["bash", "-c", program],
        capture_output=True,
        text=True,
        env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "STUB_OUTPUT": available_output},
    )


def test_script_syntax_is_valid():
    result = subprocess.run(["bash", "-n", str(_SCRIPT)], capture_output=True, text=True)
    assert result.returncode == 0, result.stderr


# --------------------------------------------------------------- clean path
# The gate must not block what it should allow. A detector exercised only
# against violations passes while rejecting every legitimate input.


def test_available_udid_is_used_verbatim():
    """The whole point: an id that EXISTS is honoured, not second-guessed."""
    out = _run_resolver(_AVAILABLE, "AAAAAAAA-1111-2222-3333-444444444444")
    assert out.stdout.strip() == "AAAAAAAA-1111-2222-3333-444444444444"


def test_allocator_choice_survives_resolution():
    """Parallel agents rely on this: a claimed, present device must win."""
    out = _run_resolver(_AVAILABLE, "AAAAAAAA-1111-2222-3333-444444444444")
    assert out.returncode == 0
    assert out.stdout.strip() == "AAAAAAAA-1111-2222-3333-444444444444"


# --------------------------------------------------------------- the defect
def test_absent_udid_falls_back_to_a_device_that_exists():
    """The original bug: an absent id was handed to the build tool anyway."""
    out = _run_resolver(_AVAILABLE, "DEADBEEF-0000-0000-0000-000000000000")
    assert out.stdout.strip() == "AAAAAAAA-1111-2222-3333-444444444444"


def test_fallback_never_selects_a_non_iphone():
    """An iPad would 'resolve' and then fail the suite for the wrong reason."""
    out = _run_resolver(_AVAILABLE, "DEADBEEF-0000-0000-0000-000000000000")
    assert "BBBBBBBB" not in out.stdout


def test_no_simulator_at_all_resolves_to_nothing():
    """Empty, so the caller can exit 2 with a message rather than build blind."""
    out = _run_resolver(_NONE_AVAILABLE, "DEADBEEF-0000-0000-0000-000000000000")
    assert out.stdout.strip() == ""


def test_caller_exits_with_a_named_reason_when_nothing_resolves():
    """Exit 2 and an actionable message beat four red legs blaming the diff."""
    source = _SCRIPT.read_text()
    assert 'echo "FATAL: no usable iOS simulator found." >&2' in source
    assert "exit 2" in source
    assert "HARNESS_SESSION_SIM_UDID" in source


# ------------------------------------------------- hang guard (CI asymmetry)
def test_local_test_leg_bounds_execution_like_ci_does():
    """
    A hang must fail, not stall. The CI script has bounded test execution since
    it was written; verify-pr.sh did not, and the local pre-push check is
    exactly where an overnight silent stall costs the most.
    """
    source = _SCRIPT.read_text()
    assert "-test-timeouts-enabled YES" in source
    assert "-default-test-execution-time-allowance 120" in source
    assert "-maximum-test-execution-time-allowance 300" in source


def test_local_allowances_match_the_ci_path_exactly():
    """
    Two encodings of one policy is how the original asymmetry survived. If CI's
    numbers change, this fails and forces the local path to follow.
    """
    ci = (_REPO_ROOT / "scripts" / "xcode-test-optimized.sh").read_text()
    local = _SCRIPT.read_text()
    for flag in (
        "-test-timeouts-enabled YES",
        "-default-test-execution-time-allowance 120",
        "-maximum-test-execution-time-allowance 300",
    ):
        assert flag in ci, f"CI path no longer sets {flag!r} — update both paths together"
        assert flag in local, f"local path missing {flag!r}"


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-v"]))
