#!/usr/bin/env bash
# test_pre_commit_phase35_detectors.sh
#
# Fixture-driven test for scripts/pre-commit-phase35-detectors.sh —
# specifically pins the architect-reviewer-caught exit-code-capture bug
# (rev_742175c0, 2026-06-05). The bug: `OUT=$(... || true); EXIT=$?` always
# reads EXIT=0 because `|| true` short-circuits before $? is read. The
# fix: `OUT=$(...) && EXIT=0 || EXIT=$?` captures the python exit cleanly.
#
# This test exercises a known-violation diff through the actual hook and
# asserts non-zero exit. Without the fix, the hook silently passes
# violations (logs to stderr, returns 0).

set -eu

# git exports GIT_DIR/GIT_WORK_TREE/etc. into hook environments; run under a hook,
# this test's throwaway-repo git commands would operate on the real repo. Scrub them
# so `git init`/`git add`/`git commit` in $TMPDIR stay isolated.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR GIT_PREFIX GIT_EXEC_PATH || true

# Locate this test + the hook in the worktree
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$TEST_DIR/../.." && pwd)
HOOK="$REPO_ROOT/scripts/pre-commit-phase35-detectors.sh"

if [ ! -f "$HOOK" ]; then
  echo "FAIL: hook not at $HOOK"
  exit 2
fi

# --- Test fixture: temp repo with a violation staged ---
TMPDIR=$(mktemp -d -t phase35-hook-test.XXXX)
trap "rm -rf $TMPDIR" EXIT

cd "$TMPDIR"
git init -q
# The hook bails out early if it doesn't see CLAUDE.md + Palace/ — fake those.
mkdir Palace
touch CLAUDE.md
git add CLAUDE.md
# Need at least one commit so git diff --cached has a base.
git -c user.email=t@t -c user.name=t commit -q -m "init"

# Stage a violation that the foreign-host-401 detector catches:
# statusCode == 401 + markCredentialsStale, no authSurfaceHosts reference.
cat > Palace/Violation.swift <<'EOF'
import Foundation

class Violation {
    func handle(response: HTTPURLResponse, account: TPPUserAccount) -> Bool {
        if response.statusCode == 401 {
            account.markCredentialsStale()
            return true
        }
        return false
    }
}
EOF
git add Palace/Violation.swift

# Build the JSON input the hook expects (tool_input.command containing "git commit").
JSON_INPUT='{"tool_input":{"command":"git commit -m \"test\""}}'

# Run the hook against this fixture. Need to symlink to the actual detectors
# under $REPO_ROOT/scripts/ so the hook can find them.
ln -s "$REPO_ROOT/scripts" "$TMPDIR/scripts"

# === Run + assert ===
set +e
HOOK_OUT=$(echo "$JSON_INPUT" | bash "$HOOK" 2>&1)
HOOK_EXIT=$?
set -e

# --- Assert 1: non-zero exit when a block-mode violation is staged ---
if [ "$HOOK_EXIT" -eq 0 ]; then
  echo "FAIL: hook returned exit 0 for a known violation — exit-code-capture bug"
  echo "  Architect-flagged bug pattern (rev_742175c0): OUT=\$(... || true); EXIT=\$?"
  echo "  Hook output was:"
  echo "$HOOK_OUT" | sed 's/^/    /'
  exit 1
fi

# --- Assert 2: hook output mentions the detector that fired ---
if ! echo "$HOOK_OUT" | grep -q "FOREIGN_HOST_401_SCOPING\|foreign-host-401-scoping"; then
  echo "FAIL: hook exited non-zero but didn't identify the firing detector"
  echo "$HOOK_OUT" | sed 's/^/    /'
  exit 1
fi

# --- Assert 3: bypass envvar honored ---
set +e
BYPASS_OUT=$(echo "$JSON_INPUT" | SKIP_PHASE35_DETECTORS=1 bash "$HOOK" 2>&1)
BYPASS_EXIT=$?
set -e
if [ "$BYPASS_EXIT" -ne 0 ]; then
  echo "FAIL: SKIP_PHASE35_DETECTORS=1 bypass did not let the hook pass"
  echo "$BYPASS_OUT" | sed 's/^/    /'
  exit 1
fi

# --- Assert 4: per-detector bypass envvar honored ---
set +e
PERDET_OUT=$(echo "$JSON_INPUT" | SKIP_PHASE35_FOREIGN_HOST_401_SCOPING=1 bash "$HOOK" 2>&1)
PERDET_EXIT=$?
set -e
# Other detectors might still block on this fixture (unlikely but possible);
# the assertion is just that the foreign-host detector ITSELF was skipped.
if echo "$PERDET_OUT" | grep -q "FOREIGN_HOST_401_SCOPING.*BLOCK"; then
  echo "FAIL: per-detector bypass envvar did not skip the named detector"
  echo "$PERDET_OUT" | sed 's/^/    /'
  exit 1
fi

# --- Assert 5: a CLEAN (non-violating) diff passes ALL detectors with exit 0 ---
# Regression guard for the LCP-detector wiring bug (2026-06-08). The hook
# passed `--diff` to check-lcp-acquisition-recursive.py, which only accepts
# `--scan` (tree-scan). The argparse error (exit 2) was treated as a block —
# so the hook would have blocked EVERY commit, even clean ones, regardless of
# content. Asserts 1-4 only ever staged a violating diff, so they stayed green
# while the hook was broken. A clean diff MUST pass: any detector invoked with
# an interface it rejects errors out and reddens this assertion.
git rm -q --cached Palace/Violation.swift
rm -f Palace/Violation.swift
cat > Palace/Clean.swift <<'EOF'
import Foundation

