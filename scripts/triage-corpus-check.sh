#!/bin/bash
# triage-corpus-check.sh
#
# Release-time credential-leak gate for the TriageBot redaction corpus (PP-4806).
#
# Re-runs the standing deny-list guard (RedactionCorpusTests) over the synthetic
# captured-payload corpus in
#   Palace/Packages/PalaceTriageBot/Tests/TriageBotCoreTests/Fixtures/
# so that a log line newly introduced anywhere in the sensitive flows (sign-in /
# borrow / download / audiobook) that leaks a patron secret through
# ContextRedactor FAILS the release instead of shipping.
#
# The corpus is SYNTHETIC today; real device captures from the simdrive / chaos
# QA runs (PP-4813 / PP-4817) drop into Fixtures/ later and this gate covers them
# unchanged.
#
# Usage:
#   scripts/triage-corpus-check.sh              # run the deny-list guard
#   scripts/triage-corpus-check.sh --self-test  # ALSO prove the gate goes red on
#                                               # an injected raw leak, then clean up
#
# Exit 0 = corpus clean (and, with --self-test, the gate provably fails on a leak).
# Exit 1 = a credential shape survived redaction (or the self-test gate did NOT
#          go red on an injected leak — a broken gate).
# Exit 2 = usage / environment error.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG_PATH="$REPO_ROOT/Palace/Packages/PalaceTriageBot"
FIXTURES_DIR="$PKG_PATH/Tests/TriageBotCoreTests/Fixtures"
TEST_FILTER="RedactionCorpusTests"

SELF_TEST=0
for arg in "$@"; do
  case "$arg" in
    --self-test) SELF_TEST=1 ;;
    -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "[triage-corpus] unknown argument: $arg"; exit 2 ;;
  esac
done

if ! command -v swift >/dev/null 2>&1; then
  echo "[triage-corpus] swift toolchain not found on PATH"; exit 2
fi
if [ ! -d "$PKG_PATH" ]; then
  echo "[triage-corpus] package not found at $PKG_PATH"; exit 2
fi
if [ ! -d "$FIXTURES_DIR" ]; then
  echo "[triage-corpus] fixtures dir not found at $FIXTURES_DIR"; exit 2
fi

run_guard() {
  swift test --package-path "$PKG_PATH" --filter "$TEST_FILTER" 2>&1
}

echo "[triage-corpus] running redaction deny-list guard over $(find "$FIXTURES_DIR" -name '*.txt' | wc -l | tr -d ' ') fixture file(s)…"
if run_guard | tee /tmp/triage-corpus-guard.log | grep -qE "Test Suite '$TEST_FILTER' passed"; then
  echo "[triage-corpus] PASS — no credential shape survived redaction."
else
  echo "[triage-corpus] FAIL — a credential shape survived redaction (see output above)."
  exit 1
fi

if [ "$SELF_TEST" -eq 1 ]; then
  # Prove the gate is live: if redaction ever STOPS stripping the secret shapes
  # the corpus contains, the guard must go RED. We simulate that leak by running
  # the same guard with redaction disabled (TRIAGE_CORPUS_DISABLE_REDACTION=1,
  # honored by RedactionCorpusTests) — the raw corpus then flows straight into
  # the deny-list, which must fire. A gate nobody has seen fail is not a gate.
  echo "[triage-corpus] --self-test: disabling redaction to prove the guard goes RED on an un-redacted corpus…"
  if TRIAGE_CORPUS_DISABLE_REDACTION=1 run_guard | grep -qE "Test Suite '$TEST_FILTER' passed"; then
    echo "[triage-corpus] SELF-TEST FAIL — guard PASSED with redaction disabled. The deny-list is inert; a real leak would ship."
    exit 1
  fi
  echo "[triage-corpus] SELF-TEST PASS — guard correctly went RED when redaction was disabled (deny-list is live)."
fi

echo "[triage-corpus] done."
exit 0
