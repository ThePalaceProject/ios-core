#!/usr/bin/env bash
# m1-rigor-lib.sh — shared M1 universal-rigor floor logic.
#
# Sourced by BOTH hook stages; not executable on its own:
#
#   pre-commit  — diff-only gates (blast-radius, adjacency-staleness)
#   commit-msg  — message-dependent gates (contract-reconciliation,
#                 intent-recorded)
#
# Why the split: pre-commit fires BEFORE git writes the new commit message,
# so at pre-commit time COMMIT_EDITMSG still holds the PREVIOUS commit's
# message. Any gate that reads commit-message claims at the pre-commit stage
# validates the wrong commit — a stale "removes X" claim from the last commit
# can block a clean commit (false positive), and a bogus claim in the commit
# being authored sails through (false negative). commit-msg receives the real
# in-progress message file as $1, so message-dependent gates belong there.
#
# Contract for callers:
#   - set M1_HOOK_NAME ("pre-commit" | "commit-msg") before sourcing
#   - call m1_compute_mode after sourcing; it sets PROD_LOC_ADDED,
#     STAGED_CRITICAL, and M1_MODE from the STAGED diff
#   - own the $M1_DIFF tempfile (creation, population, trap cleanup)
#   - count failures and call m1_enforce "$M1_FAIL" at the end

CRITICAL_PATH_REGEX='^(Palace/SignInLogic/|Palace/Packages/PalaceAuth/|Palace/Audiobooks/|Palace/MyBooks/(Download|Borrow|BookReturn)|Palace/Network/TPPNetworkExecutor\.swift|Palace/Network/TPPNetworkResponder\.swift|Palace/Migrations/)'

# Tri-state escalation from the staged diff:
#   <10 added prod-LOC under Palace/                → warn-only
#   ≥10 prod-LOC AND no critical-path file          → block-on-fail
#   ANY critical-path prefix file in the stage      → block-always
m1_compute_mode() {
  # Added prod-LOC under Palace/ in the staged diff (excludes deletions and
  # Tests/). Both pathspecs are needed: `Palace/**/*.swift` matches nested
  # files only — it does NOT match files directly under Palace/ (verified
  # against git 2.x pathspec semantics), so `Palace/*.swift` covers those.
  # `|| true` guards against grep's nonzero-on-no-match exit under `set -e`
  # (the pipeline ran fine but grep returned 1).
  PROD_LOC_ADDED=$( { git diff --cached --numstat -- 'Palace/*.swift' 'Palace/**/*.swift' 2>/dev/null || true; } \
    | { grep -v '/Tests/' || true; } \
    | awk 'BEGIN{s=0} $1 ~ /^[0-9]+$/ {s+=$1} END{print s+0}')

  STAGED_CRITICAL=$( { git diff --cached --name-only --diff-filter=AM 2>/dev/null || true; } \
    | grep -E "$CRITICAL_PATH_REGEX" || true)

  if [[ -n "$STAGED_CRITICAL" ]]; then
    M1_MODE="block-always"
  elif [[ "$PROD_LOC_ADDED" -ge 10 ]]; then
    M1_MODE="block-on-fail"
  else
    M1_MODE="warn-only"
  fi
}

# run_m1_check <name> <script-relpath> [extra script flags...]
# Runs a check-*.py against $M1_DIFF; extra flags (e.g. --commit-msg <file>)
# pass through to the script. Returns the script's pass/fail.
run_m1_check() {
  local name="$1" script="$2"
  shift 2
  local out exit_code=0
  if [[ ! -f "$REPO_ROOT_M1/$script" ]]; then
    echo "  $M1_HOOK_NAME M1: $name — script missing, skipping" >&2
    return 0
  fi
  out=$(python3 "$REPO_ROOT_M1/$script" --diff "$M1_DIFF" "$@" --quiet 2>&1) || exit_code=$?
  if [[ "$exit_code" -ne 0 ]]; then
    echo "  $M1_HOOK_NAME M1: $name FAIL — $(echo "$out" | head -3 | tr '\n' ' ')" >&2
    return 1
  fi
  return 0
}

# m1_enforce <fail-count> — exits 1 when the tri-state mode says block.
m1_enforce() {
  local fail_count="$1"
  [[ "$fail_count" -gt 0 ]] || return 0
  case "$M1_MODE" in
    block-always)
      cat >&2 <<EOF

ERROR: $M1_HOOK_NAME M1 floor — staged diff touches critical-path files; $fail_count universal-rigor check(s) FAILED.

Critical-path file(s) staged:
$(echo "$STAGED_CRITICAL" | sed 's/^/  - /')

Fix the failures above, or — for an emergency commit — use \`git commit --no-verify\` and include a rationale stanza in the commit body.
EOF
      exit 1
      ;;
    block-on-fail)
      cat >&2 <<EOF

ERROR: $M1_HOOK_NAME M1 floor — $PROD_LOC_ADDED prod-LOC staged (≥10); $fail_count universal-rigor check(s) FAILED.

Fix the failures above, or — for an emergency commit — use \`git commit --no-verify\` and include a rationale stanza in the commit body.
EOF
      exit 1
      ;;
    warn-only)
      echo "  $M1_HOOK_NAME M1: $fail_count check(s) failed (warn-only — <10 prod-LOC, non-critical)" >&2
      ;;
  esac
}
