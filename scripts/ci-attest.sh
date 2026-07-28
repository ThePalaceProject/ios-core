#!/usr/bin/env bash
#
# ci-attest.sh — mint a CI-signed, tip-bound proof-of-done AFTER the authoritative
# suite has already passed at this SHA. This is the "system validates itself" signer:
# the proof is signed by the `ci-runner` identity whose PRIVATE key exists only in a
# GitHub Actions secret, so no local actor (human or agent) can forge it.
#
# .heka/ is gitignored, so CI has neither the allowlist nor a heka.json — this script
# assembles BOTH from the CI-provided trust material into a temp dir, signs, exports
# the evidence, and ALWAYS shreds the private key (trap), win or lose.
#
# INPUTS (env — set by the workflow from Actions secrets/vars):
#   HEKA_CI_SIGNING_KEY_MATERIAL   the ci-runner PRIVATE key (openssh, no passphrase)   [secret]
#   HEKA_CI_ALLOWED_SIGNERS        one allowlist line: `ci-runner ssh-ed25519 AAAA… ci` [variable]
#   HEKA_BIN                       path to the heka2 binary (default: heka2 on PATH)
# ARGS:
#   --tier T<n>   verification tier this attests (default T2 — the full CI parity tier)
#   --runner ID   attesting principal (default ci-runner) — MUST match the allowlist line
#   --sha SHA     the head SHA the suite passed at; asserted == git HEAD (tip-binding guard)
#
# EXIT 0 = signed proof recorded (verify:<tier>, tier=signed) + evidence exported.
set -euo pipefail

TIER=T2; RUNNER=ci-runner; WANT_SHA=""
while [ $# -gt 0 ]; do
  case "$1" in
    --tier)   TIER="$2";   shift 2 ;;
    --runner) RUNNER="$2"; shift 2 ;;
    --sha)    WANT_SHA="$2"; shift 2 ;;
    *) echo "ci-attest: unknown arg $1" >&2; exit 2 ;;
  esac
done

: "${HEKA_CI_SIGNING_KEY_MATERIAL:?ci-attest: HEKA_CI_SIGNING_KEY_MATERIAL not set (the ci-runner private key secret)}"
: "${HEKA_CI_ALLOWED_SIGNERS:?ci-attest: HEKA_CI_ALLOWED_SIGNERS not set (the ci-runner allowlist line)}"
HEKA_BIN="${HEKA_BIN:-heka2}"
command -v "$HEKA_BIN" >/dev/null || { echo "ci-attest: heka2 not found ($HEKA_BIN)" >&2; exit 2; }

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

# Tip-binding guard: the suite passed at WANT_SHA; refuse to attest a different tip.
HEAD_SHA="$(git rev-parse HEAD)"
if [ -n "$WANT_SHA" ] && [ "${HEAD_SHA#"$WANT_SHA"}" = "$HEAD_SHA" ] && [ "${WANT_SHA#"$HEAD_SHA"}" = "$WANT_SHA" ]; then
  echo "ci-attest: HEAD ($HEAD_SHA) != suite SHA ($WANT_SHA) — refusing to attest a tip the suite did not pass (fail-closed)." >&2
  exit 1
fi

# Assemble the trust material in a private temp dir; shred the KEY on every exit.
WORK="$(mktemp -d)"
KEY="$WORK/ci-runner"; ALLOW="$WORK/allowed_signers"; CFG="$WORK/heka.json"
cleanup() { command -v shred >/dev/null && shred -u "$KEY" 2>/dev/null || rm -f "$KEY"; rm -rf "$WORK"; }
trap cleanup EXIT

printf '%s\n' "$HEKA_CI_SIGNING_KEY_MATERIAL" > "$KEY"; chmod 600 "$KEY"
printf '%s\n' "$HEKA_CI_ALLOWED_SIGNERS"      > "$ALLOW"
# heka.json only needs require_tier + the allowlist; the KEY is passed via env override.
printf '{"stacks":["swift"],"gates":{"review":{"require_tier":"attested","allowed_signers":"%s"}}}\n' "$ALLOW" > "$CFG"

# heka2 reads heka.json from the repo root; stage ours only for the attest call, then
# restore whatever was there (usually nothing — .heka/heka.json are gitignored in CI).
PRIOR=""; [ -f heka.json ] && PRIOR="$(mktemp)" && cp heka.json "$PRIOR"
cp "$CFG" heka.json
restore_cfg() { if [ -n "$PRIOR" ]; then mv "$PRIOR" heka.json; else rm -f heka.json; fi; }
trap 'restore_cfg; cleanup' EXIT

echo "ci-attest: signing verify:$TIER as $RUNNER at ${HEAD_SHA:0:9} …"
HEKA_ACTOR="$RUNNER" HEKA_SIGNING_KEY="$KEY" \
  "$HEKA_BIN" gate verify-attest --tier "$TIER" --runner "$RUNNER" --result pass

# Export the freshly-recorded verify:<tier> event as portable evidence (the merge
# recheck / audit reads this without trusting CI's own ledger fields).
mkdir -p .heka/evidence
OUT=".heka/evidence/verify-${TIER}-${HEAD_SHA:0:12}.json"
tail -1 .heka/telemetry.jsonl > "$OUT"
echo "ci-attest: evidence exported → $OUT"
