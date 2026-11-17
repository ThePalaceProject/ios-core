#!/bin/bash
# test_check_nodrm_app_excludes_audioengine.sh
# Verifies scripts/check-nodrm-app-excludes-audioengine.sh in BOTH directions:
# the clean product passes, each violation blocks, and "nothing to check" is a
# distinct exit (2), never a pass. A detector exercised only against violations
# passes while rejecting everything — so the first fixture is the clean one.
#
# otool is replaced by a fixture command through NODRM_CHECK_OTOOL so the test
# needs no built binary; the real-otool path is exercised by the NonDRM Build
# workflow against the product it just built.
# prior-art-checked: the harness has no product-inspection fixture to reuse.
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
DET="$DIR/../check-nodrm-app-excludes-audioengine.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
bad(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# A fixture otool: prints canned load commands for whatever binary it is given.
# The canned text is selected by the OTOOL_FIXTURE env var.
FAKE_OTOOL="$TMP/otool"
cat > "$FAKE_OTOOL" <<'EOF'
#!/bin/bash
case "${OTOOL_FIXTURE:-weak}" in
  weak)
    cat <<'OUT'
/tmp/Palace-noDRM.app/Frameworks/PalaceAudiobookToolkit.framework/PalaceAudiobookToolkit (architecture x86_64):
	@rpath/PalaceAudiobookToolkit.framework/PalaceAudiobookToolkit (compatibility version 1.0.0, current version 1.0.0)
	@rpath/AudioEngine.framework/AudioEngine (compatibility version 1.0.0, current version 1.0.0, weak)
	/System/Library/Frameworks/Foundation.framework/Foundation (compatibility version 300.0.0, current version 3200.0.0)
/tmp/Palace-noDRM.app/Frameworks/PalaceAudiobookToolkit.framework/PalaceAudiobookToolkit (architecture arm64):
	@rpath/PalaceAudiobookToolkit.framework/PalaceAudiobookToolkit (compatibility version 1.0.0, current version 1.0.0)
	@rpath/AudioEngine.framework/AudioEngine (compatibility version 1.0.0, current version 1.0.0, weak)
OUT
    ;;
  strong)
    cat <<'OUT'
/tmp/Palace-noDRM.app/Frameworks/PalaceAudiobookToolkit.framework/PalaceAudiobookToolkit:
	@rpath/PalaceAudiobookToolkit.framework/PalaceAudiobookToolkit (compatibility version 1.0.0, current version 1.0.0)
	@rpath/AudioEngine.framework/AudioEngine (compatibility version 1.0.0, current version 1.0.0)
OUT
    ;;
  one-slice-strong)
    cat <<'OUT'
/tmp/Palace-noDRM.app/Frameworks/PalaceAudiobookToolkit.framework/PalaceAudiobookToolkit (architecture x86_64):
	@rpath/AudioEngine.framework/AudioEngine (compatibility version 1.0.0, current version 1.0.0, weak)
/tmp/Palace-noDRM.app/Frameworks/PalaceAudiobookToolkit.framework/PalaceAudiobookToolkit (architecture arm64):
	@rpath/AudioEngine.framework/AudioEngine (compatibility version 1.0.0, current version 1.0.0)
OUT
    ;;
  absent)
    cat <<'OUT'
/tmp/Palace-noDRM.app/Frameworks/PalaceAudiobookToolkit.framework/PalaceAudiobookToolkit:
	@rpath/PalaceAudiobookToolkit.framework/PalaceAudiobookToolkit (compatibility version 1.0.0, current version 1.0.0)
	/System/Library/Frameworks/Foundation.framework/Foundation (compatibility version 300.0.0, current version 3200.0.0)
OUT
    ;;
  broken)
    echo "otool: fixture failure" 1>&2; exit 1
    ;;
esac
EOF
chmod +x "$FAKE_OTOOL"
export NODRM_CHECK_OTOOL="$FAKE_OTOOL"

