#!/usr/bin/env bash
# regression-preflight.sh — prove the regression harness can ACTUALLY test,
# before spending a campaign's wall-clock discovering it cannot.
#
# WHY THIS EXISTS
# ---------------
# On 2026-08-20 a full fleet campaign — 21 shards across 3 device cells — ran to
# completion in 25 seconds and reported "0 findings". It had executed nothing:
# 96 journeys skipped, 0 evidence files. A chaos fan launched to replace it also
# executed nothing: every simdrive tool was ungranted in the headless session, so
# the agent was denied, correctly refused to invent findings, and the orchestrator
# logged "returned cleanly / 0 findings". Both results are indistinguishable from
# a clean regression in the merged report.
#
# Every one of those failures was detectable in seconds, BEFORE the campaign.
# That is this script's whole job: check each link in the chain by observing the
# property itself, never by trusting a success message, and refuse to proceed if
# any link is broken. See .harness/wall-failures/2026-08-20-silent-success-in-
# regression-harness.md.
#
# USAGE
#   scripts/regression-preflight.sh --udid <UDID> [--app-path <Palace.app>]
#                                   [--area-group <g>] [--skip-agent]
#
#   --skip-agent   skip the (slow, token-costing) headless-agent tool-grant probe
#
# EXIT
#   0  every check passed — the campaign can produce real evidence
#   1  at least one check FAILED — running a campaign now would produce a
#      vacuous green. The failing check prints the specific remedy.
set -uo pipefail

UDID=""; APP_PATH=""; AREA_GROUP=""; SKIP_AGENT=0
BUNDLE_ID="org.thepalaceproject.palace"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --udid) UDID="$2"; shift 2 ;;
    --app-path) APP_PATH="$2"; shift 2 ;;
    --area-group) AREA_GROUP="$2"; shift 2 ;;
    --skip-agent) SKIP_AGENT=1; shift ;;
    -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

PASS=0; FAIL=0; WARN=0
ok()   { printf '  \033[32mOK\033[0m    %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; printf '        remedy: %s\n' "$2"; FAIL=$((FAIL+1)); }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$1"; WARN=$((WARN+1)); }

echo "=== regression preflight ==="
echo "udid:     ${UDID:-<none>}"
echo "app-path: ${APP_PATH:-<not given>}"
echo

# ---- 1. simulator reachable -------------------------------------------------
if [[ -z "$UDID" ]]; then
  bad "no --udid given" "pass --udid <UDID>; get one from 'xcrun simctl list devices available'"
else
  state="$(xcrun simctl list devices 2>/dev/null | grep -F "$UDID" | grep -oE 'Booted|Shutdown' | head -1)"
  if [[ -z "$state" ]]; then
    bad "sim $UDID not found on this Mac" "the UDID is stale — re-read it from 'xcrun simctl list devices available'"
  elif [[ "$state" != "Booted" ]]; then
    warn "sim $UDID is $state (will be booted on demand)"
  else
    ok "sim $UDID is Booted"
  fi
fi

# ---- 2. app installed -------------------------------------------------------
INSTALLED=""
if [[ -n "$UDID" ]]; then
  INSTALLED="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" app 2>/dev/null || true)"
  if [[ -z "$INSTALLED" ]]; then
    bad "$BUNDLE_ID is not installed on $UDID" "scripts/build-sim-for-simdrive.sh -u $UDID"
  else
    ok "app installed"
  fi
fi

# ---- 3. the installed app is really CODESIGNED, not linker-signed -----------
# A DerivedData / build-for-testing product carries the linker's automatic ad-hoc
# stamp: it prints "Signature=adhoc" but seals no resources. Its keychain fails
# -34018 and every download fails NSURLError -1 — failures that look like app or
# simulator bugs and are neither.
if [[ -n "$INSTALLED" ]]; then
  CS="$(codesign -dvv "$INSTALLED" 2>&1 || true)"
  if printf '%s' "$CS" | grep -qi "linker-signed"; then
    bad "installed app is LINKER-SIGNED (Sealed Resources=none)" \
        "you installed a DerivedData build product; install the one scripts/build-sim-for-simdrive.sh produces"
  elif ! printf '%s' "$CS" | grep -qi "Sealed Resources version"; then
    bad "installed app has no sealed resources" "rebuild with CODE_SIGNING_ALLOWED=YES via scripts/build-sim-for-simdrive.sh"
  else
    ok "app is codesigned with sealed resources"
  fi
  if [[ -d "$INSTALLED/PlugIns/PalaceTests.xctest" ]]; then
    warn "app bundles PalaceTests.xctest — this is a test-host build, not a release-shaped one"
  fi
fi

# ---- 4. app launches --------------------------------------------------------
if [[ -n "$INSTALLED" ]]; then
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  if LAUNCH="$(xcrun simctl launch "$UDID" "$BUNDLE_ID" 2>&1)"; then
    ok "app launches (${LAUNCH##* })"
  else
    bad "app failed to launch: $LAUNCH" "check the signature and the iOS version floor (deployment target is 17.0)"
  fi
fi

