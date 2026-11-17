#!/usr/bin/env bash
#
# check-package-tests-wired.sh — every SPM package that HAS tests must have
# those tests actually executed by something.
#
# prior-art-checked: `harness capabilities` has no SPM/test-wiring capability
# (its only near match audits the harness's OWN hooks and symlinks). SPM package
# boundaries constrain IMPORTS (what a package may depend on); nothing checks
# whether a package's tests EXECUTE. That is a different axis.
#
# WHY THIS EXISTS
#
#   Palace/Packages/*/Tests directories accumulate at extraction time and then
#   run nowhere. The only Xcode schemes are `Palace` and `Palace-noDRM`, so
#   xcodebuild never sees a package test target; the only `swift test` step in
#   CI was PalaceTriageBot's. Measured 2026-09-25: PalaceAuthTests (116 tests),
#   PalaceReadingPositionTests (20) and PalaceLoggingTests (8) had executed
#   ZERO times in CI. PalaceAuthTests had been dark since 2026-05-12.
#
#   144 passing tests that proved nothing, because nothing ran them. That is the
#   CLAUDE.md failure mode — "a gate that cannot fail reports a pass" — sitting
#   inside the architecture campaign whose whole purpose is enforcement.
#
#   This gate makes the omission loud: add a package test target, and CI fails
#   until you either wire it or record why you cannot.
#
# THE RULE
#
#   For each Palace/Packages/<Pkg>/Tests containing a test file:
#     <Pkg> must be referenced in .github/workflows/unit-testing.yml
#     OR be listed in ALLOWLIST below with the MECHANISM that blocks wiring.
#
#   An allowlist entry is a debt, not an exemption. "Doesn't work" is not a
#   reason; a reproducible mechanism is.
#
# Exit: 0 all wired or allowlisted · 1 an unwired package · 2 usage/IO error.

set -uo pipefail

ROOT="${1:-$(git rev-parse --show-toplevel 2>/dev/null || echo .)}"
WORKFLOW="$ROOT/.github/workflows/unit-testing.yml"
PKGDIR="$ROOT/Palace/Packages"

# <package>|<mechanism that prevents wiring>
ALLOWLIST=(
  "PalaceKeychain|Builds, then HANGS under macOS swift test. Its tests guard with KeychainAvailability.skipIfUnavailable(), which probes by WRITING to the keychain. That guard was written for the iOS Simulator, where an unentitled host returns -34018 and the skip fires cleanly. On an unsigned macOS swift-test binary the same call blocks on a UI authorization prompt instead of erroring, so the guard never returns and the step burns its timeout. Reproduced 2026-09-25: 'Build complete (21.19s)', then zero test-suite lines, killed at 600s. Fix is to bound the probe, not to wire it as-is."
)

# Exit 2, not 0. "No packages directory" is not "all packages are wired" — and
# a reviewer proved the difference is reachable: relocating Palace/Packages to
# Palace/Modules made this gate exit 0 with every package test still dark. The
# sibling ceiling gate already exits 2 on a missing tree; this one did not, and
# the asymmetry was the hole. Absence must not render as success.
[ -d "$PKGDIR" ] || { echo "[package-tests-wired] ERROR: no $PKGDIR" >&2; exit 2; }
[ -f "$WORKFLOW" ] || { echo "[package-tests-wired] ERROR: missing $WORKFLOW" >&2; exit 2; }

allow_reason() {
  local pkg="$1" entry
  for entry in "${ALLOWLIST[@]}"; do
    case "$entry" in
      "$pkg|"*) printf '%s' "${entry#*|}"; return 0 ;;
    esac
  done
  return 1
}

# Full-line YAML comments stripped ONCE, here, rather than in a pipeline inside
# the loop. `grep -vE ... | grep -q ...` looks equivalent and is not: grep -q
# exits at the first match, the upstream grep takes SIGPIPE (141), and `set -o
# pipefail` turns that into a FAILED test for a package that is correctly wired.
# It is also size-dependent — on a short workflow the upstream finishes before
# the pipe closes and the same code passes. Measured on this tree: all four
# wired packages reported UNWIRED.
# EFFECTIVE steps only. A grep over the YAML text answers "does this string
# appear", which is not the question — the question is "will this run and can it
# fail the build". A reviewer defeated the grep three ways, each the likely shape
# of the incident this gate exists to catch: `continue-on-error: true` (runs,
# cannot redden the board), `if: false` (never runs), and the invocation inside
# an `echo` string. unit-testing.yml already uses continue-on-error 14x and
# step-level `if:` 19x, so none of these is exotic.
#
# The extractor is stdlib-only ON PURPOSE: the first version imported PyYAML, and
# /usr/bin/python3 does not have it, so a restricted-PATH run (a git hook, a
# fresh checkout, any contributor who never pip-installed) got exit 2 from a gate
# with nothing to say about their tree. CLAUDE.md requires verify-pr.sh to run
# unaided.
# Resolved against THIS script's directory, not $ROOT: $ROOT is the tree being
# scanned, which for a pytest fixture is a tmp dir with no scripts/ in it.
EXTRACTOR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/workflow_effective_runs.py"
[ -f "$EXTRACTOR" ] || { echo "[package-tests-wired] ERROR: missing $EXTRACTOR" >&2; exit 2; }
WORKFLOW_CODE="$(python3 "$EXTRACTOR" "$WORKFLOW")" || exit 2