struct Clean {
    func add(_ a: Int, _ b: Int) -> Int { a + b }
}
EOF
git add Palace/Clean.swift
set +e
CLEAN_OUT=$(echo "$JSON_INPUT" | bash "$HOOK" 2>&1)
CLEAN_EXIT=$?
set -e
if [ "$CLEAN_EXIT" -ne 0 ]; then
  echo "FAIL: hook blocked a CLEAN diff (exit $CLEAN_EXIT) — a detector spuriously errored."
  echo "  Regression guard: a wired detector invoked with an interface it rejects"
  echo "  (e.g. --diff passed to a scan-only detector) errors → spurious block on every commit."
  echo "$CLEAN_OUT" | sed 's/^/    /'
  exit 1
fi

# --- Assert 6: UNSYNCHRONIZED_SENDABLE_MOCK detector fires on its fixture ---
# (fix/sync-mock-race-segv-bookmark-keys) An @unchecked Sendable mock with
# unsynchronized state + a test file driving it via DispatchQueue.global must
# block; removing the concurrent usage must pass again (detector-level
# clean-pass, complementing Assert 5's no-PalaceTests-tree pass).
mkdir -p PalaceTests/Mocks
cat > PalaceTests/Mocks/RacyMock.swift <<'EOF'
import Foundation
class RacyMock: NSObject, @unchecked Sendable {
    var registry = [String: Int]()
    func set(_ v: Int, for k: String) { registry[k] = v }
}
EOF
cat > PalaceTests/RacyMockTests.swift <<'EOF'
import XCTest
final class RacyMockTests: XCTestCase {
    func testHammer() {
        let mock = RacyMock()
        for i in 0..<100 { DispatchQueue.global().async { mock.set(i, for: "k") } }
    }
}
EOF
git add PalaceTests
set +e
MOCK_OUT=$(echo "$JSON_INPUT" | bash "$HOOK" 2>&1)
MOCK_EXIT=$?
set -e
if [ "$MOCK_EXIT" -eq 0 ] || ! echo "$MOCK_OUT" | grep -q "UNSYNCHRONIZED_SENDABLE_MOCK\|unsynchronized-sendable-mock"; then
  echo "FAIL: unsynchronized-sendable-mock violation did not block (exit $MOCK_EXIT)"
  echo "$MOCK_OUT" | sed 's/^/    /'
  exit 1
fi
# Clean path: same mock, concurrent usage removed → must pass.
cat > PalaceTests/RacyMockTests.swift <<'EOF'
import XCTest
final class RacyMockTests: XCTestCase {
    func testSequential() {
        let mock = RacyMock()
        mock.set(1, for: "k")
    }
}
EOF
git add PalaceTests
set +e
MOCK_CLEAN_OUT=$(echo "$JSON_INPUT" | bash "$HOOK" 2>&1)
MOCK_CLEAN_EXIT=$?
set -e
if [ "$MOCK_CLEAN_EXIT" -ne 0 ]; then
  echo "FAIL: latent (non-concurrent) unsynchronized mock spuriously blocked (exit $MOCK_CLEAN_EXIT)"
  echo "$MOCK_CLEAN_OUT" | sed 's/^/    /'
  exit 1
fi

# --- Assert 7: AUTH_CHALLENGE_ASYNC_FORM detector fires on its fixture ---
# (PP-4895) An authentication-challenge delegate callback written in the
# completion-handler form must block: the Xcode 26.2 ClangImporter can leave it
# unmatched, which strips it from the ObjC runtime, and URLSession then never
# calls it — the challenge goes unanswered with no error. Rewriting it in the
# SDK's async spelling must pass again.
git rm -q -r --cached PalaceTests
rm -rf PalaceTests
cat > Palace/ChallengeDelegate.swift <<'EOF'
import Foundation
final class ChallengeDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(.performDefaultHandling, nil)
    }
}
EOF
git add Palace/ChallengeDelegate.swift
set +e
ACF_OUT=$(echo "$JSON_INPUT" | bash "$HOOK" 2>&1)
ACF_EXIT=$?
set -e
if [ "$ACF_EXIT" -eq 0 ] || ! echo "$ACF_OUT" | grep -q "AUTH_CHALLENGE_ASYNC_FORM\|auth-challenge-async-form"; then
  echo "FAIL: completion-handler-form auth-challenge callback did not block (exit $ACF_EXIT)"
  echo "$ACF_OUT" | sed 's/^/    /'
  exit 1
fi
# Clean path: the same callback in the async spelling → must pass.
cat > Palace/ChallengeDelegate.swift <<'EOF'
import Foundation
final class ChallengeDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge)
    async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        (.performDefaultHandling, nil)
    }
}
EOF
git add Palace/ChallengeDelegate.swift
set +e
ACF_CLEAN_OUT=$(echo "$JSON_INPUT" | bash "$HOOK" 2>&1)
ACF_CLEAN_EXIT=$?
set -e
if [ "$ACF_CLEAN_EXIT" -ne 0 ]; then
  echo "FAIL: async-form auth-challenge callback spuriously blocked (exit $ACF_CLEAN_EXIT)"
  echo "$ACF_CLEAN_OUT" | sed 's/^/    /'
  exit 1
fi

echo "PASS: 7 assertions — hook blocks violations, identifies detector, honors both"
echo "      bypass envvars, passes a clean diff (no detector spuriously blocks),"
echo "      and the unsynchronized-sendable-mock + auth-challenge-async-form"
echo "      detectors each fire on a violation and clean-pass on the fix."
exit 0