make_app() {  # make_app <dir> [--with-audioengine] [--no-toolkit]
  local app="$1"; shift
  mkdir -p "$app/Frameworks/PalaceUIKit.framework"
  local toolkit=1 ae=0
  for f in "$@"; do
    [ "$f" = "--with-audioengine" ] && ae=1
    [ "$f" = "--no-toolkit" ] && toolkit=0
  done
  if [ "$toolkit" -eq 1 ]; then
    mkdir -p "$app/Frameworks/PalaceAudiobookToolkit.framework"
    printf 'not-a-real-binary' > "$app/Frameworks/PalaceAudiobookToolkit.framework/PalaceAudiobookToolkit"
  fi
  if [ "$ae" -eq 1 ]; then
    mkdir -p "$app/Frameworks/AudioEngine.framework"
    printf 'sdk' > "$app/Frameworks/AudioEngine.framework/AudioEngine"
  fi
}

# Fixture 1 — CLEAN product: no AudioEngine.framework, toolkit weak-links -> PASS (0).
make_app "$TMP/clean.app"
OTOOL_FIXTURE=weak "$DET" "$TMP/clean.app" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && ok "clean product passes (exit 0)" || bad "clean product blocked (exit $rc, want 0)"

# Fixture 2 — toolkit compiled with no AudioEngine reference at all -> PASS (0).
OTOOL_FIXTURE=absent "$DET" "$TMP/clean.app" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && ok "toolkit without any AudioEngine load command passes (exit 0)" || bad "absent load command wrongly blocked (exit $rc, want 0)"

# Fixture 3 — product EMBEDS AudioEngine.framework -> BLOCK (1).
make_app "$TMP/embeds.app" --with-audioengine
out="$(OTOOL_FIXTURE=weak "$DET" "$TMP/embeds.app" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && ok "embedded AudioEngine.framework blocked (exit 1)" || bad "embedded SDK not blocked (exit $rc, want 1)"
echo "$out" | grep -q "embeds Findaway's AudioEngine SDK" && ok "embed violation names the framework" || bad "embed violation message missing"

# Fixture 4 — AudioEngine.framework nested deeper than Frameworks/ -> BLOCK (1).
make_app "$TMP/nested.app"
mkdir -p "$TMP/nested.app/Frameworks/PalaceAudiobookToolkit.framework/Frameworks/AudioEngine.framework"
OTOOL_FIXTURE=weak "$DET" "$TMP/nested.app" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "nested AudioEngine.framework blocked (exit 1)" || bad "nested SDK not blocked (exit $rc, want 1)"

# Fixture 5 — toolkit links AudioEngine as REQUIRED -> BLOCK (1).
out="$(OTOOL_FIXTURE=strong "$DET" "$TMP/clean.app" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && ok "required (non-weak) AudioEngine link blocked (exit 1)" || bad "strong link not blocked (exit $rc, want 1)"
echo "$out" | grep -q "REQUIRED library" && ok "strong-link violation explains the dyld consequence" || bad "strong-link message missing"

# Fixture 6 — only ONE architecture slice links it strong -> BLOCK (1).
OTOOL_FIXTURE=one-slice-strong "$DET" "$TMP/clean.app" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "a single strong slice is enough to block (exit 1)" || bad "one-slice strong link not blocked (exit $rc, want 1)"

# Fixture 7 — both violations at once -> BLOCK (1), and BOTH are reported.
out="$(OTOOL_FIXTURE=strong "$DET" "$TMP/embeds.app" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && echo "$out" | grep -q "embeds Findaway" && echo "$out" | grep -q "REQUIRED library" \
  && ok "both violations reported in one run" || bad "combined violations not both reported (exit $rc)"

# Fixture 8 — missing argument -> usage (2).
"$DET" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "missing arg -> exit 2" || bad "missing arg wrong exit ($rc, want 2)"

# Fixture 9 — app path does not exist -> cannot judge (2), NOT a pass.
"$DET" "$TMP/does-not-exist.app" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "absent product -> exit 2 (not a pass)" || bad "absent product wrong exit ($rc, want 2)"

# Fixture 10 — toolkit binary absent inside the app -> cannot judge (2).
make_app "$TMP/notoolkit.app" --no-toolkit
"$DET" "$TMP/notoolkit.app" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "missing toolkit binary -> exit 2 (not a pass)" || bad "missing toolkit wrong exit ($rc, want 2)"

# Fixture 11 — otool itself fails -> cannot judge (2), NOT a pass.
OTOOL_FIXTURE=broken "$DET" "$TMP/clean.app" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "otool failure -> exit 2 (not a pass)" || bad "otool failure wrong exit ($rc, want 2)"

echo "[test_check_nodrm_app_excludes_audioengine] $PASS passed / $FAIL failed"
[ "$FAIL" -eq 0 ]