# W1: carry the ceiling gate's B2 reasoning across. An allowlist entry for a
# package that no longer exists is fail-closed here rather than laundering (the
# loop is driven by the filesystem), but it is still a recorded debt for
# something that is gone, and it rots silently. Warn, do not fail.
for entry in "${ALLOWLIST[@]}"; do
  apkg="${entry%%|*}"
  [ -d "$PKGDIR/$apkg" ] || echo "[package-tests-wired] NOTE: allowlisted '$apkg' no longer exists — drop the entry."
done

TMP_EFFECTIVE="$(mktemp)"
trap 'rm -f "$TMP_EFFECTIVE"' EXIT

fails=0
checked=0
seen_dirs=0   # Tests directories found at all, whether or not they hold tests.

for tests_dir in "$PKGDIR"/*/Tests; do
  [ -d "$tests_dir" ] || continue
  seen_dirs=$((seen_dirs + 1))
  pkg="$(basename "$(dirname "$tests_dir")")"

  # A Tests directory with no test file is scaffolding, not a dark suite.
  n_tests=$(grep -rl --include='*.swift' -E '\bfunc test|@Test' "$tests_dir" 2>/dev/null | wc -l | tr -d ' ')
  [ "${n_tests:-0}" -gt 0 ] || continue

  checked=$((checked + 1))

  # Two false-pass routes to close, both measured, not theorised:
  #   1. A bare path match is satisfied by a MENTION — "# someday wire
  #      Palace/Packages/PalaceGhost here" — so the match is anchored to an
  #      actual `swift test --package-path` invocation.
  #   2. Anchoring alone is NOT enough: a commented-out step
  #      ("# - run: swift test --package-path Palace/Packages/PalaceGhost")
  #      still contains the invocation. Someone comments out a flaky package
  #      step mid-incident, the suite goes dark, and the gate built to catch
  #      exactly that stays green. Full-line YAML comments are stripped first.
  #      This PR adds a 30-line comment block to that workflow, so comment prose
  #      near these paths is now normal there.
  # Strip echo/printf lines: `echo "swift test --package-path X"` prints the
  # command, it does not run it, and it satisfied the bare match.
  if grep -vE '^[[:space:]]*(echo|printf)\b' <<< "$WORKFLOW_CODE" \
     > "$TMP_EFFECTIVE" && grep -qE "swift test .*--package-path +Palace/Packages/$pkg([[:space:]]|$)" "$TMP_EFFECTIVE"; then
    echo "  ok        $pkg — run by unit-testing.yml ($n_tests test file(s))"
    continue
  fi

  if reason="$(allow_reason "$pkg")"; then
    echo "  allowed   $pkg — not wired; mechanism recorded:"
    echo "            ${reason:0:92}..."
    continue
  fi

  echo "  UNWIRED   $pkg — $n_tests test file(s) that NOTHING runs" >&2
  fails=$((fails + 1))
done

echo
if [ "$fails" -gt 0 ]; then
  cat >&2 <<'EOF'
[package-tests-wired] FAILED: package(s) above have tests that never execute.

Either add the package to the "Run host-buildable package tests" step in
.github/workflows/unit-testing.yml, or add an ALLOWLIST entry in this script
naming the MECHANISM that prevents it.

A test target nothing runs is worse than no test target: it reads as coverage.
EOF
  exit 1
fi

# A gate that scanned nothing reports the same "OK" as a gate that scanned
# everything and found it clean. Two mutants exploited exactly that — never
# incrementing `checked`, and matching */Test instead of */Tests — and both
# printed OK and exited 0 with the real suites dark. The scan must assert it
# actually saw something.
# The two zeroes are NOT the same and must not be collapsed:
#   seen_dirs == 0  -> the glob matched no Tests directory at all. The scan
#                      broke or the layout moved (a mutant globbing */Test
#                      instead of */Tests reaches exactly this, and used to
#                      print OK). An error.
#   checked   == 0  -> Tests directories exist but none holds a test file.
#                      That is legitimate scaffolding, and reporting it as an
#                      error would make the gate red on a tree with nothing
#                      wrong. Reported, not failed.
# The remaining mutant — `checked` never incrementing while dirs are found — is
# held by test_live_repo_passes asserting the printed count against the real
# tree, since no synthetic fixture can know the true number.
if [ "$seen_dirs" -eq 0 ]; then
  echo "[package-tests-wired] ERROR: scanned $PKGDIR and found NO package test targets." >&2
  echo "  Palace/Packages/*/Tests has held test files continuously since 2026-05." >&2
  echo "  Zero means the layout moved or the scan broke — not that the tree is clean." >&2
  exit 2
fi

echo "[package-tests-wired] OK — $checked package test target(s), all executed or allowlisted with a mechanism."
exit 0
