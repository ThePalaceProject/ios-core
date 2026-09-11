#!/bin/bash
# test_nodrm_build_inputs.sh
# Behavioural tests for the two scripts that put AudioEngine.xcframework where
# PalaceAudiobookToolkit links it, on the --no-private (noDRM) path:
#
#   scripts/build-carthage.sh    must run fetch-audioengine.sh WITH --no-private
#                                (and still run AddLCP + fetch without it)
#   scripts/fetch-audioengine.sh must leave Carthage/Build/AudioEngine.xcframework
#                                in place, and must exit non-zero when the
#                                download fails (it used to exit 0 there).
#
# Each script is run for real inside a throwaway tree, with `carthage`, `swift`
# and `curl` replaced by PATH stubs that record their calls. No network, no
# Xcode. The assertions are on what the scripts DO — a moved line, a dropped
# `set -e`, or a `--no-private` guard grown back around the fetch each fail one.
# prior-art-checked: nothing in the harness exercises these public build scripts.
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$(cd "$DIR/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
bad(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# ---------- a sandbox repo root with stubbed tools on PATH -------------------
# build-carthage.sh calls ./scripts/fetch-audioengine.sh by relative path and
# `rm -rf ~/Library/Caches/...`, so it runs from a fake root with a fake HOME.
make_root() {  # make_root <dir>
  local root="$1"
  mkdir -p "$root/scripts" "$root/bin" "$root/home" "$root/mobile-certificates/Certificates/Palace/iOS"
  cp "$SCRIPTS/build-carthage.sh" "$root/scripts/"
  touch "$root/Cartfile" "$root/Cartfile.resolved"
  : > "$root/mobile-certificates/Certificates/Palace/iOS/AddLCP.swift"
  # fetch-audioengine stub: records that it ran, in the file the assertions read.
  cat > "$root/scripts/fetch-audioengine.sh" <<'EOF'
#!/bin/bash
echo "fetch-audioengine ran" >> "$STUB_LOG"
EOF
  chmod +x "$root/scripts/fetch-audioengine.sh"
  # carthage / swift stubs.
  printf '#!/bin/bash\necho "carthage $*" >> "$STUB_LOG"\n' > "$root/bin/carthage"
  printf '#!/bin/bash\necho "swift $*" >> "$STUB_LOG"\n' > "$root/bin/swift"
  chmod +x "$root/bin/carthage" "$root/bin/swift"
}

run_build_carthage() {  # run_build_carthage <root> [args...]
  local root="$1"; shift
  ( cd "$root" && STUB_LOG="$root/calls.log" HOME="$root/home" PATH="$root/bin:$PATH" \
      bash scripts/build-carthage.sh "$@" ) >"$root/out.log" 2>&1
}

# Case 1 — --no-private still fetches AudioEngine (the noDRM build's link input),
# runs carthage, and does NOT touch the private AddLCP step.
make_root "$TMP/nodrm"
run_build_carthage "$TMP/nodrm" --no-private; rc=$?
[ "$rc" -eq 0 ] && ok "--no-private: build-carthage exits 0" || { bad "--no-private: exit $rc"; cat "$TMP/nodrm/out.log"; }
grep -q "fetch-audioengine ran" "$TMP/nodrm/calls.log" \
  && ok "--no-private: fetch-audioengine.sh ran" || bad "--no-private: fetch-audioengine.sh did NOT run (the noDRM link input is missing again)"
grep -q "^swift " "$TMP/nodrm/calls.log" \
  && bad "--no-private: AddLCP (swift) ran — private step leaked into the open build" || ok "--no-private: AddLCP skipped"
grep -q "^carthage bootstrap" "$TMP/nodrm/calls.log" \
  && ok "--no-private: carthage bootstrap ran" || bad "--no-private: carthage bootstrap did not run"

# Case 2 — the fetch runs BEFORE carthage (order is what a reader relies on: the
# xcframework must be in Carthage/Build before anything consumes that folder).
fetch_line="$(grep -n "fetch-audioengine ran" "$TMP/nodrm/calls.log" | cut -d: -f1 | head -1)"
carthage_line="$(grep -n "^carthage bootstrap" "$TMP/nodrm/calls.log" | cut -d: -f1 | head -1)"
[ -n "$fetch_line" ] && [ -n "$carthage_line" ] && [ "$fetch_line" -lt "$carthage_line" ] \
  && ok "--no-private: fetch happens before carthage bootstrap" || bad "--no-private: fetch/carthage order wrong ($fetch_line vs $carthage_line)"

# Case 3 — DRM path (no flag): AddLCP AND fetch both run.
make_root "$TMP/drm"
run_build_carthage "$TMP/drm"; rc=$?
[ "$rc" -eq 0 ] && ok "drm: build-carthage exits 0" || { bad "drm: exit $rc"; cat "$TMP/drm/out.log"; }
grep -q "^swift .*AddLCP.swift" "$TMP/drm/calls.log" && ok "drm: AddLCP ran" || bad "drm: AddLCP did not run"
grep -q "fetch-audioengine ran" "$TMP/drm/calls.log" && ok "drm: fetch-audioengine.sh ran" || bad "drm: fetch-audioengine.sh did not run"

# Case 4 — a failing fetch fails build-carthage (set -e must still cover it).
make_root "$TMP/fetchfail"
printf '#!/bin/bash\nexit 22\n' > "$TMP/fetchfail/scripts/fetch-audioengine.sh"
run_build_carthage "$TMP/fetchfail" --no-private; rc=$?
[ "$rc" -ne 0 ] && ok "--no-private: a failing fetch fails build-carthage (exit $rc)" || bad "--no-private: failing fetch was swallowed (exit 0)"
grep -q "^carthage" "$TMP/fetchfail/calls.log" 2>/dev/null \
  && bad "--no-private: carthage ran after the fetch failed" || ok "--no-private: carthage not reached after a failed fetch"

# ---------- fetch-audioengine.sh, for real, with curl stubbed -----------------
# The stub curl writes a zip shaped like Findaway's: AudioEngine/ containing
# AudioEngine.xcframework/ (with a slice) plus Licenses/. `-o <file>` is honored.
make_fetch_root() {  # make_fetch_root <dir> <curl-mode: ok|fail|empty>
  local root="$1" mode="$2"
  mkdir -p "$root/scripts" "$root/bin"
  cp "$SCRIPTS/fetch-audioengine.sh" "$root/scripts/"
  # Build the fixture archive once per root.
  ( cd "$root" && mkdir -p AudioEngine/AudioEngine.xcframework/ios-arm64_x86_64-simulator/AudioEngine.framework AudioEngine/Licenses \
      && printf 'plist' > AudioEngine/AudioEngine.xcframework/Info.plist \
      && printf 'bin' > AudioEngine/AudioEngine.xcframework/ios-arm64_x86_64-simulator/AudioEngine.framework/AudioEngine \
      && printf 'MIT' > AudioEngine/Licenses/FBKVOController.txt \
      && zip -q -r fixture.zip AudioEngine && rm -rf AudioEngine )
  cat > "$root/bin/curl" <<EOF
#!/bin/bash
# accept: -fsSL -o <out> <url>
out=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) out="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
case "$mode" in
  ok)    cp "$root/fixture.zip" "\$out" ;;
  fail)  exit 22 ;;                       # curl -f on HTTP 404
  empty) : > "\$out" ;;                    # 200 with an empty body
