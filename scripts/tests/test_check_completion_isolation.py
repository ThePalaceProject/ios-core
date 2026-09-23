#!/usr/bin/env python3
"""Pytest for scripts/check-completion-isolation.py.

The other detector that shipped without a test. It flags a completion handler
invoked from a Task that does NOT inherit main-actor isolation — the PP-4955
shape, where a @MainActor caller's closure fails Swift's isolation assertion and
the process is killed outright (scrubbing a DRM audiobook terminated the app).

The subtlety this file exists to pin: `Task { }` INHERITS the enclosing
isolation, so the same three lines are a crash inside a plain class and correct
inside a @MainActor one. A detector that grepped for `Task` would flag
CarPlayAudiobookBridge and LibraryService, both of which are fine. So the
false-positive tests below are not padding — they are the whole reason the
detector reads context instead of matching text.
"""
from __future__ import annotations

import importlib.util
import re
import subprocess
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "check-completion-isolation.py"
WORKFLOW = REPO / ".github" / "workflows" / "tooling-checks.yml"

_spec = importlib.util.spec_from_file_location("check_completion_isolation", SCRIPT)
cci = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cci)


def _run(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, str(SCRIPT), *args],
                          capture_output=True, text=True, cwd=str(REPO), timeout=120)


def _swift(tmp_path: Path, name: str, body: str) -> Path:
    p = tmp_path / name
    p.write_text(body, encoding="utf-8")
    return p


# --- the crash shape --------------------------------------------------------

PLAIN_CLASS = """import Foundation

final class DefaultAudiobookManager {
  func seekWithSlider(value: Double, completion: @escaping (Double) -> Void) {
    Task {
      let result = await self.seek(value)
      completion(result)
    }
  }
}
"""


def test_flags_completion_from_a_task_in_a_non_isolated_class(tmp_path):
    rc = _run(str(_swift(tmp_path, "Manager.swift", PLAIN_CLASS)))
    assert rc.returncode == 1, rc.stdout + rc.stderr
    assert "seekWithSlider" in rc.stdout
    assert "PP-4955" in rc.stdout, "the finding must name the incident it prevents"


def test_flags_task_detached_even_inside_a_main_actor_type(tmp_path):
    """`Task.detached` inherits nothing — isolation of the enclosing type is
    irrelevant, which is exactly the case a context-reading detector could get
    wrong in the safe direction."""
    detached = """import Foundation

@MainActor
final class Bridge {
  func play(completion: @escaping () -> Void) {
    Task.detached {
      completion()
    }
  }
}
"""
    rc = _run(str(_swift(tmp_path, "Bridge.swift", detached)))
    assert rc.returncode == 1, rc.stdout + rc.stderr
    assert "Task.detached" in rc.stdout


def test_flags_callback_and_completion_handler_spellings(tmp_path):
    for ident in ("callback", "completionHandler"):
        src = PLAIN_CLASS.replace("completion", ident)
        rc = _run(str(_swift(tmp_path, f"{ident}.swift", src)))
        assert rc.returncode == 1, f"{ident} not recognised:\n{rc.stdout}"


# --- the shapes that must NOT be flagged ------------------------------------

def test_task_inside_a_main_actor_type_is_not_flagged(tmp_path):
    """`Task { }` inherits the enclosing actor. This is CarPlayAudiobookBridge
    and LibraryService — they look exactly like the crash and are correct."""
    main_actor_type = PLAIN_CLASS.replace(
        "final class DefaultAudiobookManager {",
        "@MainActor\nfinal class DefaultAudiobookManager {")
    rc = _run(str(_swift(tmp_path, "Safe.swift", main_actor_type)))
    assert rc.returncode == 0, rc.stdout + rc.stderr


def test_task_inside_a_main_actor_func_is_not_flagged(tmp_path):
    per_func = """import Foundation

final class Manager {
  @MainActor
  func seek(completion: @escaping () -> Void) {
    Task {
      completion()
    }
  }
}
"""
    rc = _run(str(_swift(tmp_path, "PerFunc.swift", per_func)))
    assert rc.returncode == 0, rc.stdout + rc.stderr


def test_explicit_hop_inside_the_task_is_not_flagged(tmp_path):
    hopped = """import Foundation

final class Manager {
  func seek(completion: @escaping () -> Void) {
    Task {
      await MainActor.run {
        completion()
      }
    }
  }
}
"""
    rc = _run(str(_swift(tmp_path, "Hopped.swift", hopped)))
    assert rc.returncode == 0, rc.stdout + rc.stderr


def test_task_pinned_to_main_at_the_declaration_is_not_flagged(tmp_path):
    pinned = """import Foundation

final class Manager {
  func seek(completion: @escaping () -> Void) {
    Task { @MainActor in
      completion()
    }
  }
}
"""
    rc = _run(str(_swift(tmp_path, "Pinned.swift", pinned)))
    assert rc.returncode == 0, rc.stdout + rc.stderr


def test_completion_called_outside_any_task_is_not_flagged(tmp_path):
    synchronous = """import Foundation

final class Manager {
  func seek(completion: @escaping () -> Void) {
    completion()
  }
}
"""
    rc = _run(str(_swift(tmp_path, "Sync.swift", synchronous)))
    assert rc.returncode == 0, rc.stdout + rc.stderr


def test_completion_after_the_task_block_closes_is_not_flagged(tmp_path):
    """Scope tracking: once the Task's brace closes we are back on the caller's
    thread, so the call is not an off-main delivery."""
    after = """import Foundation

final class Manager {
  func seek(completion: @escaping () -> Void) {
    Task {
      await self.work()
    }
    completion()
  }
}
"""
    rc = _run(str(_swift(tmp_path, "After.swift", after)))
    assert rc.returncode == 0, rc.stdout + rc.stderr


