#!/usr/bin/env bash
# test_verify_pr_ratchet_wiring.sh
#
# Pins the WIRING of four detectors into scripts/verify-pr.sh:
#
#   check-appcontainer-locator-count.sh   (whole-tree, baseline)
#   check-godclass-loc-freeze.sh          (whole-tree, baseline)
#   check-shared-read-count.sh            (whole-tree, baseline)
#   check-completion-isolation.py         (diff-scoped, file paths)
#   check-playback-ui-latch.py            (whole-tree, optional root arg)
#   check-override-drops-base-state.py    (whole-tree, baselined, optional root arg)
#
# WHY THIS TEST EXISTS. All four shipped with baselines and pytests and were
# invoked by NOTHING — a 2026-08-20 audit found them reachable from no hook, no
# workflow, and no script. Their pytests passed the whole time, because a
# detector's own unit tests say nothing about whether anything calls it. This
# test asserts the call site, not the detector.
#
# It also pins the INTERFACE each one is called with, which is the failure mode
# CLAUDE.md rule 4 names: a scan-only detector invoked with `--diff` is invisible
# to a fixture that only ever stages a violation. So every case below asserts the
# CLEAN path exits 0 as well as the violating path exiting non-zero.

set -eu

unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR GIT_PREFIX GIT_EXEC_PATH || true

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$TEST_DIR/../.." && pwd)
VERIFY="$REPO_ROOT/scripts/verify-pr.sh"

fail() { echo "FAIL: $*"; exit 1; }
pass() { echo "  ok — $*"; }

[ -f "$VERIFY" ] || fail "verify-pr.sh not at $VERIFY"

# ---------------------------------------------------------------------------
# 1. The wiring exists at all.
# ---------------------------------------------------------------------------
echo "1. detectors referenced by verify-pr.sh"
for d in check-appcontainer-locator-count.sh \
         check-godclass-loc-freeze.sh \
         check-shared-read-count.sh \
         check-completion-isolation.py \
         check-playback-ui-latch.py \
         check-override-drops-base-state.py; do
  grep -qF "$d" "$VERIFY" || fail "$d is not referenced by verify-pr.sh (orphaned again)"
  pass "$d is wired"
done

# The record() keys must exist too — a detector can be mentioned in a comment
# while its block is unreachable. Ratchet detectors trip on comment mentions
# (memory `ratchet-detectors-count-comment-mentions`), so assert the real keys.
for key in '"decomposition_ratchets"' '"completion_isolation"' '"playback_ui_latch"' '"override_base_state"'; do
  grep -qF "record $key" "$VERIFY" || fail "no record() call for $key in verify-pr.sh"
  pass "record() key $key present"
done

# ---------------------------------------------------------------------------
# 2. CLEAN PATH — the three whole-tree ratchets must pass on the real tree with
#    the exact interface verify-pr.sh uses (no arguments). If one of these ever
#    needs a flag, this catches the mismatch before it lands as a false block.
# ---------------------------------------------------------------------------
echo "2. clean path — whole-tree ratchets, invoked with no arguments"
for r in check-appcontainer-locator-count.sh \
         check-godclass-loc-freeze.sh \
         check-shared-read-count.sh; do
  [ -f "$REPO_ROOT/scripts/$r" ] || fail "$r missing"
  if ( cd "$REPO_ROOT" && bash "scripts/$r" >/dev/null 2>&1 ); then
    pass "$r exits 0 at baseline"
  else
    fail "$r exits non-zero on the current tree — verify-pr.sh would block every PR. Either the tree regressed past its baseline or the baseline needs re-committing."
  fi
done

# ---------------------------------------------------------------------------
# 3. completion-isolation is DIFF-SCOPED. Two assertions, and the clean one
#    matters more: verify-pr.sh passes file paths, so a build that only ever
#    checked the violating case would not notice the detector rejecting the
#    argument form entirely.
# ---------------------------------------------------------------------------
echo "3. completion-isolation — file-path interface, both directions"
CI="$REPO_ROOT/scripts/check-completion-isolation.py"
[ -f "$CI" ] || fail "check-completion-isolation.py missing"

TMPDIR=$(mktemp -d -t ci-wiring.XXXX)
trap 'rm -rf "$TMPDIR"' EXIT

