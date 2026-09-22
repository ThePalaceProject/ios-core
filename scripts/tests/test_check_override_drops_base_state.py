"""Tests for check-override-drops-base-state.py.

Every violating fixture is paired with a near-identical CLEAN one. A detector
validated only against violations gets tuned to keep matching them, which is how a
check ends up firing on its own motivating example and nothing else.
"""
import subprocess
import sys
import textwrap
import pathlib

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "check-override-drops-base-state.py"
SCAN_SUBDIR = pathlib.Path("ios-audiobooktoolkit/PalaceAudiobookToolkit/Player")

BASE = """\
class BasePlayer {
  var queuedTrackPosition: TrackPosition?
  var unrelated: Int = 0

  var currentTrackPosition: TrackPosition? {
    if let queued = queuedTrackPosition {
      return queued
    }
    return nil
  }

  func playCallback(at position: TrackPosition) {
    queuedTrackPosition = position
    unrelated = 1
  }
}
"""


def run(tmp_path, files, baseline=None):
    root = tmp_path / "repo"
    scan = root / SCAN_SUBDIR
    scan.mkdir(parents=True)
    for name, body in files.items():
        (scan / name).write_text(textwrap.dedent(body))
    # The script reads its baseline from its OWN directory, so point it at a copy.
    scripts = root / "scripts"
    scripts.mkdir()
    local = scripts / SCRIPT.name
    local.write_text(SCRIPT.read_text())
    if baseline is not None:
        (scripts / "override-drops-base-state-baseline.txt").write_text(baseline)
    proc = subprocess.run(
        [sys.executable, str(local), str(root)], capture_output=True, text=True
    )
    return proc.returncode, proc.stdout + proc.stderr


def test_override_that_drops_base_state_is_flagged(tmp_path):
    rc, out = run(tmp_path, {
        "BasePlayer.swift": BASE,
        "LCPPlayer.swift": """\
            class LCPPlayer: BasePlayer {
              override func playCallback(at position: TrackPosition) {
                doSomethingElse()
              }
            }
            """,
    })
    assert rc == 1, out
    assert "queuedTrackPosition" in out
    assert "LCPPlayer.playCallback" in out


def test_override_that_keeps_the_state_is_clean(tmp_path):
    rc, out = run(tmp_path, {
        "BasePlayer.swift": BASE,
        "LCPPlayer.swift": """\
            class LCPPlayer: BasePlayer {
              override func playCallback(at position: TrackPosition) {
                queuedTrackPosition = position
              }
            }
            """,
    })
    assert rc == 0, out


def test_assignment_through_optional_self_counts(tmp_path):
    # The real fix assigns inside an escaping closure as `self?.queuedTrackPosition`.
    # A matcher that only understood bare identifiers would have called it a miss.
    rc, out = run(tmp_path, {
        "BasePlayer.swift": BASE,
        "LCPPlayer.swift": """\
            class LCPPlayer: BasePlayer {
              override func playCallback(at position: TrackPosition) {
                let done = { [weak self] in
                  self?.queuedTrackPosition = nil
                }
                done()
              }
            }
            """,
    })
    assert rc == 0, out


def test_override_that_delegates_to_super_is_clean(tmp_path):
    # Delegation still gets the base's bookkeeping. Without this the check fires on
    # every `super.x()` wrapper and would be tuned away rather than fixed.
    rc, out = run(tmp_path, {
        "BasePlayer.swift": BASE,
        "LCPPlayer.swift": """\
            class LCPPlayer: BasePlayer {
              override func playCallback(at position: TrackPosition) {
                super.playCallback(at: position)
              }
            }
            """,
    })
    assert rc == 0, out


def test_write_only_base_state_is_not_flagged(tmp_path):
    # `unrelated` is assigned by the base method but read nowhere else in the class,
    # so an override that ignores it cannot leave anything stale.
    rc, out = run(tmp_path, {
        "BasePlayer.swift": BASE,
        "LCPPlayer.swift": """\
            class LCPPlayer: BasePlayer {
              override func playCallback(at position: TrackPosition) {
                queuedTrackPosition = position
              }
            }
            """,
    })
    assert rc == 0, out
    assert "unrelated" not in out


def test_escape_hatch_on_the_func_line_suppresses(tmp_path):
    rc, out = run(tmp_path, {
        "BasePlayer.swift": BASE,
        "LCPPlayer.swift": """\
            class LCPPlayer: BasePlayer {
              override func playCallback(at position: TrackPosition) { // no-override-state: streaming owns its own position
                doSomethingElse()
              }
            }
            """,
    })
    assert rc == 0, out


def test_escape_hatch_on_a_preceding_line_does_NOT_suppress(tmp_path):
    # Line-adjacency is the contract. A marker one line up looks applied and is not —
    # the failure mode this repo already wrote down for FLUFF-003.
    rc, out = run(tmp_path, {
        "BasePlayer.swift": BASE,
        "LCPPlayer.swift": """\
            class LCPPlayer: BasePlayer {
              // no-override-state: streaming owns its own position
              override func playCallback(at position: TrackPosition) {
                doSomethingElse()
              }
            }
            """,
    })
    assert rc == 1, out


