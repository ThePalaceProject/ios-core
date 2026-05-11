#!/usr/bin/env bash
# Phase 0 of the regression suite: cred + device + in-field signal pre-flight.
#
# Emits to <output-dir>/preflight/:
#   creds-matrix.md   — auth-coverage matrix vs harness vault
#   devices.md        — paired devices + WDA bootstrap status
#   MUST_TEST.md      — in-field signal (Crashlytics + HelpSpot + CM)
#
# Exit:
#   0  — pre-flight clean (>=5 auth coverable AND >=1 device-leg-ready)
#   1  — soft fail (<5 auth or 0 devices) — emits warning, doesn't block
#   2  — hard fail (no harness, no MCP, malformed args)
#
# Usage:
#   scripts/regression/preflight.sh --output-dir ~/Desktop/regression-PP-XXXX \
#                                   --baseline-version 3.0.0
set -uo pipefail

OUTPUT_DIR=""
BASELINE_VERSION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    --baseline-version) BASELINE_VERSION="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^set -u/p' "$0" | sed -n 's/^# \?//p'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -z "$OUTPUT_DIR" ]] && { echo "missing --output-dir" >&2; exit 2; }
[[ -z "$BASELINE_VERSION" ]] && { echo "missing --baseline-version" >&2; exit 2; }
PREFLIGHT_DIR="$OUTPUT_DIR/preflight"
mkdir -p "$PREFLIGHT_DIR"

soft_fail=0

# ------------------- 1. Cred-availability matrix -------------------
auth_matrix() {
  cat <<'EOF'
| Auth type | Test library | Harness vault key | Status |
|-----------|--------------|-------------------|--------|
EOF
  # Each row: type, library, vault key
  rows=(
    "basic|A1QA Test Library|palace-ios.lib.a1qa"
    "token|Lyrasis Reads|palace-ios.lib.lyrasis-reads"
    "oauthIntermediary|NYPL Clever|MANUAL"
    "saml|Academic / BiblioCommons|MANUAL"
    "oidc|Palace OIDC test|MANUAL"
    "anonymous|Palace Bookshelf|N/A"
    "coppa|Open eBooks|N/A"
  )

  if command -v ~/harness/bin/harness >/dev/null 2>&1; then
    creds_list="$(~/harness/bin/harness creds list 2>/dev/null || true)"
  else
    creds_list=""
  fi

  coverable=0
  for row in "${rows[@]}"; do
    IFS='|' read -r typ lib key <<<"$row"
    if [[ "$key" == "MANUAL" ]]; then
      status="MANUAL — needs human + IdP"
    elif [[ "$key" == "N/A" ]]; then
      status="✅ no-cred (anonymous-class)"
      coverable=$((coverable + 1))
    elif grep -q "^$key$" <<<"$creds_list"; then
      status="✅ vault-key present"
      coverable=$((coverable + 1))
    else
      status="❌ vault-key missing"
    fi
    printf "| %s | %s | %s | %s |\n" "$typ" "$lib" "$key" "$status"
  done

  echo
  echo "**Coverable auth types:** $coverable / 7"
  if [[ $coverable -lt 5 ]]; then
    echo
    echo "🚨 **Below 5-of-7 minimum.** TEST_MATRIX mandates at minimum: basic, token, saml, oidc, anonymous. Phase-3 manual flow needs human + IdP for every MANUAL row above."
    return 1
  fi
  return 0
}

{
  echo "# Auth Coverage Matrix"
  echo
  echo "**Generated:** $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  auth_matrix || soft_fail=1
} > "$PREFLIGHT_DIR/creds-matrix.md"

