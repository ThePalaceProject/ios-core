#!/bin/bash
# test_check_objc_witness_nearly_matches.sh
# Verifies the @objc-witness-drift detector: blocks same-name witness drift,
# passes benign different-name "nearly matches", passes clean logs, honors allowlist.
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
DET="$DIR/../check-objc-witness-nearly-matches.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
bad(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# Fixture 1 — TRUE witness drift: candidate name == requirement name -> BLOCK (exit 1).
cat > "$TMP/drift.log" <<'EOF'
/src/SignInWebViewCoordinator.swift:50:10: warning: instance method 'webView(_:decidePolicyFor:decisionHandler:)' nearly matches optional requirement 'webView(_:decidePolicyFor:decisionHandler:)' of protocol 'WKNavigationDelegate'
/src/SignInWebViewCoordinator.swift:50:10: note: candidate has non-matching type '(WKWebView, WKNavigationAction, @escaping (WKNavigationActionPolicy) -> Void) -> ()'
EOF
"$DET" "$TMP/drift.log" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "same-name witness drift blocked (exit 1)" || bad "drift not blocked (exit $rc, want 1)"

# Fixture 2 — BENIGN different-name nearly-matches (CarPlay didDisconnect≈didSelect) -> PASS (exit 0).
cat > "$TMP/benign.log" <<'EOF'
/src/CarPlaySceneDelegate.swift:75:10: warning: instance method 'templateApplicationScene(_:didDisconnect:)' nearly matches optional requirement 'templateApplicationScene(_:didSelect:)' of protocol 'CPTemplateApplicationSceneDelegate'
EOF
"$DET" "$TMP/benign.log" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && ok "benign different-name nearly-match allowed (exit 0)" || bad "benign case wrongly blocked (exit $rc, want 0)"

# Fixture 3 — clean log (no nearly-matches) -> PASS (exit 0).
cat > "$TMP/clean.log" <<'EOF'
Compiling SignInWebViewCoordinator.swift
** TEST BUILD SUCCEEDED **
EOF
"$DET" "$TMP/clean.log" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && ok "clean log passes (exit 0)" || bad "clean log wrongly blocked (exit $rc)"

# Fixture 4 — allowlisted drift -> PASS (exit 0).
echo "SignInWebViewCoordinator.swift" > "$TMP/allow.txt"
OBJC_WITNESS_ALLOWLIST="$TMP/allow.txt" "$DET" "$TMP/drift.log" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && ok "allowlisted drift suppressed (exit 0)" || bad "allowlist not honored (exit $rc, want 0)"

# Fixture 5 — missing log arg -> usage error (exit 2).
"$DET" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "missing arg -> usage error (exit 2)" || bad "missing arg wrong exit ($rc, want 2)"

echo "[test_check_objc_witness_nearly_matches] $PASS passed / $FAIL failed"
[ "$FAIL" -eq 0 ]