def test_non_override_method_of_the_same_name_is_ignored(tmp_path):
    rc, out = run(tmp_path, {
        "BasePlayer.swift": BASE,
        "OtherPlayer.swift": """\
            class OtherPlayer {
              func playCallback(at position: TrackPosition) {
                doSomethingElse()
              }
            }
            """,
    })
    assert rc == 0, out


def test_baselined_finding_does_not_fail_but_a_new_one_does(tmp_path):
    files = {
        "BasePlayer.swift": BASE,
        "LCPPlayer.swift": """\
            class LCPPlayer: BasePlayer {
              override func playCallback(at position: TrackPosition) {
                doSomethingElse()
              }
            }
            """,
    }
    rc, out = run(tmp_path, files, baseline="LCPPlayer.playCallback:queuedTrackPosition\n")
    assert rc == 0, out
    assert "1 baselined, 0 new" in out


def test_a_baselined_finding_does_not_mask_a_second_new_one(tmp_path):
    # The test above asserts only the amnesty half. Its name promised both
    # directions and a reviewer caught that it delivered one: a baseline that
    # swallowed every finding once it held ANY entry would have passed it.
    files = {
        "BasePlayer.swift": BASE,
        "LCPPlayer.swift": """\
            class LCPPlayer: BasePlayer {
              override func playCallback(at position: TrackPosition) {
                doSomethingElse()
              }
            }
            """,
        "OtherSub.swift": """\
            class OtherSub: BasePlayer {
              override func playCallback(at position: TrackPosition) {
                doSomethingElseEntirely()
              }
            }
            """,
    }
    rc, out = run(tmp_path, files, baseline="LCPPlayer.playCallback:queuedTrackPosition\n")
    assert rc == 1, out
    assert "OtherSub.playCallback" in out
    assert "LCPPlayer.playCallback" not in out, "the baselined finding must not be re-reported"


def test_super_call_inside_a_comment_does_not_exempt(tmp_path):
    # Comments are stripped before every other textual test but were NOT stripped
    # before the exemption search — an escape hatch nobody wrote, inside the
    # detector built to stop a silent pass.
    rc, out = run(tmp_path, {
        "BasePlayer.swift": BASE,
        "LCPPlayer.swift": """\
            class LCPPlayer: BasePlayer {
              override func playCallback(at position: TrackPosition) {
                // unlike super.playCallback(at:), this one rebuilds the queue
                doSomethingElse()
              }
            }
            """,
    })
    assert rc == 1, out


def test_same_name_overloads_are_keyed_separately(tmp_path):
    # `funcs` keyed on (class, name) collapsed overloads to whichever came last in
    # the file, so an override could be compared against the WRONG base body and
    # silently pass. OpenAccessPlayer really does have two `play` definitions.
    rc, out = run(tmp_path, {
        "BasePlayer.swift": """\
            class BasePlayer {
              var queuedTrackPosition: TrackPosition?

              var currentTrackPosition: TrackPosition? {
                if let queued = queuedTrackPosition { return queued }
                return nil
              }

              func play() {
                doNothingWithState()
              }

              func play(at position: TrackPosition) {
                queuedTrackPosition = position
              }
            }
            """,
        "LCPPlayer.swift": """\
            class LCPPlayer: BasePlayer {
              override func play(at position: TrackPosition) {
                doSomethingElse()
              }
            }
            """,
    })
    assert rc == 1, out
    assert "queuedTrackPosition" in out


def test_stored_property_with_an_initialiser_is_visible(tmp_path):
    # `var isLoaded: Bool = false` was invisible to the first regex, so a whole
    # category of live state went unchecked.
    rc, out = run(tmp_path, {
        "BasePlayer.swift": """\
            class BasePlayer {
              var isLoaded: Bool = false

              func report() -> Bool {
                return isLoaded
              }

              func playCallback(at position: TrackPosition) {
                isLoaded = true
              }
            }
            """,
        "LCPPlayer.swift": """\
            class LCPPlayer: BasePlayer {
              override func playCallback(at position: TrackPosition) {
                doSomethingElse()
              }
            }
            """,
    })
    assert rc == 1, out
    assert "isLoaded" in out


def test_a_baselined_finding_that_stops_firing_fails(tmp_path):
    # The amnesty must not go stale. A fixed entry left in the file is an exemption
    # nobody is watching.
    files = {
        "BasePlayer.swift": BASE,
        "LCPPlayer.swift": """\
            class LCPPlayer: BasePlayer {
              override func playCallback(at position: TrackPosition) {
                queuedTrackPosition = position
              }
            }
            """,
    }
    rc, out = run(tmp_path, files, baseline="LCPPlayer.playCallback:queuedTrackPosition\n")
    assert rc == 1, out
    assert "no longer fires" in out


def test_absent_scan_root_says_SKIP_loudly_not_OK(tmp_path):
    # An unchecked-out submodule must never render as a clean run — "a gate that
    # cannot fail reports a pass".
    root = tmp_path / "bare"
    root.mkdir()
    proc = subprocess.run([sys.executable, str(SCRIPT), str(root)],
                          capture_output=True, text=True)
    assert proc.returncode == 0
    assert "SKIP" in proc.stdout
    assert "NOT a pass" in proc.stdout