# ------------------- 2. Device-availability -------------------
{
  echo "# Paired Real-Device Status"
  echo
  echo "**Generated:** $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo

  if ! command -v xcrun >/dev/null 2>&1; then
    echo "🚨 \`xcrun\` not on PATH — cannot enumerate devices."
    soft_fail=1
  else
    devices_count=0
    while IFS= read -r line; do
      # devicectl line format: "Name | Hostname | UUID | State | Model"
      [[ -z "$line" ]] && continue
      [[ "$line" =~ ^Name|^----- ]] && continue
      [[ ! "$line" =~ available|connected ]] && continue
      udid="$(awk '{print $(NF-2)}' <<<"$line")"
      [[ ! "$udid" =~ ^[0-9A-F-]+$ ]] && continue
      name="$(awk '{print $1}' <<<"$line")"

      # Hardware UDID (8-4 form) lives in ~/.simdrive/wda/<udid>.json
      # Try both the coredevice UUID and the hw UDID
      wda_json=""
      for f in ~/.simdrive/wda/*.json; do
        [[ -f "$f" ]] || continue
        if grep -q "\"coredevice_uuid\":\\s*\"$udid\"" "$f" 2>/dev/null; then
          wda_json="$f"
          break
        fi
      done

      if [[ -n "$wda_json" ]]; then
        last_built="$(grep last_built_at "$wda_json" | head -1 | cut -d'"' -f4)"
        if grep -q '"xctestrun_path"' "$wda_json"; then
          status="✅ ready (a8-format registry, last_built=$last_built)"
        else
          status="⚠️  needs-rebootstrap (a7-format registry; wda-up rejects without xctestrun_path)"
        fi
      else
        status="❌ no-bootstrap — \`simdrive bootstrap-device $udid --team-id <ID>\` required (Xcode Apple Account must be signed in)"
      fi
      printf -- "- **%s** (%s) — %s\n" "$name" "$udid" "$status"
      devices_count=$((devices_count + 1))
    done < <(xcrun devicectl list devices 2>/dev/null | tr -s ' ')

    echo
    if [[ $devices_count -eq 0 ]]; then
      echo "🚨 No paired devices found. Real-device leg cannot run."
      soft_fail=1
    else
      echo "**Paired devices:** $devices_count (filter: available/connected only)"
    fi
  fi
} > "$PREFLIGHT_DIR/devices.md"

# ------------------- 3. In-field signal (MCP-fed; placeholder hooks) -------------------
{
  echo "# Must-Test — In-Field Signal vs Baseline $BASELINE_VERSION"
  echo
  echo "**Generated:** $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  echo "Bias the Phase-3 manual walk toward areas users are reporting on $BASELINE_VERSION. The agent should populate these sections via MCP at runtime — this script lays out the structure."
  echo
  echo "## Top Crashlytics events ($BASELINE_VERSION)"
  echo "_To populate: \`mcp__firebase__crashlytics_list_events\` filtered by app version $BASELINE_VERSION, top 5 by impacted users._"
  echo
  echo "- [ ] Stub — fill from MCP at run time"
  echo
  echo "## Top HelpSpot tickets ($BASELINE_VERSION)"
  echo "_To populate: \`mcp__helpspot__helpspot_list_by_filter\` for filter open/iOS/$BASELINE_VERSION, top 5 by recency._"
  echo
  echo "- [ ] Stub — fill from MCP at run time"
  echo
  echo "## Circulation Manager contract drift since $BASELINE_VERSION"
  echo "_To populate: \`mcp__palace-cm-monitor__cm_drift\`._"
  echo
  echo "- [ ] Stub — fill from MCP at run time"
  echo
  echo "## Top areas to scrutinize"
  echo
  echo "_Computed from the union of the three signal sources. Empty until the agent populates the sources above._"
} > "$PREFLIGHT_DIR/MUST_TEST.md"

# ------------------- summary -------------------
echo "Pre-flight artifacts:"
echo "  $PREFLIGHT_DIR/creds-matrix.md"
echo "  $PREFLIGHT_DIR/devices.md"
echo "  $PREFLIGHT_DIR/MUST_TEST.md"

[[ $soft_fail -eq 1 ]] && exit 1
exit 0