# 3a. CLEAN — a bare Task inside a @MainActor type inherits main isolation, so
#     calling the completion from it is correct and must NOT be flagged.
cat > "$TMPDIR/Clean.swift" <<'EOF'
import Foundation

@MainActor
final class CleanExample {
    func load(completion: @escaping (String?) -> Void) {
        Task {
            let value = await fetch()
            completion(value)
        }
    }

    private func fetch() async -> String? { nil }
}
EOF

if python3 "$CI" "$TMPDIR/Clean.swift" >/dev/null 2>&1; then
  pass "clean file (Task inside @MainActor type) exits 0"
else
  fail "clean file was flagged — false positive; verify-pr.sh would block correct code"
fi

# 3b. VIOLATION — the same shape in a plain class inherits nothing, lands on the
#     cooperative executor, and traps a @MainActor caller's closure (PP-4955).
cat > "$TMPDIR/Violation.swift" <<'EOF'
import Foundation

final class ViolationExample {
    func load(completion: @escaping (String?) -> Void) {
        Task {
            let value = await fetch()
            completion(value)
        }
    }

    private func fetch() async -> String? { nil }
}
EOF

if python3 "$CI" "$TMPDIR/Violation.swift" >/dev/null 2>&1; then
  fail "off-main completion in a plain class was NOT flagged — the detector is wired but toothless"
else
  pass "off-main completion in a plain class exits non-zero"
fi

# 3c. Mixed batch — verify-pr.sh passes ALL changed Swift files at once. One bad
#     file among good ones must still fail the batch.
if python3 "$CI" "$TMPDIR/Clean.swift" "$TMPDIR/Violation.swift" >/dev/null 2>&1; then
  fail "mixed batch passed — a violation is masked when batched with clean files"
else
  pass "mixed batch exits non-zero"
fi

# ---------------------------------------------------------------------------
# 3d. playback-ui-latch is WHOLE-TREE and takes an optional ROOT, not file paths.
#     verify-pr.sh calls it with no arguments, so the clean assertion below uses
#     exactly that form — a detector that silently required a `--diff` it never
#     receives would look wired and catch nothing.
# ---------------------------------------------------------------------------
echo "3d. playback-ui-latch — no-argument whole-tree interface, both directions"
PL="$REPO_ROOT/scripts/check-playback-ui-latch.py"
[ -f "$PL" ] || fail "check-playback-ui-latch.py missing"

if ( cd "$REPO_ROOT" && python3 "$PL" >/dev/null 2>&1 ); then
  pass "no-argument run exits 0 on the current tree"
else
  fail "check-playback-ui-latch.py exits non-zero on the current tree with the interface verify-pr.sh uses — it would block every PR."
fi

# A violating predicate under a throwaway root: a blocking UI state derived from
# a live readiness signal with no hasStartedPlayback latch (PP-5205).
mkdir -p "$TMPDIR/root/Palace/Fake"
cat > "$TMPDIR/root/Palace/Fake/Overlay.swift" <<'EOF'
import Foundation

enum FakeOverlayState { case hidden, spinner }

enum FakeOverlayPolicy {
    static func overlayState(
        isLoaded: Bool,
        isDownloading: Bool
    ) -> FakeOverlayState {
        isLoaded ? .hidden : .spinner
    }
}
EOF

if python3 "$PL" "$TMPDIR/root" >/dev/null 2>&1; then
  fail "an unlatched blocking overlay predicate was NOT flagged — the detector is wired but toothless"
else
  pass "unlatched blocking overlay predicate exits non-zero"
fi

# ---------------------------------------------------------------------------
# 3e. override-drops-base-state is WHOLE-TREE with an optional root and a keyed
#     BASELINE. Three assertions, because this one has a third failure mode the
#     others do not: a baselined entry that stops firing must fail, or the amnesty
#     becomes a permanent exemption list nobody re-reads.
# ---------------------------------------------------------------------------
echo "3e. override-drops-base-state — no-argument run, violation, and stale baseline"
OB="$REPO_ROOT/scripts/check-override-drops-base-state.py"
[ -f "$OB" ] || fail "check-override-drops-base-state.py missing"

if ( cd "$REPO_ROOT" && python3 "$OB" >/dev/null 2>&1 ); then
  pass "no-argument run exits 0 on the current tree"
else
  fail "check-override-drops-base-state.py exits non-zero on the current tree with the interface verify-pr.sh uses — it would block every PR."
fi

