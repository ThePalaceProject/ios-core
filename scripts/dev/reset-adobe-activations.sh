#!/usr/bin/env bash
#
# reset-adobe-activations.sh — give a test patron a fresh Adobe identity.
#
# WHY YOU NEED THIS. Adobe caps how many devices one Adobe user may activate.
# Reinstalling the app, wiping a simulator, or signing out over a connection
# that drops all consume a slot without returning one, so a test account walks
# into `E_ACT_TOO_MANY_ACTIVATIONS` and every Adobe borrow fails until it is
# cleared. There is no in-app way out.
#
# WHAT IT ACTUALLY DOES, because the name oversells it. It calls
# `DELETE /patrons/me/adobe_id` on the circulation manager, which deletes the
# patron's stored Adobe account identifier. The NEXT sign-in mints a new one,
# so the patron is a new Adobe user with an empty activation count.
#
# It does NOT deauthorize anything at Adobe. The old activations stay stranded
# under the old identifier forever — this walks away from them rather than
# releasing them. Two consequences worth knowing before you run it:
#
#   * Any Adobe-DRM book already downloaded under the old identity becomes
#     undecryptable on every device. Return them first if you care.
#   * The patron must sign out and back in for the new identifier to be minted.
#
# For those reasons this is a TEST-ACCOUNT tool. It refuses a production host
# unless you insist, and it will not read credentials from the command line.
#
# Usage:
#   scripts/dev/reset-adobe-activations.sh [--library SLUG] [--server URL]
#
#   PALACE_BARCODE / PALACE_PIN may be exported to skip the prompts.
#   The PIN is never echoed and never appears in the process list.
#
set -euo pipefail

SERVER="${PALACE_SERVER:-https://gorgon.staging.palaceproject.io}"
LIBRARY="${PALACE_LIBRARY:-a1qa-test}"
FORCE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --library) LIBRARY="$2"; shift 2 ;;
    --server)  SERVER="${2%/}"; shift 2 ;;
    --force)   FORCE=1; shift ;;
    -h|--help) sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# A slot reset on a real patron destroys their downloaded Adobe books. Make
# that a deliberate act rather than a default.
case "$SERVER" in
  *staging*|*localhost*|*127.0.0.1*|*qa*) ;;
  *)
    if [ "$FORCE" -ne 1 ]; then
      echo "Refusing to touch a non-staging server: $SERVER" >&2
      echo "This deletes a real patron's Adobe identity and orphans their downloaded books." >&2
      echo "Pass --force if that is genuinely what you want." >&2
      exit 1
    fi
    echo "WARNING: running against $SERVER — a production patron's books will be orphaned." >&2
    ;;
esac

URL="$SERVER/$LIBRARY/patrons/me/adobe_id"

BARCODE="${PALACE_BARCODE:-}"
if [ -z "$BARCODE" ]; then
  printf 'Barcode for %s: ' "$LIBRARY" >&2
  read -r BARCODE
fi

PIN="${PALACE_PIN:-}"
if [ -z "$PIN" ]; then
  printf 'PIN (not echoed): ' >&2
  read -rs PIN
  echo >&2
fi

echo "DELETE $URL" >&2

# Credentials go via --netrc-file on a private fd-backed temp file rather than
# -u, so they never appear in `ps` output or the shell history.
NETRC="$(mktemp)"
trap 'rm -f "$NETRC"' EXIT
chmod 600 "$NETRC"
HOST="${SERVER#*://}"; HOST="${HOST%%/*}"
printf 'machine %s login %s password %s\n' "$HOST" "$BARCODE" "$PIN" > "$NETRC"

BODY="$(mktemp)"; trap 'rm -f "$NETRC" "$BODY"' EXIT
STATUS="$(curl -sS -o "$BODY" -w '%{http_code}' -X DELETE --netrc-file "$NETRC" "$URL")"

echo "HTTP $STATUS" >&2
cat "$BODY"; echo

case "$STATUS" in
  200)
    cat >&2 <<'DONE'

Adobe identity deleted. To finish:
  1. Sign OUT of this library in the app.
  2. Sign back IN — the CM mints a new Adobe identifier at that point.
  3. Borrow an Adobe title. Activation count starts from zero.
DONE
    ;;
  401) echo "Authentication failed — check the barcode/PIN for $LIBRARY." >&2; exit 1 ;;
  404) echo "No such route. Check --library ($LIBRARY) and --server ($SERVER)." >&2; exit 1 ;;
  *)   echo "Unexpected status $STATUS — nothing was reset." >&2; exit 1 ;;
esac
