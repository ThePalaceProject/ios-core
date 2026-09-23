#!/bin/bash
# check-objc-witness-nearly-matches.sh
#
# Fails when a build log contains an `@objc` optional-protocol "nearly matches"
# warning whose candidate method name EQUALS the requirement name — i.e. true
# witness drift: the method silently is NOT registered as the delegate witness,
# so the callback is skipped at runtime. This is the exact class that broke
# web-sheet sign-in on Xcode 26.2 (WKNavigationDelegate.decidePolicyFor with a
# non-@MainActor decisionHandler) — see
# .forgeos/wall-failures/2026-07-07-pr1205-wknavigationdelegate-mainactor-witness.md
#
# It SKIPS benign "nearly matches" between DIFFERENTLY-named methods (e.g.
# CarPlay `templateApplicationScene(_:didDisconnect:)` ≈ `...(_:didSelect:)`) —
# those are unrelated methods the compiler merely finds structurally similar,
# not a witness that failed to register.
#
# Usage: scripts/check-objc-witness-nearly-matches.sh <build-log>   ('-' = stdin)
# Exit 0 = clean; Exit 1 = witness drift found; Exit 2 = usage/log error.
#
# Allowlist (optional): OBJC_WITNESS_ALLOWLIST (default .forgeos/objc-witness-allowlist.txt)
#   one "substring" per line matched against the offending warning line; '#' comments.

set -uo pipefail

LOG="${1:-}"
if [ -z "$LOG" ]; then echo "usage: $0 <build-log|->"; exit 2; fi
if [ "$LOG" = "-" ]; then SRC=/dev/stdin; else SRC="$LOG"; [ -f "$SRC" ] || { echo "[objc-witness] no such log: $SRC"; exit 2; }; fi

ALLOW="${OBJC_WITNESS_ALLOWLIST:-.forgeos/objc-witness-allowlist.txt}"

# For each nearly-matches warning, extract candidate method name (m) and
# requirement name (r); emit the line only when m == r (same selector = drift).
FINDINGS=$(awk '
  /warning: instance method .* nearly matches optional requirement .* of protocol/ {
    line=$0
    if (match(line, /instance method '\''[^'\'']+'\''/)) {
      m=substr(line, RSTART, RLENGTH); gsub(/instance method '\''|'\''$/,"",m)
    } else { next }
    if (match(line, /optional requirement '\''[^'\'']+'\''/)) {
      r=substr(line, RSTART, RLENGTH); gsub(/optional requirement '\''|'\''$/,"",r)
    } else { next }
    if (m == r) print line
  }
' "$SRC" | sort -u)

# Drop allowlisted lines.
if [ -f "$ALLOW" ] && [ -n "$FINDINGS" ]; then
  while IFS= read -r pat; do
    [ -z "$pat" ] && continue
    case "$pat" in \#*) continue ;; esac
    FINDINGS=$(printf '%s\n' "$FINDINGS" | grep -vF -- "$pat" || true)
  done < "$ALLOW"
fi

if [ -n "$FINDINGS" ]; then
  echo "[objc-witness] BLOCK: @objc optional-protocol witness drift — the method is silently NOT the delegate witness, so WebKit/UIKit will skip the callback at runtime:"
  printf '%s\n' "$FINDINGS"
  echo ""
  echo "Fix: match the SDK requirement's signature/isolation exactly (e.g. an @MainActor method"
  echo "     with an '@escaping @MainActor' handler for WK_SWIFT_UI_ACTOR protocols)."
  echo "If genuinely intentional, add a matching substring to $ALLOW with a reason."
  exit 1
fi

echo "[objc-witness] OK: no same-name @objc optional-protocol witness drift."
exit 0