OBROOT="$TMPDIR/obroot"
mkdir -p "$OBROOT/ios-audiobooktoolkit/PalaceAudiobookToolkit/Player" "$OBROOT/scripts"
cp "$OB" "$OBROOT/scripts/"
cat > "$OBROOT/ios-audiobooktoolkit/PalaceAudiobookToolkit/Player/BasePlayer.swift" <<'EOF'
class BasePlayer {
  var queuedTrackPosition: TrackPosition?

  var currentTrackPosition: TrackPosition? {
    if let queued = queuedTrackPosition { return queued }
    return nil
  }

  func playCallback(at position: TrackPosition) {
    queuedTrackPosition = position
  }
}
EOF
cat > "$OBROOT/ios-audiobooktoolkit/PalaceAudiobookToolkit/Player/SubPlayer.swift" <<'EOF'
class SubPlayer: BasePlayer {
  override func playCallback(at position: TrackPosition) {
    doSomethingElse()
  }
}
EOF

OB_RC=0
python3 "$OBROOT/scripts/$(basename "$OB")" "$OBROOT" >/dev/null 2>&1 || OB_RC=$?
if [ "$OB_RC" -eq 1 ]; then
  pass "an override that drops live base state exits non-zero"
else
  fail "an override that drops live base state exited $OB_RC, not 1 — the detector is wired but toothless"
fi

# Baseline the finding, then FIX it: the entry is now stale and must fail.
printf '%s\n' "SubPlayer.playCallback:queuedTrackPosition" > "$OBROOT/scripts/override-drops-base-state-baseline.txt"
cat > "$OBROOT/ios-audiobooktoolkit/PalaceAudiobookToolkit/Player/SubPlayer.swift" <<'EOF'
class SubPlayer: BasePlayer {
  override func playCallback(at position: TrackPosition) {
    queuedTrackPosition = position
  }
}
EOF
OB_RC=0
python3 "$OBROOT/scripts/$(basename "$OB")" "$OBROOT" >/dev/null 2>&1 || OB_RC=$?
if [ "$OB_RC" -eq 1 ]; then
  pass "a baselined finding that stops firing exits non-zero (the amnesty cannot go stale)"
else
  fail "a resolved baseline entry exited $OB_RC, not 1 — the baseline can rot into a permanent exemption"
fi

# ---------------------------------------------------------------------------
# 4. verify-pr.sh still parses.
# ---------------------------------------------------------------------------
# NOTE: the aggregation's BEHAVIOUR is asserted in
# test_ratchet_aggregation_behaviour.sh, not here. A previous version of this
# file asserted it by grepping this script's own source text, and two reviewers
# between them walked through that seven different ways — every edit left the
# searched-for strings in place while making the branch unreachable. One was
# piping the ratchet into `head` so the exit status read came from `head`, a
# trap already written down in this repo. A check that reads source text cannot
# tell whether the code runs.
echo "4. verify-pr.sh syntax"
bash -n "$VERIFY" || fail "verify-pr.sh does not parse"
pass "bash -n clean"

# ---------------------------------------------------------------------------
# 5. `--base <ref>` is PARSED, not swallowed by the catch-all.
#
#    The arg loop ends in `*) shift ;;`, so an unrecognised flag is silently
#    dropped — a caller who passes `--base` at a branch off a release line would
#    get the develop-based diff anyway, and every diff-scoped gate would judge
#    the wrong range while reporting a clean run. The unresolvable-ref arm exits
#    2 before any build, which is what makes this assertable cheaply: if the flag
#    were being dropped, the run would proceed instead of exiting 2.
# ---------------------------------------------------------------------------
echo "5. --base is parsed"
# `set -e` is on: a bare failing subshell aborts this script before the status
# can be read, which looked exactly like the assertion passing.
BASE_RC=0
( cd "$REPO_ROOT" && bash "$VERIFY" --base definitely-not-a-ref >/dev/null 2>&1 ) || BASE_RC=$?
if [ "$BASE_RC" -eq 2 ]; then
  pass "--base with an unresolvable ref exits 2 (flag reached the parser)"
else
  fail "--base with an unresolvable ref exited $BASE_RC, not 2 — the flag is being swallowed by the catch-all arm, so a release-branch PR would silently be diffed against develop."
fi

echo
echo "PASS: all six detectors are wired, both directions behave, and --base is parsed."
