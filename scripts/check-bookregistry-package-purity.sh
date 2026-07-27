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

FINDINGS="$(grep -rnE "$FORBIDDEN" "$SCAN_ROOT" --include='*.swift' 2>/dev/null || true)"

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