# --- the exemption list -----------------------------------------------------

def test_exempt_entries_suppress_the_finding(tmp_path):
    """Every EXEMPT entry was triaged by reading the callers. Prove the
    mechanism works, keyed on the repo-relative path the scanner reports."""
    rel = "Palace/Book/Models/TPPBookRegistry+Extensions.swift"
    assert f"{rel}:syncLocation" in cci.EXEMPT
    src = PLAIN_CLASS.replace("seekWithSlider(value: Double, ", "syncLocation(")
    p = _swift(tmp_path, "Exempt.swift", src)
    assert cci.check_file(str(p), rel) == []
    # The same file under any other path is still a finding.
    assert cci.check_file(str(p), "Palace/Other/Thing.swift")


def test_every_exempt_entry_has_a_reason():
    for key, reason in cci.EXEMPT.items():
        assert ":" in key, f"EXEMPT key must be path:symbol — {key!r}"
        assert len(reason) > 40, f"EXEMPT {key} lacks a triage reason"


# --- CLI + tree + wiring ----------------------------------------------------

def test_rejects_unknown_options(tmp_path):
    rc = _run("--scan", str(tmp_path))
    assert rc.returncode == 2
    assert "unknown option" in rc.stderr


# Known-untriaged sites, as (file, enclosing function) -> count. These are NOT
# exemptions: nobody has read their callers yet, which is the only question that
# decides whether they are defects. They surfaced the moment the TASK pattern
# above learned the `let handle = Task { … }` form — before that the detector was
# structurally blind to them, which is why they were never triaged.
#
# The list is a RATCHET, not a suppression: the test below asserts the tree
# contains EXACTLY these and nothing else, so a NEW off-main completion goes red
# in `pytest scripts/tests/` (which tooling-checks.yml runs as a directory glob)
# while the legacy debt does not block unrelated work. Triage a site, then delete
# its entry here — moving it to EXEMPT with a reason, or fixing it.
KNOWN_UNTRIAGED = {
    ("Palace/Audiobooks/LCP/LCPAudiobooks.swift", "loadContentDictionary"): 6,
    ("Palace/Reader2/Bookmarks/AudiobookBookmarkBusinessLogic.swift",
     "saveListeningPosition"): 5,
}


def _tree_findings() -> dict:
    """{(file, func): count} for the whole tracked Palace/ tree."""
    rc = _run()
    counts: dict = {}
    for line in rc.stdout.splitlines():
        m = re.match(r"\s+(Palace/\S+?):\d+: .*? inside `(\w+)`", line)
        if m:
            counts[(m.group(1), m.group(2))] = counts.get(
                (m.group(1), m.group(2)), 0) + 1
    return counts


def test_no_new_off_main_completion_beyond_the_known_debt():
    """RATCHET. Red if any NEW site appears — that is the gate.

    Deliberately not asserting a clean tree: it is not clean, and pretending
    otherwise is how the detector sat unwired and unnoticed. Deliberately not
    asserting only >= either: an unchanged count is what keeps the debt from
    growing quietly inside the same function.
    """
    found = _tree_findings()
    new = {k: v for k, v in found.items() if k not in KNOWN_UNTRIAGED}
    assert not new, (
        "NEW off-main completion delivery (PP-4955 shape) — a @MainActor "
        f"caller's closure invoked here KILLS the process:\n  {new}\n"
        "Fix it, or triage the callers and add an EXEMPT entry with the reason.")
    grown = {k: (KNOWN_UNTRIAGED[k], v) for k, v in found.items()
             if KNOWN_UNTRIAGED.get(k, 0) < v}
    assert not grown, f"known-untriaged sites grew: {grown}"


def test_the_known_debt_is_real_and_not_a_stale_list():
    """The other direction: if a site was fixed, this list must shrink with it.

    Otherwise the ratchet quietly loosens — the baseline stays wide enough to
    re-admit the defect it was supposed to pin.
    """
    found = _tree_findings()
    stale = [k for k in KNOWN_UNTRIAGED if k not in found]
    assert not stale, (
        f"KNOWN_UNTRIAGED lists sites the detector no longer finds: {stale}. "
        "They were fixed or moved — delete them so the ratchet stays tight.")


def test_wiring_note_matches_reality():
    """This detector is intentionally NOT a tooling-checks.yml step yet.

    Landing it as a workflow step today would fail every PR on 11 pre-existing,
    untriaged sites — the exact "gate that fires on the tree it ships with"
    CLAUDE.md rule 4(c) forbids. The ratchet above is the wiring in the interim:
    it runs inside the pytest directory glob CI already executes. This test
    fails if someone adds the step without first clearing KNOWN_UNTRIAGED.
    """
    wired = "check-completion-isolation.py" in WORKFLOW.read_text(encoding="utf-8")
    if wired:
        assert not KNOWN_UNTRIAGED, (
            "the detector is now a CI step, so the tree must be clean — "
            f"still untriaged: {sorted(KNOWN_UNTRIAGED)}")


@pytest.mark.parametrize("line,matches", [
    ("    Task {", True),
    ("    Task.detached {", True),
    ("    let t = Task {", True),
    ("    Task(priority: .high) {", True),
    ("    // Task { }", False),
    ("    taskManager.run {", False),
])
def test_task_predicate(line, matches):
    assert bool(cci.TASK.match(line)) is matches
