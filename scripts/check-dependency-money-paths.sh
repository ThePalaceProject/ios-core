#!/usr/bin/env bash
#
# check-dependency-money-paths.sh
#
# Fails when the Readium (swift-toolkit) pin moves without a recorded
# money-path validation entry for the new version.
#
# Why this gate exists
# --------------------
# Palace 3.2.0 bumped Readium 3.7 -> 3.9. That bump carried in the removal of the
# range clamp in `BufferingResource.stream(range:)` (upstream PR readium#723,
# whose title names only the EPUB navigator but which rewrote shared code), so
# reads can run past end of file. Nothing in the release process exercised LCP
# audiobook playback against the new pin, so it shipped unnoticed and was only
# diagnosed months later.
#
# A second, older defect compounds it (upstream issue readium#579, filed against
# toolkit v3.2.0): playback does not start until the whole resource is buffered.
# Between them, LCP audiobook streaming is unusable, so an entire `.lcpa` archive
# must download before playback starts, which is minutes on a large title. Both
# are being fixed upstream on an unmerged branch. See
# docs/architecture/readium-upgrade-validation.md for the full account and why a
# version bump alone should not be assumed to fix open latency.
#
# A dependency that renders, decrypts, or fulfills content sits directly on the
# money paths. Version numbers do not tell you whether those paths still work.
# Someone has to open a borrowed book of each protected kind and confirm.
#
# What it requires
# ----------------
# When the swift-toolkit version or revision changes, the same change must add
# an entry to the validation ledger naming what moved: the new version, or the
# new revision when the version itself did not change. The ledger records who
# validated which paths against which build. See
# docs/architecture/readium-upgrade-validation.md for the required paths and the
# entry format.
#
# Usage
#   check-dependency-money-paths.sh --base <git-ref>
#       Compare the working tree against <git-ref> (CI / pre-PR use).
#
#   check-dependency-money-paths.sh --old-resolved F --new-resolved F --ledger F
#       Pure file comparison with no git involvement (used by the unit tests).
#
# Exit codes
#   0  pin unchanged, or pin changed and validation is recorded
#   1  pin changed without a matching ledger entry
#   2  usage / unreadable input
#
set -euo pipefail

RESOLVED_PATH="Palace.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
LEDGER_PATH="docs/architecture/readium-money-path-validation.md"
PACKAGE_IDENTITY="swift-toolkit"

usage() {
  sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

# Extracts "<version>|<revision>" for the tracked package from a Package.resolved
# file. Emits an empty string when the file is missing or the package is absent
# (a fresh checkout, or the dependency having been removed).
extract_pin() {
  local file="$1"
  [ -f "$file" ] || { printf ''; return 0; }
  python3 - "$file" "$PACKAGE_IDENTITY" <<'PY'
import json, sys
path, identity = sys.argv[1], sys.argv[2]
try:
    with open(path) as fh:
        doc = json.load(fh)
except Exception:
    print("")
    sys.exit(0)
# Package.resolved v2 nests under "pins"; v1 under "object"/"pins".
pins = doc.get("pins") or doc.get("object", {}).get("pins") or []
for pin in pins:
    name = pin.get("identity") or pin.get("package") or ""
    if name.lower() == identity.lower():
        state = pin.get("state", {})
        print("%s|%s" % (state.get("version", ""), state.get("revision", "")))
        sys.exit(0)
print("")
PY
}

# True when the ledger records the given version. Matching is deliberately
# literal: the entry must name the exact version string so a copy-pasted entry
# for an older bump does not satisfy a newer one.
ledger_records_version() {
  local ledger="$1" version="$2"
  [ -f "$ledger" ] || return 1
  [ -n "$version" ] || return 1
  grep -Fq -- "$version" "$ledger"
}

MODE=""
BASE=""
OLD_RESOLVED=""
NEW_RESOLVED=""
LEDGER=""

while [ $# -gt 0 ]; do
  case "$1" in
    --base)          MODE="git";  BASE="${2:-}"; shift 2 ;;
    --old-resolved)  MODE="pure"; OLD_RESOLVED="${2:-}"; shift 2 ;;
    --new-resolved)  MODE="pure"; NEW_RESOLVED="${2:-}"; shift 2 ;;
    --ledger)        LEDGER="${2:-}"; shift 2 ;;
    -h|--help)       usage ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
done

if [ "$MODE" = "git" ]; then
  [ -n "$BASE" ] || usage
  # Materialize the base revision's Package.resolved so both sides go through
  # the same extractor — a second inline copy would be free to drift.
  BASE_TMP="$(mktemp)"
  trap 'rm -f "$BASE_TMP"' EXIT
  git show "$BASE:$RESOLVED_PATH" > "$BASE_TMP" 2>/dev/null || : > "$BASE_TMP"
  OLD_PIN="$(extract_pin "$BASE_TMP")"
  NEW_PIN="$(extract_pin "$RESOLVED_PATH")"
  LEDGER="$LEDGER_PATH"
elif [ "$MODE" = "pure" ]; then
  [ -n "$NEW_RESOLVED" ] || usage
  OLD_PIN="$(extract_pin "$OLD_RESOLVED")"
  NEW_PIN="$(extract_pin "$NEW_RESOLVED")"
  [ -n "$LEDGER" ] || LEDGER="$LEDGER_PATH"
else
  usage
fi

if [ "$OLD_PIN" = "$NEW_PIN" ]; then
  echo "Readium pin unchanged (${NEW_PIN:-absent}) — money-path validation not required."
  exit 0
fi

OLD_VERSION="${OLD_PIN%%|*}"
NEW_VERSION="${NEW_PIN%%|*}"
NEW_REVISION="${NEW_PIN#*|}"

echo "Readium pin changed:"
echo "  before: ${OLD_PIN:-absent}"
echo "  after:  ${NEW_PIN:-absent}"

# Which token must appear in the ledger depends on what actually moved. A
# revision move at an unchanged version still changes behaviour (a branch build,
# a re-tag, a force-push upstream), and the existing entry for that version says
# nothing about the new code — so in that case the revision is what has to be
# recorded. Matching on the version alone here would let exactly that change
# through on the strength of a stale entry.
if [ -n "$NEW_VERSION" ] && [ "$NEW_VERSION" != "$OLD_VERSION" ]; then
  REQUIRED_TOKEN="$NEW_VERSION"
  REQUIRED_KIND="version"
else
  REQUIRED_TOKEN="$NEW_REVISION"
  REQUIRED_KIND="revision"
fi

if ledger_records_version "$LEDGER" "$REQUIRED_TOKEN"; then
  echo "Money-path validation recorded for ${REQUIRED_KIND} ${REQUIRED_TOKEN} in ${LEDGER}."
  exit 0
fi

cat >&2 <<EOF

BLOCKED: the Readium pin moved to version '${NEW_VERSION:-unknown}'
(revision ${NEW_REVISION:-unknown}) with no money-path validation entry in
${LEDGER} naming the ${REQUIRED_KIND} '${REQUIRED_TOKEN:-unknown}'.

Readium renders and decrypts borrowed content, so a version bump can break
borrow, download, fulfillment, or playback without any compile error. The
3.7 -> 3.9 bump removed a range clamp and broke LCP audiobook streaming; it
shipped because nothing exercised that path against the new pin.

Validate the paths listed in docs/architecture/readium-upgrade-validation.md
against a build carrying this pin, then add an entry to ${LEDGER} naming the
${REQUIRED_KIND} '${REQUIRED_TOKEN:-unknown}'.

EOF
exit 1
