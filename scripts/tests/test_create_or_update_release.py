"""Release publishing must tell an absent release from an unanswered query.

The defect these cover: the release workflows used to decide with
`if gh release view "$V" >/dev/null 2>&1`, which treats every non-zero the same
and discards the message. A transient API error therefore routed an
already-released version to `gh release create`, which fails with
"tag_name already exists". That took the 3.3.1 build-512 merge red on
2026-10-02, with no record of the original error.

Each test drives the real scripts with a fake `gh` first on PATH that records
the subcommands it was asked to run, so the assertions are about which API call
the script chose, not about its internals.

prior-art-checked: a pytest beside the other detector tests in this directory,
collected by the same `pytest scripts/tests/` run in tooling-checks.yml. Nothing
in the local tooling runs shared-repo CI script tests.
"""

import os
import subprocess
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
PROBE = SCRIPTS / "gh-release-exists.sh"
PUBLISH = SCRIPTS / "create-or-update-release.sh"


def _fake_gh(tmp_path, *, view_exit, view_stderr, view_stderr_after=None):
    """Install a fake `gh` on PATH; return (bin_dir, calls_log).

    `view_stderr_after` makes the first `view` attempt fail and later ones
    behave as `view_exit`/`view_stderr` describe, so retry can be exercised.
    """
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir(exist_ok=True)
    calls = tmp_path / "calls.log"
    attempts = tmp_path / "attempts"

    first_branch = ""
    if view_stderr_after is not None:
        first_branch = f"""
      n=$(cat "{attempts}" 2>/dev/null || echo 0)
      n=$((n+1)); echo "$n" > "{attempts}"
      if [ "$n" -eq 1 ]; then
        printf '%s\\n' {view_stderr_after!r} >&2
        exit 1
      fi
"""

    (bin_dir / "gh").write_text(
        f"""#!/usr/bin/env bash
echo "$*" >> "{calls}"
if [ "$1" = release ] && [ "$2" = view ]; then
{first_branch}
  printf '%s' {view_stderr!r} >&2
  exit {view_exit}
fi
exit 0
"""
    )
    (bin_dir / "gh").chmod(0o755)
    return bin_dir, calls


def _run(script, args, bin_dir, expect_ok=True):
    env = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}")
    proc = subprocess.run(
        ["bash", str(script), *args],
        capture_output=True, text=True, env=env, timeout=60,
    )
    if expect_ok:
        assert proc.returncode == 0, f"expected success, got {proc.returncode}\n{proc.stderr}"
    return proc


def _notes(tmp_path):
    p = tmp_path / "notes.md"
    p.write_text("### Changelog:\n\n- something\n")
    return p


# --- the probe's three outcomes -------------------------------------------------

def test_probe_reports_exists_when_the_release_is_there(tmp_path):
    bin_dir, _ = _fake_gh(tmp_path, view_exit=0, view_stderr="")
    assert _run(PROBE, ["3.3.1"], bin_dir).stdout.strip() == "exists"


def test_probe_reports_absent_only_on_the_recognised_not_found_message(tmp_path):
    bin_dir, _ = _fake_gh(tmp_path, view_exit=1, view_stderr="release not found")
    assert _run(PROBE, ["9.9.9"], bin_dir).stdout.strip() == "absent"


def test_probe_fails_loudly_when_the_api_does_not_answer(tmp_path):
    """The regression. An unrecognised error must not read as 'absent'."""
    bin_dir, _ = _fake_gh(tmp_path, view_exit=1, view_stderr="HTTP 503: Service Unavailable")
    proc = _run(PROBE, ["3.3.1", "2"], bin_dir, expect_ok=False)
    assert proc.returncode != 0
    assert "absent" not in proc.stdout
    assert "could not determine" in proc.stderr
    # The discarded evidence is now reported.
    assert "503" in proc.stderr


def test_probe_retries_a_transient_error_then_succeeds(tmp_path):
    bin_dir, _ = _fake_gh(
        tmp_path, view_exit=0, view_stderr="",
        view_stderr_after="HTTP 502: Bad Gateway",
    )
    assert _run(PROBE, ["3.3.1", "3"], bin_dir).stdout.strip() == "exists"


# --- what the publisher does with each outcome ---------------------------------

def test_publish_edits_when_the_release_already_exists(tmp_path):
    bin_dir, calls = _fake_gh(tmp_path, view_exit=0, view_stderr="")
    _run(PUBLISH, ["3.3.1", str(_notes(tmp_path))], bin_dir)
    log = calls.read_text()
    assert "release edit 3.3.1" in log
    assert "release create" not in log


def test_publish_creates_when_there_is_no_release(tmp_path):
    bin_dir, calls = _fake_gh(tmp_path, view_exit=1, view_stderr="release not found")
    _run(PUBLISH, ["3.4.0", str(_notes(tmp_path))], bin_dir)
    log = calls.read_text()
    assert "release create 3.4.0" in log
    assert "release edit" not in log


def test_publish_creates_nothing_when_existence_is_unknown(tmp_path):
    """The shipped failure: a transient error must not become a create."""
    bin_dir, calls = _fake_gh(tmp_path, view_exit=1, view_stderr="HTTP 503: Service Unavailable")
    proc = _run(PUBLISH, ["3.3.1", str(_notes(tmp_path))], bin_dir, expect_ok=False)
    assert proc.returncode != 0
    log = calls.read_text()
    assert "release create" not in log, "a release was created on an unknown"
    assert "release edit" not in log


def test_publish_refuses_a_missing_notes_file(tmp_path):
    bin_dir, calls = _fake_gh(tmp_path, view_exit=0, view_stderr="")
    proc = _run(PUBLISH, ["3.3.1", str(tmp_path / "nope.md")], bin_dir, expect_ok=False)
    assert proc.returncode != 0
    assert not calls.exists() or "release" not in calls.read_text()
