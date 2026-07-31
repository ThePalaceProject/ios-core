#!/usr/bin/env bash
#
# check-inert-wiring.sh — find guards that no test can tell you deleted.
#
# The single most common defect class on the 3.2.3 LCP hotfix was not broken
# logic. It was correct production code whose proof was inert: a line could be
# deleted and the whole suite stayed green. Five separate findings, across three
# review rounds, all the same shape:
#
#   self.localContentService.downloadCenterHasTransfer = { ... }   <- delete it,
#   self.startCoordinator.hasActiveLCPContentTransfer  = { ... }      suite green
#   self.cancellationHandler.progressReporter = progressReporter
#
# Every behavioural test injected those seams by hand, so nothing observed the
# assignment that connects them in production. An inert guard is worse than no
# guard: it reads as coverage in a PR body and suppresses the scrutiny that would
# have caught the bug.
#
# This script finds the candidates mechanically. For each post-init collaborator
# assignment the diff adds, it comments the line out, runs the suites you name,
# and reports SURVIVED (nothing failed -> inert) or KILLED (a test noticed).
#
# It is deliberately narrow. It does not try to mutate arbitrary logic — that is
# palace_mutate's job. It targets the one pattern that unit tests structurally
# cannot see, because the unit test is the thing bypassing it.
#
# Usage:
#   scripts/check-inert-wiring.sh --base origin/main --tests PalaceTests/FooTests[,BarTests]
#   scripts/check-inert-wiring.sh --list-only --base origin/main
#
# Exit 0 = every candidate killed (or none found). Exit 1 = at least one survived.

set -euo pipefail

BASE="origin/main"
TESTS=""
LIST_ONLY=0
SIM_ID="${HARNESS_SESSION_SIM_UDID:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base)      BASE="$2"; shift 2 ;;
    --tests)     TESTS="$2"; shift 2 ;;
    --sim)       SIM_ID="$2"; shift 2 ;;
    --list-only) LIST_ONLY=1; shift ;;
    -h|--help)   sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if ! git rev-parse --verify "$BASE" >/dev/null 2>&1; then
  echo "check-inert-wiring: base ref '$BASE' not found" >&2
  exit 2
fi

# Added lines that assign onto a COLLABORATOR's property: `self.x.y = ...`.
#
# Two components after `self.` on purpose. `self.foo = foo` is constructor
# plumbing that any construction test covers; `self.collaborator.property = ...`
# is composition wiring, which unit tests bypass by injecting the seam directly.
# That second shape is the one that goes inert, and narrowing to it keeps the
# signal high enough to act on — a noisy detector gets ignored, which is how you
# end up with an inert detector for inert guards.
# Pathspec is `Palace/` plus a suffix filter, NOT 'Palace/**/*.swift': that glob
# requires at least one directory level, so it silently skipped files directly
# under Palace/ — which is exactly how a detector ends up reporting "nothing to
# check" on a diff that has something to check.
CANDIDATES=$(git diff "$BASE"...HEAD --unified=0 -- 'Palace/' \
  | grep -E '^\+' | grep -vE '^\+\+\+' \
  | sed 's/^\+//' \
  | grep -E '^[[:space:]]*self\.[A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*(\{|[A-Za-z_])' \
  | sort -u || true)

# `[[:space:]]` not `\s`, and NO left-strip. BSD sed silently ignores `\s`, so a
# `sed 's/^\s*//'` here is a no-op on macOS and a real strip on the GNU sed the
# ubuntu tooling runner uses. That difference is invisible locally and changes what
# the probe deletes — the detector passed its own dogfood on macOS while being
# broken on CI.

if [[ -z "$CANDIDATES" ]]; then
  echo "check-inert-wiring: no post-init wiring assignments added — nothing to check"
  exit 0
fi

echo "check-inert-wiring: candidate wiring lines added vs $BASE:"
while IFS= read -r line; do echo "  $line"; done <<< "$CANDIDATES"

if [[ "$LIST_ONLY" == "1" ]]; then exit 0; fi

if [[ -z "$TESTS" ]]; then
  echo ""
  echo "check-inert-wiring: --tests is required to verify (got none)." >&2
  echo "Name the suites that should notice these seams, e.g." >&2
  echo "  --tests PalaceTests/LocalBookContentServiceTests" >&2
  exit 2
fi

if [[ -n "$(git status --porcelain)" ]]; then
  echo "check-inert-wiring: worktree is dirty; commit or stash first (this script edits files)" >&2
  exit 2
fi

DEST="platform=iOS Simulator,name=iPhone 16 Pro"
[[ -n "$SIM_ID" ]] && DEST="platform=iOS Simulator,id=$SIM_ID"

