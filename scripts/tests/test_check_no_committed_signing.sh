#!/bin/bash
# test_check_no_committed_signing.sh — verify the committed-signing gate.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
DET="$DIR/../check-no-committed-signing.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
bad(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# 1 — adds CODE_SIGN_STYLE = Automatic -> BLOCK
cat > "$TMP/a.diff" <<'EOF'
diff --git a/Palace.xcodeproj/project.pbxproj b/Palace.xcodeproj/project.pbxproj
--- a/Palace.xcodeproj/project.pbxproj
+++ b/Palace.xcodeproj/project.pbxproj
@@ -1 +1 @@
+				CODE_SIGN_STYLE = Automatic;
EOF
"$DET" "$TMP/a.diff" >/dev/null 2>&1; [ $? -eq 1 ] && ok "Automatic style blocked" || bad "Automatic not blocked"

# 2 — adds a real DEVELOPMENT_TEAM -> BLOCK
cat > "$TMP/t.diff" <<'EOF'
+++ b/Palace.xcodeproj/project.pbxproj
+				DEVELOPMENT_TEAM = 88CBA74T8K;
EOF
"$DET" "$TMP/t.diff" >/dev/null 2>&1; [ $? -eq 1 ] && ok "real DEVELOPMENT_TEAM blocked" || bad "team id not blocked"

# 3 — adds a provisioning profile UUID -> BLOCK
cat > "$TMP/p.diff" <<'EOF'
+++ b/Palace.xcodeproj/project.pbxproj
+				PROVISIONING_PROFILE = "b3d9154d-70e1-48d6-a0c5-869431277a5c";
EOF
"$DET" "$TMP/p.diff" >/dev/null 2>&1; [ $? -eq 1 ] && ok "provisioning UUID blocked" || bad "profile uuid not blocked"

# 4 — adds a BLANK team ("") + Manual -> PASS (the allowed target state)
cat > "$TMP/blank.diff" <<'EOF'
+++ b/Palace.xcodeproj/project.pbxproj
+				CODE_SIGN_STYLE = Manual;
+				DEVELOPMENT_TEAM = "";
+				PROVISIONING_PROFILE_SPECIFIER = "";
EOF
"$DET" "$TMP/blank.diff" >/dev/null 2>&1; [ $? -eq 0 ] && ok "blank team + Manual allowed" || bad "blank/Manual wrongly blocked"

# 5 — REMOVING signing (- lines) -> PASS (only added lines matter)
cat > "$TMP/rm.diff" <<'EOF'
+++ b/Palace.xcodeproj/project.pbxproj
-				DEVELOPMENT_TEAM = 88CBA74T8K;
-				CODE_SIGN_STYLE = Automatic;
EOF
"$DET" "$TMP/rm.diff" >/dev/null 2>&1; [ $? -eq 0 ] && ok "removing signing allowed" || bad "removal wrongly blocked"

# 6 — unrelated diff -> PASS
cat > "$TMP/clean.diff" <<'EOF'
+++ b/Palace/Foo.swift
+    let x = 1
EOF
"$DET" "$TMP/clean.diff" >/dev/null 2>&1; [ $? -eq 0 ] && ok "unrelated diff passes" || bad "clean diff wrongly blocked"

# 7 — allowlisted team -> PASS
echo "88CBA74T8K" > "$TMP/allow.txt"
NO_SIGNING_ALLOWLIST="$TMP/allow.txt" "$DET" "$TMP/t.diff" >/dev/null 2>&1; [ $? -eq 0 ] && ok "allowlisted team suppressed" || bad "allowlist not honored"

# 8 — team ID in an .xcconfig (NO trailing semicolon) -> BLOCK (the xcconfig gap)
cat > "$TMP/xcconfig.diff" <<'EOF'
+++ b/Signing.xcconfig
+DEVELOPMENT_TEAM = 88CBA74T8K
EOF
"$DET" "$TMP/xcconfig.diff" >/dev/null 2>&1; [ $? -eq 1 ] && ok "xcconfig team id (no semicolon) blocked" || bad "xcconfig team id slipped through"

# 9 — signing-looking strings in a NON-build file (this detector's own test/docs)
#     -> PASS. Proves path-awareness: fixtures/docs must not self-trigger the gate.
cat > "$TMP/selftest.diff" <<'EOF'
+++ b/scripts/tests/test_check_no_committed_signing.sh
+CODE_SIGN_STYLE = Automatic;
+DEVELOPMENT_TEAM = 88CBA74T8K;
+PROVISIONING_PROFILE = "b3d9154d-70e1-48d6-a0c5-869431277a5c";
EOF
"$DET" "$TMP/selftest.diff" >/dev/null 2>&1; [ $? -eq 0 ] && ok "signing strings in non-build file ignored (no self-block)" || bad "path-blind: flagged a non-build file"

# 10 — QUOTED team id in a pbxproj (Xcode emits `DEVELOPMENT_TEAM = "ABCDE12345";`
#      in some configs) -> BLOCK. The unquoted rule missed this form.
cat > "$TMP/quoted.diff" <<'EOF'
+++ b/Palace.xcodeproj/project.pbxproj
+				DEVELOPMENT_TEAM = "88CBA74T8K";
EOF
"$DET" "$TMP/quoted.diff" >/dev/null 2>&1; [ $? -eq 1 ] && ok "quoted DEVELOPMENT_TEAM blocked" || bad "quoted team id slipped through"

echo "[test_check_no_committed_signing] $PASS passed / $FAIL failed"
[ "$FAIL" -eq 0 ]
