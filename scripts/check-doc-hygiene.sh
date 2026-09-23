#!/bin/bash
# check-doc-hygiene.sh
#
# Repo rule: only commit documentation that helps a future engineer/agent rebuild
# the WHAT and WHY of the CODE (architecture ADRs, design rationale, READMEs).
# Do NOT commit process/campaign/generated doc artifacts — they bloat the repo,
# leak agent-orchestration internals, and go stale immediately.
#
# This blocks a commit/diff that ADDS a file matching a denied class:
#
#   - **/.arch/**                          generated architecture IR (regenerable;
#                                          `harness arch` output — not hand-authored why)
#   - .forgeos/swarms/*/transcripts/**     agent run transcripts (process, not code)
#   - .forgeos/swarms/*/HANDOFF.md         campaign handoff scaffolding
#   - .forgeos/swarms/*/plan.md            campaign plan
#   - .forgeos/swarms/*/manifest.yaml      campaign manifest
#   - .forgeos/swarms/*review*.md          raw review dumps (the ADR distills these)
#   - docs/**/*.html                       generated doc renders (regenerable)
#
# It does NOT touch legit docs: docs/architecture/*.md ADRs, **/README.md,
# CLAUDE.md, CONTRIBUTING.md, or inline code docs — those explain the code.
#
# Operates on ADDED files (diff-filter=A) so it prevents NEW cruft without firing
# on artifacts already committed (cleaned out separately).
#
# Usage:
#   check-doc-hygiene.sh                       # staged files (pre-commit)
#   check-doc-hygiene.sh --base <ref>          # files added vs <ref> (CI/PR)
#   check-doc-hygiene.sh --files <a> <b> ...    # explicit file list (tests)
# Exit 0 = clean; 1 = denied doc added; 2 = usage/error.
#
# Allowlist (optional): DOC_HYGIENE_ALLOWLIST (default
#   .forgeos/doc-hygiene-allowlist.txt); one path substring per line, '#' comments —
#   for a deliberately-kept artifact, with a reason.
#
# bash 3.2 compatible (macOS): no `mapfile`, no arrays under `set -u`.

set -uo pipefail

MODE="staged"; BASE=""; ADDED=""
case "${1:-}" in
  --base)  MODE="base"; BASE="${2:-}"; [ -n "$BASE" ] || { echo "[doc-hygiene] --base needs a ref"; exit 2; } ;;
  --files) shift; ADDED="$(printf '%s\n' "$@")"; MODE="files" ;;
  "" ) : ;;
  * ) echo "[doc-hygiene] usage: check-doc-hygiene.sh [--base <ref> | --files <f>...]"; exit 2 ;;
esac

case "$MODE" in
  staged) ADDED="$(git diff --cached --name-only --diff-filter=A 2>/dev/null)" ;;
  base)   ADDED="$(git diff --name-only --diff-filter=A "${BASE}...HEAD" 2>/dev/null)" ;;
esac

ALLOW="${DOC_HYGIENE_ALLOWLIST:-.forgeos/doc-hygiene-allowlist.txt}"

# Denied classes — process/generated docs that do NOT explain the code's what/why.
is_denied() {
  case "$1" in
    # Generated architecture IR (`harness arch` output — regenerable, not hand-authored why).
    */.arch/*|.arch/*)      return 0 ;;
    # ALL swarm-campaign artifacts: transcripts, HANDOFF, plan, manifest, reviews, AND
    # per-workstream contracts. These are the execution plan for one campaign — valuable
    # during the run, history after it. The durable architecture belongs in an ADR under
    # docs/architecture/ and in the code's own doc-comments, not in campaign scaffolding.
    .forgeos/swarms/*)      return 0 ;;
  esac
  # Any generated HTML render under docs/ (case globs don't recurse; match by prefix+suffix).
  case "$1" in docs/*) case "$1" in *.html) return 0 ;; esac ;; esac
  return 1
}

allowlisted() {
  [ -f "$ALLOW" ] || return 1
  while IFS= read -r line; do
    pat="${line%%#*}"                                   # strip inline (and full-line) '#' comment
    pat="$(printf '%s' "$pat" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"  # trim
    [ -z "$pat" ] && continue
    case "$1" in *"$pat"*) return 0 ;; esac
  done < "$ALLOW"
  return 1
}

HITS=""
while IFS= read -r f; do
  [ -z "$f" ] && continue
  if is_denied "$f" && ! allowlisted "$f"; then HITS="${HITS}${f}
"; fi
done <<EOF
${ADDED}
EOF

if [ -n "$HITS" ]; then
  echo "[doc-hygiene] BLOCK: this change adds process/generated doc artifact(s) that do"
  echo "not help rebuild the WHAT/WHY of the code:"
  echo ""
  printf '%s' "$HITS" | sed 's/^/  /'
  echo ""
  echo "Repo rule: commit only docs that explain the code (docs/architecture/*.md ADRs,"
  echo "READMEs, design rationale). Agent transcripts, campaign HANDOFF/plan/manifest/"
  echo "reviews, generated .arch IR, and generated docs/*.html are NOT committed —"
  echo "distill the durable WHY into an ADR instead."
  echo "If genuinely intentional, add a path substring to $ALLOW with a reason."
  exit 1
fi

echo "[doc-hygiene] OK: no process/generated doc artifacts added."
exit 0
