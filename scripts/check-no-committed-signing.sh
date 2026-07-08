#!/bin/bash
# check-no-committed-signing.sh
#
# Repo-wide rule: code-signing info must NOT be committed, and signing must be
# Manual. This blocks a commit/diff that ADDS any of the following to a tracked
# file (project.pbxproj, xcconfig, plist, …):
#
#   - CODE_SIGN_STYLE = Automatic            (repo rule: Manual only — Automatic
#                                             lets Xcode rewrite team/profile into
#                                             the pbxproj on every dev's machine)
#   - DEVELOPMENT_TEAM = <real 10-char id>   (provide locally, not in git; blank
#                                             `DEVELOPMENT_TEAM = ""` is allowed)
#   - PROVISIONING_PROFILE = <uuid>          (per-machine profile UUID — never commit)
#
# Operates on ADDED diff lines (leading '+') so it prevents NEW leaks without
# firing on values already committed (which are cleaned out separately). A
# pre-existing team ID being present is not this gate's concern; a diff that
# (re)introduces or changes one is.
#
# Usage: check-no-committed-signing.sh [<unified-diff-file>|--diff <f>]
#        (default: `git diff --cached`)
# Exit 0 = clean; 1 = signing info found; 2 = usage/error.
#
# Allowlist (optional): OBJC unrelated — NO_SIGNING_ALLOWLIST (default
#   .forgeos/committed-signing-allowlist.txt); one substring per line, '#' comments.

set -uo pipefail

DIFF_FILE=""
case "${1:-}" in
  --diff) DIFF_FILE="${2:-}" ;;
  "" ) : ;;
  * ) DIFF_FILE="$1" ;;
esac

if [ -n "$DIFF_FILE" ]; then
  [ -f "$DIFF_FILE" ] || { echo "[no-signing] no such diff file: $DIFF_FILE"; exit 2; }
  DIFF="$(cat "$DIFF_FILE")"
else
  DIFF="$(git diff --cached 2>/dev/null)"
fi

ALLOW="${NO_SIGNING_ALLOWLIST:-.forgeos/committed-signing-allowlist.txt}"

# PATH-AWARE: only evaluate ADDED lines that belong to a signing-bearing build
# file (project.pbxproj / *.xcconfig / *.entitlements / *.plist). This is what
# keeps the detector from flagging its OWN test fixtures and doc comments, which
# live in scripts/tests/*.sh and this file — a diff of those is not a signing
# leak. awk tracks the current `+++ b/<path>` header; the regex match is done
# after (grep -E supports {N} intervals; POSIX awk may not).
RELEVANT_ADDED="$(printf '%s\n' "$DIFF" | awk '
  /^diff --git / { infile=0; next }
  /^\+\+\+ b\// { f=$0; sub(/^\+\+\+ b\//,"",f);
                  infile = (f ~ /\.(pbxproj|xcconfig|entitlements|plist)$/) ? 1 : 0; next }
  /^\+\+\+/ { next }
  infile==1 && /^\+/ { line=$0; sub(/^\+/,"",line); print line }
')"

# DEVELOPMENT_TEAM: trailing ';' (pbxproj) OR end-of-line (xcconfig has no ';').
FINDINGS="$(printf '%s\n' "$RELEVANT_ADDED" | grep -nE \
  'CODE_SIGN_STYLE[[:space:]]*=[[:space:]]*Automatic|DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*[A-Z0-9]{10}[[:space:]]*(;|$)|PROVISIONING_PROFILE[[:space:]]*=[[:space:]]*"?[0-9a-fA-F]{8}-[0-9a-fA-F-]{27}' \
  2>/dev/null || true)"

# Drop allowlisted lines.
if [ -f "$ALLOW" ] && [ -n "$FINDINGS" ]; then
  while IFS= read -r pat; do
    [ -z "$pat" ] && continue
    case "$pat" in \#*) continue ;; esac
    FINDINGS="$(printf '%s\n' "$FINDINGS" | grep -vF -- "$pat" || true)"
  done < "$ALLOW"
fi

if [ -n "$FINDINGS" ]; then
  echo "[no-signing] BLOCK: this commit adds code-signing info to a tracked file."
  echo "Repo rule: signing must be Manual, and the team ID / provisioning profile must"
  echo "NOT be committed (provide them via a gitignored local xcconfig or CI secret)."
  echo ""
  printf '  %s\n' "$FINDINGS"
  echo ""
  echo "Fix: set CODE_SIGN_STYLE = Manual; set DEVELOPMENT_TEAM = \"\" (or remove it) and"
  echo "     PROVISIONING_PROFILE via a local, gitignored config — not in git."
  echo "If genuinely intentional, add a matching substring to $ALLOW with a reason."
  exit 1
fi

echo "[no-signing] OK: no committed code-signing info / Automatic style added."
exit 0