esac
EOF
  chmod +x "$root/bin/curl"
}

run_fetch() {  # run_fetch <root>
  local root="$1"
  ( cd "$root" && PATH="$root/bin:$PATH" bash scripts/fetch-audioengine.sh ) >"$root/out.log" 2>&1
}

# Case 5 — happy path: xcframework lands in Carthage/Build, scratch is cleaned up.
make_fetch_root "$TMP/fetch-ok" ok
run_fetch "$TMP/fetch-ok"; rc=$?
[ "$rc" -eq 0 ] && ok "fetch: exits 0 on a good download" || { bad "fetch: exit $rc on a good download"; cat "$TMP/fetch-ok/out.log"; }
[ -f "$TMP/fetch-ok/Carthage/Build/AudioEngine.xcframework/Info.plist" ] \
  && ok "fetch: Carthage/Build/AudioEngine.xcframework is in place" || bad "fetch: xcframework not where the toolkit links it"
[ ! -e "$TMP/fetch-ok/AudioEngine" ] && [ ! -e "$TMP/fetch-ok/AudioEngine6.5.6.zip" ] \
  && ok "fetch: scratch dir and zip removed" || bad "fetch: left AudioEngine/ or the zip behind"

# Case 6 — re-run over an existing Carthage/Build (build-carthage wipes it, but
# a hand run must not hang on an unzip overwrite prompt or fail on mv).
run_fetch "$TMP/fetch-ok"; rc=$?
[ "$rc" -eq 0 ] && ok "fetch: second run over existing output exits 0" || { bad "fetch: second run failed (exit $rc)"; cat "$TMP/fetch-ok/out.log"; }

# Case 7 — HTTP failure: must exit non-zero and leave no xcframework.
make_fetch_root "$TMP/fetch-fail" fail
run_fetch "$TMP/fetch-fail"; rc=$?
[ "$rc" -ne 0 ] && ok "fetch: failed download exits non-zero ($rc)" || bad "fetch: failed download exited 0 (the silent-pass shape)"
[ ! -e "$TMP/fetch-fail/Carthage/Build/AudioEngine.xcframework" ] \
  && ok "fetch: no xcframework after a failed download" || bad "fetch: xcframework present after a failed download"

# Case 8 — 200 with an empty/corrupt body: unzip fails, script must not exit 0.
make_fetch_root "$TMP/fetch-empty" empty
run_fetch "$TMP/fetch-empty"; rc=$?
[ "$rc" -ne 0 ] && ok "fetch: corrupt archive exits non-zero ($rc)" || bad "fetch: corrupt archive exited 0"

echo "[test_nodrm_build_inputs] $PASS passed / $FAIL failed"
[ "$FAIL" -eq 0 ]