ONLY_TESTING=""
IFS=',' read -ra SUITES <<< "$TESTS"
for s in "${SUITES[@]}"; do ONLY_TESTING="$ONLY_TESTING -only-testing:$s"; done

WORK=$(mktemp -d)
trap 'git checkout -- Palace/ 2>/dev/null || true; rm -rf "$WORK"' EXIT

SURVIVED=0
TOTAL=0
INCONCLUSIVE=0

while IFS= read -r line; do
  FILE=$(git diff "$BASE"...HEAD --name-only -- 'Palace/' | grep '\.swift$' \
         | while read -r f; do grep -qF "$line" "$f" 2>/dev/null && echo "$f" && break; done)
  [[ -z "$FILE" ]] && continue
  TOTAL=$((TOTAL + 1))

  echo ""
  echo "--- deleting: $line"
  echo "    in: $FILE"

  python3 - "$FILE" "$line" <<'PY'
import sys
path, target = sys.argv[1], sys.argv[2]
src = open(path).read()
# Neutralise the assignment. A one-liner is commented out; a multi-line closure
# must be removed WHOLESALE, or the orphaned body is a syntax error and the probe
# reports nothing useful.
#
# Detecting "opens a closure" by `endswith("{")` is wrong: a capture list ends the
# line with `in` (`= { [weak self] identifier in`). That bug made this script's own
# first run report two covered lines as SURVIVED — a false positive, which is worse
# than no detector at all.
idx = src.find(target)
if idx == -1:
    sys.exit(0)
open(path + ".inert-bak", "w").write(src)
opens_closure = "{" in target and target.count("{") > target.count("}")
if opens_closure:
    # Balance braces from the assignment forward, rather than guessing the closing
    # brace from indentation. Indent-matching depended on the candidate keeping its
    # leading whitespace, which differs between BSD and GNU sed; when it was lost,
    # this searched for a column-0 `}` and deleted to the end of the class.
    depth, end = 0, None
    for i in range(idx, len(src)):
        if src[i] == "{":
            depth += 1
        elif src[i] == "}":
            depth -= 1
            if depth == 0:
                end = src.find("\n", i)
                end = end + 1 if end != -1 else len(src)
                break
    if end is None:
        sys.exit(0)
    src = src[:idx] + src[end:]
else:
    src = src.replace(target, "// [inert-wiring probe] " + target, 1)
open(path, "w").write(src)
PY

  if "${XCODEBUILD:-xcodebuild}" -project Palace.xcodeproj -scheme Palace -configuration Debug \
       -destination "$DEST" -derivedDataPath "$WORK/dd" \
       $ONLY_TESTING test > "$WORK/out.log" 2>&1; then
    FAILS=0
  else
    FAILS=$(grep -cE 'error: -\[' "$WORK/out.log" || true)
  fi

  # A build failure is not a kill and is NOT a survival — it means the probe broke
  # compilation, which tells you nothing about coverage. The only trustworthy
  # signal that tests actually RAN is a TEST SUCCEEDED/FAILED banner; absent that,
  # say so rather than guessing. Scoring a non-compiling probe as SURVIVED is how
  # this script first reported two well-covered lines as inert.
  if ! grep -qE '\*\* TEST (SUCCEEDED|FAILED) \*\*' "$WORK/out.log"; then
    echo "    INCONCLUSIVE — probe did not build, so no test ran; check by hand"
    INCONCLUSIVE=$((INCONCLUSIVE + 1))
  elif [[ "$FAILS" -gt 0 ]]; then
    echo "    KILLED — $FAILS failing assertion(s)"
  else
    echo "    SURVIVED — no test noticed this line was gone"
    SURVIVED=$((SURVIVED + 1))
  fi

  [[ -f "$FILE.inert-bak" ]] && mv "$FILE.inert-bak" "$FILE"
done <<< "$CANDIDATES"

echo ""
if [[ "$SURVIVED" -gt 0 ]]; then
  echo "check-inert-wiring: $SURVIVED of $TOTAL wiring line(s) SURVIVED deletion."
  echo "Each is a guard no test can tell you removed. Add an assertion that"
  echo "observes the seam through the object production actually wires, not"
  echo "through a hand-injected one."
  exit 1
fi

if [[ "$INCONCLUSIVE" -gt 0 ]]; then
  echo "check-inert-wiring: $INCONCLUSIVE of $TOTAL probe(s) INCONCLUSIVE — the probe did not"
  echo "compile, so those lines are UNVERIFIED. Exiting non-zero: a detector that cannot"
  echo "reach a verdict must not report success, or it becomes the inert gate it exists"
  echo "to find."
  exit 1
fi
echo "check-inert-wiring: all conclusive probes killed ($TOTAL candidate(s))."