# ---- 5. simdrive can actually DRIVE it (the liveness proof) -----------------
# This is the check that matters. Everything above can pass while the driver is
# unable to observe or tap, which is what turns a campaign into a no-op.
if [[ -n "$UDID" && -n "$INSTALLED" ]]; then
  PROBE="$(python3 - "$UDID" "$BUNDLE_ID" <<'PY' 2>&1
import sys, tempfile, pathlib
udid, bid = sys.argv[1], sys.argv[2]
try:
    from simdrive import session, observe
except Exception as e:
    print("IMPORTFAIL " + str(e)); sys.exit(0)
sess = None
try:
    sess = session.start(udid=udid, app_bundle_id=bid)
    out = pathlib.Path(tempfile.mkdtemp(prefix="preflight-obs-"))
    obs = observe.observe(udid=udid, out_dir=out, annotate=False)
    marks = getattr(obs, "marks", None) or []
    print("MARKS %d" % len(marks))
except Exception as e:
    print("DRIVEFAIL %s: %s" % (type(e).__name__, e))
finally:
    try:
        if sess is not None:
            session.end(session_id=sess.session_id, terminate_app=False)
    except Exception:
        pass
PY
)"
  case "$PROBE" in
    MARKS\ 0)      bad "simdrive drove the app but observed 0 UI marks" "the app may be on a blank//loading screen; re-run after it settles" ;;
    MARKS\ *)      ok "simdrive drove the app and observed ${PROBE#MARKS } UI marks" ;;
    IMPORTFAIL*)   bad "cannot import the simdrive driver API: ${PROBE#IMPORTFAIL }" "check the installed simdrive exposes simdrive.session / simdrive.observe ('~/harness/bin/harness simdrive status'); a renamed API here means THIS script needs updating, not necessarily simdrive" ;;
    DRIVEFAIL*)    bad "simdrive could not drive the app: ${PROBE#DRIVEFAIL }" "run 'simdrive doctor'; check the sim is booted and the app launched" ;;
    *)             bad "simdrive probe returned something unexpected: $PROBE" "run the probe by hand to see the raw error" ;;
  esac
fi

# ---- 6. headless agent actually has its tools granted -----------------------
# The chaos orchestrator runs `claude -p`, which cannot approve a permission
# prompt. If the simdrive tools are not granted at the invocation, the agent is
# denied every call and the pass explores 0 paths while reporting cleanly.
if (( SKIP_AGENT )); then
  warn "skipped the headless-agent tool-grant probe (--skip-agent)"
elif ! command -v claude >/dev/null 2>&1; then
  bad "'claude' CLI not on PATH" "chaos passes invoke 'claude -p'; install the CLI or pass --skip-agent"
else
  if grep -q -- '--allowedTools' "$REPO_ROOT/scripts/run-chaos-pass.sh" 2>/dev/null; then
    ok "run-chaos-pass.sh declares --allowedTools for the subagent"
  else
    bad "run-chaos-pass.sh does not pass --allowedTools" \
        "the headless subagent will be denied every simdrive call and the pass will report 0 findings having run nothing"
  fi
fi

# ---- 7. replay corpus (informational, but loudly) ---------------------------
if [[ -f "$REPO_ROOT/.simdrive/regression-areas.json" ]]; then
  read -r NEED HAVE <<<"$(python3 - "$REPO_ROOT" <<'PY'
import json, os, sys
root = sys.argv[1]
man = json.load(open(os.path.join(root, ".simdrive/regression-areas.json")))
need = set()
for v in man["area_groups"].values():
    need |= set(v.get("journeys", []))
rec = os.path.expanduser("~/.simdrive/recordings")
have = set(os.listdir(rec)) if os.path.isdir(rec) else set()
print(len(need), len(need & have))
PY
)"
  if [[ "$HAVE" -eq 0 ]]; then
    warn "replay corpus EMPTY: 0 of $NEED manifest journeys have a local recording — journey replay will skip everything (chaos does not need recordings)"
  elif [[ "$HAVE" -lt "$NEED" ]]; then
    warn "replay corpus partial: $HAVE of $NEED manifest journeys have a local recording"
  else
    ok "replay corpus complete: $HAVE of $NEED journeys recorded"
  fi
fi

# ---- 8. area-group resolves ------------------------------------------------
if [[ -n "$AREA_GROUP" ]]; then
  if python3 "$REPO_ROOT/scripts/regression_findings.py" journeys \
       "$REPO_ROOT/.simdrive/regression-areas.json" "$AREA_GROUP" >/dev/null 2>&1; then
    ok "area-group '$AREA_GROUP' resolves in the manifest"
  else
    bad "area-group '$AREA_GROUP' is not in the manifest" \
        "valid groups: $(python3 "$REPO_ROOT/scripts/regression_findings.py" areas "$REPO_ROOT/.simdrive/regression-areas.json" 2>/dev/null | tr '\n' ' ')"
  fi
fi

echo
echo "=== preflight: $PASS passed, $WARN warned, $FAIL failed ==="
if (( FAIL > 0 )); then
  echo "DO NOT RUN THE CAMPAIGN. It would report a result it did not earn." >&2
  exit 1
fi
echo "Chain verified end-to-end — a campaign run now produces real evidence."
exit 0
