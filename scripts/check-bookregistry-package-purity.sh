#!/bin/bash
# check-bookregistry-package-purity.sh
#
# DORMANT gate for the future `PalaceBookRegistry` package (Wave 2b — see
# docs/architecture/god-class-decomposition-plan.md and the Wave 2b brief:
# extract PalaceBookRegistry + invert Accounts via `AccountScopeProviding`).
#
# Once that package exists, its `Sources/` must NEVER reach back into the
# app-target coupling surface it was extracted to escape — that would
# recreate exactly the `.shared` / `AppContainer`-locator coupling the whole
# god-class decomposition campaign exists to dissolve. This gate asserts ZERO
# occurrences, anywhere under `Palace/Packages/PalaceBookRegistry/Sources`, of:
#
#   AccountsManager | TPPUserAccount | AppContainer | MyBooksDownloadCenter |
#   LCPAudiobooks | NotificationService
#
# It is DORMANT today: the package does not exist yet (Wave 2b has not landed
# as of this writing), so the gate NO-OPs cleanly (exit 0, explains why) until
# `Palace/Packages/PalaceBookRegistry/Sources` appears. Once the package is
# extracted, this gate goes live automatically on the very next commit that
# touches it — no further wiring required.
#
# Env overrides (for tests):
#   BOOKREGISTRY_SCAN_ROOT   directory to scan (default:
#                            <repo>/Palace/Packages/PalaceBookRegistry/Sources)
#
# Usage: check-bookregistry-package-purity.sh
# Exit: 0 = package doesn't exist yet (no-op) OR zero forbidden references (PASS)
#       1 = a forbidden reference was found (FAIL)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
SCAN_ROOT="${BOOKREGISTRY_SCAN_ROOT:-$REPO/Palace/Packages/PalaceBookRegistry/Sources}"

FORBIDDEN='AccountsManager|TPPUserAccount|AppContainer|MyBooksDownloadCenter|LCPAudiobooks|NotificationService'

if [ ! -d "$SCAN_ROOT" ]; then
  echo "[bookregistry-purity] NO-OP: $SCAN_ROOT does not exist yet (Wave 2b package not extracted) — gate is dormant."
  exit 0
fi

# Match CODE references only, not documentation. The extracted package's
# boundary docs legitimately NAME these types (e.g. "no `AccountsManager` type
# crosses this boundary", "the package holds no edge to `AppContainer`") — the
# invariant is about code coupling (imports / type usage), never prose. So strip
# Swift comments (`//`, `///`, `/* */`) and string literals before matching, and
# require a word-boundary hit on the residue. A naive grep would flag the gate's
# own documentation.
PY_STDERR="$(mktemp)"
trap 'rm -f "$PY_STDERR"' EXIT

set +e
FINDINGS="$(FORBIDDEN="$FORBIDDEN" SCAN_ROOT="$SCAN_ROOT" python3 - 2>"$PY_STDERR" <<'PY'
import os, re, sys
forbidden = os.environ["FORBIDDEN"]
root = os.environ["SCAN_ROOT"]
pat = re.compile(r'\b(' + forbidden + r')\b')

def strip(src):
    # Blank out //-line-comments, /* */ block comments, and "..." string
    # literals, preserving newlines so line numbers stay accurate.
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c == '"':                       # string literal
            out.append(' '); i += 1
            while i < n and src[i] != '"':
                if src[i] == '\\' and i + 1 < n:
                    out.append('  '); i += 2; continue
                out.append('\n' if src[i] == '\n' else ' '); i += 1
            if i < n:
                out.append(' '); i += 1
        elif c == '/' and i + 1 < n and src[i+1] == '/':   # // or /// line comment
            while i < n and src[i] != '\n':
                out.append(' '); i += 1
        elif c == '/' and i + 1 < n and src[i+1] == '*':   # /* */ block comment
            out.append('  '); i += 2
            while i + 1 < n and not (src[i] == '*' and src[i+1] == '/'):
                out.append('\n' if src[i] == '\n' else ' '); i += 1
            if i + 1 < n:
                out.append('  '); i += 2
        else:
            out.append(c); i += 1
    return ''.join(out)

hits = []
for dirpath, _, files in os.walk(root):
    for f in files:
        if not f.endswith('.swift'):
            continue
        p = os.path.join(dirpath, f)
        try:
            code = strip(open(p, encoding='utf-8', errors='replace').read())
        except OSError:
            continue
        for ln, line in enumerate(code.splitlines(), 1):
            m = pat.search(line)
            if m:
                hits.append(f"{p}:{ln}: {m.group(1)}")
sys.stdout.write("\n".join(hits))
PY
)"
PY_EXIT=$?
set -e

if [ "$PY_EXIT" -ne 0 ]; then
  echo "[bookregistry-purity] FAIL: the python3 scanner crashed (exit $PY_EXIT) instead of"
  echo "  producing findings. A crashed scanner is NOT the same as zero findings — failing"
  echo "  closed rather than silently passing. Interpreter stderr:"
  sed 's/^/  /' "$PY_STDERR"
  exit 1
fi

if [ -n "$FINDINGS" ]; then
  echo "[bookregistry-purity] FAIL: PalaceBookRegistry/Sources references the app-target"
  echo "  coupling surface it was extracted to escape:"
  printf '%s\n' "$FINDINGS"
  echo ""
  echo "  Fix: invert the dependency (e.g. AccountScopeProviding) instead of reaching back"
  echo "  into AccountsManager / TPPUserAccount / AppContainer / MyBooksDownloadCenter /"
  echo "  LCPAudiobooks / NotificationService from the extracted package (see the Wave 2b plan)."
  exit 1
fi

echo "[bookregistry-purity] PASS: $SCAN_ROOT has zero forbidden app-target references."
exit 0
