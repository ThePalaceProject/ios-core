#!/usr/bin/env bash
# build-sim-for-simdrive.sh — produce a LAUNCHABLE, sign-in + download-capable
# Palace build for the iOS Simulator, install it, and verify it, so simdrive
# (host-AX / HID) can drive AUTHENTICATED flows end-to-end:
# sign-in → borrow → download → play.
#
# ─────────────────────────────────────────────────────────────────────────────
# WHY THIS EXISTS (hard-won — do NOT re-derive; ~a day was spent here)
# ─────────────────────────────────────────────────────────────────────────────
# The ONE thing that matters is that the app is actually code-SIGNED. A properly
# ad-hoc-signed simulator build (CODE_SIGN_IDENTITY="-", CODE_SIGNING_ALLOWED=YES)
# launches AND its keychain works AND it downloads — verified live 2026-06-23:
# A1QA sign-in persisted (8× SecItemAdd succeeded, zero -34018), an authenticated
# audiobook fulfilled+downloaded+played, and a free EPUB downloaded — no
# NSURLError -1. Empty entitlements are FINE; the simulator does not require a
# keychain-access-group for a *signed* app.
#
# The two ways to get this WRONG (both cost real time):
#   1. CODE_SIGNING_ALLOWED=NO  →  codesign is SKIPPED → the app is UNSIGNED.
#      It still launches, but the keychain fails errSecMissingEntitlement
#      (-34018) so sign-in never persists (every request 401s) AND the
#      background download fails NSURLErrorDomain Code=-1. (We once mis-blamed
#      this on a "sim background-URLSession limitation" — WRONG; it was the
#      missing signature. -34018 and -1 share that one root.)
#   2. Trying to ADD a keychain-access-groups entitlement (via
#      CODE_SIGN_ENTITLEMENTS or post-hoc `codesign --entitlements`, ad-hoc OR a
#      real cert, ±--deep) → the iOS 26 simulator REFUSES TO LAUNCH it
#      ("SBMainWorkspace … denied by service delegate"). You don't need the
#      entitlement at all — a signed app's keychain already works on the sim.
#      So: never declare keychain entitlements for a CLI sim build.
#
# Also: build into a DEDICATED fresh derived-data dir. Reusing one DD across
# different signing configs corrupts the module cache → bogus compile errors
# (e.g. a spurious "RDServicesStubs.m" failure that is really a stale PCH).
#
# ─────────────────────────────────────────────────────────────────────────────
# USAGE
#   scripts/build-sim-for-simdrive.sh [-u <sim-udid>] [-d <derived-data-dir>]
#                                     [--no-install] [--no-launch]
#   -u  Target simulator UDID. If given, the built .app is installed (and a
#       launch-smoke is run unless --no-launch). If omitted, build + verify only.
#   -d  Derived-data dir (default: /tmp/palace-sim-build). Wiped before building.
#   --no-install   Build only.
#   --no-launch    Install but skip the launch-smoke.
#
# On success prints the .app path + bundle id + UDID — hand those to simdrive:
#   session_start(device_udid=<udid>, app_bundle_id=org.thepalaceproject.palace)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# Genuine build-for-install (NOT a test on a shared sim) with an explicit
# isolated derivedDataPath — exempt from the harness raw-xcodebuild redirect.
# Paper trail for the guardrail hook:
export SKIP_XCODEBUILD_REDIRECT=1

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="${PALACE_PROJECT:-Palace.xcodeproj}"
SCHEME="${PALACE_SCHEME:-Palace}"
CONFIG="${PALACE_CONFIG:-Debug}"
BUNDLE_ID="${PALACE_BUNDLE_ID:-org.thepalaceproject.palace}"
DERIVED_DATA="/tmp/palace-sim-build"
UDID=""
DO_INSTALL=1
DO_LAUNCH=1

while [ $# -gt 0 ]; do
  case "$1" in
    -u) UDID="$2"; shift 2 ;;
    -d) DERIVED_DATA="$2"; shift 2 ;;
    --no-install) DO_INSTALL=0; shift ;;
    --no-launch)  DO_LAUNCH=0; shift ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "✗ unknown arg: $1" >&2; exit 2 ;;
  esac
done

say() { printf '\n\033[1;36m▸ %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# ── 1. build ad-hoc (SIGNED) into a DEDICATED fresh derived-data dir ──────────
say "Building $SCHEME ($CONFIG) for the iOS Simulator — ad-hoc sign, fresh DD ($DERIVED_DATA)"
rm -rf "$DERIVED_DATA"
LOG="$DERIVED_DATA.build.log"
mkdir -p "$DERIVED_DATA"
set +e
xcodebuild build \
  -project "$REPO_ROOT/$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="" \
  > "$LOG" 2>&1
RC=$?
set -e
if [ "$RC" != "0" ]; then
  echo "--- last 12 build-log lines ---" >&2
  tail -12 "$LOG" >&2
  die "Build failed (rc=$RC). Full log: $LOG"
fi
APP="$DERIVED_DATA/Build/Products/${CONFIG}-iphonesimulator/Palace.app"
[ -d "$APP" ] || die "Build reported success but $APP is missing."
echo "  ✓ BUILD SUCCEEDED → $APP"

# ── 2. PRE-FLIGHT GATE: the app must actually be SIGNED ───────────────────────
# A signed app is what makes keychain + download work on the sim; an UNSIGNED
# app (CODE_SIGNING_ALLOWED=NO) launches but -34018s / -1s. Verify there is a
# code signature before handing it to simdrive.
say "Pre-flight gate: verifying the app is code-signed"
# Capture FIRST, match second. This gate used to be
#   codesign -dvv "$APP" 2>&1 | grep -qiE ...
# which fails NON-DETERMINISTICALLY under this script's `set -euo pipefail`:
# `grep -q` exits the instant it matches, `codesign` then dies on SIGPIPE (141),
# and pipefail propagates that 141 to the `if`, so a CORRECTLY ad-hoc-signed app
# reports "NOT signed" and the build is thrown away. Measured 3 failures in 5 runs
# against an app that `codesign --verify` calls valid on disk. Whether it trips is
# a scheduling race between grep exiting and codesign finishing its write, so it
# looks like a flaky toolchain rather than a bug in this line.
# Keep the command substitution: it has no pipeline, so there is no exit code to
# misread. Do not "simplify" it back into a pipe.
CODESIGN_OUT="$(codesign -dvv "$APP" 2>&1 || true)"
# "Signature=adhoc" alone is NOT sufficient. The linker stamps an automatic ad-hoc
# signature on the Mach-O of any simulator build, so an UNSIGNED bundle still
# reports Signature=adhoc and passes a naive substring test. The difference is the
# BUNDLE: a real codesign pass seals the resources and writes
# _CodeSignature/CodeResources; the linker's stamp does neither and additionally
# flags itself `linker-signed`.
#
#   properly signed : flags=0x2(adhoc)              Sealed Resources version=2 ... 354 files
#   linker-signed   : flags=0x20002(adhoc,linker-signed)  Sealed Resources=none
#
# Only the second form -34018s the keychain and -1s downloads, which is precisely
# the failure this gate exists to prevent — so the old predicate was blind to the
# only case that matters. Caught when a chaos QA pass ran against a DerivedData
# test-host build, hit NSURLError -1 on every fulfill request, and attributed it to
# "the simulator's background NSURLSession XPC service" instead of to the signature.
# Require all three: adhoc/authority, sealed resources, and NOT linker-signed.
if printf '%s' "$CODESIGN_OUT" | grep -qiE "signature=adhoc|authority=|\(adhoc\)" \
   && printf '%s' "$CODESIGN_OUT" | grep -qi "Sealed Resources version" \
   && ! printf '%s' "$CODESIGN_OUT" | grep -qi "linker-signed"; then
  echo "  ✓ signed + resources sealed (keychain + download will work on the sim)"
else
  echo "$CODESIGN_OUT" >&2
  if printf '%s' "$CODESIGN_OUT" | grep -qi "linker-signed"; then
    die "App is LINKER-SIGNED, not codesigned (Sealed Resources=none) — the keychain will
-34018 and downloads will fail NSURLError -1. This is what you get from a
DerivedData build product or a build-for-testing artifact. Install the app this
script builds, not the one under ~/Library/Developer/Xcode/DerivedData."
  fi
  die "App is NOT signed — keychain will -34018 and downloads will -1. Rebuild with CODE_SIGNING_ALLOWED=YES."
fi

# ── 3. install + seed dev settings + launch-smoke ─────────────────────────────
if [ "$DO_INSTALL" = "1" ] && [ -n "$UDID" ]; then
  say "Installing on sim $UDID"
  xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || xcrun simctl boot "$UDID" 2>/dev/null || true
  xcrun simctl install "$UDID" "$APP"
  echo "  ✓ installed"

  # Reveal the in-app Developer Settings menu (which hosts the load-bearing
  # "Enable Hidden Libraries" toggle needed to add the A1QA test library). The
  # menu is gated on @AppStorage("showDeveloperSettings"); seed it ON. NOTE: the
  # toggle itself still must be flipped in-app — it fires the QA-registry refetch
  # that the simctl default alone does not.
  say "Seeding showDeveloperSettings=YES (reveals the Enable Hidden Libraries toggle)"
  xcrun simctl spawn "$UDID" defaults write "$BUNDLE_ID" showDeveloperSettings -bool YES 2>/dev/null \
    && echo "  ✓ showDeveloperSettings seeded (relaunch to take effect)" \
    || echo "  (could not seed showDeveloperSettings — set it in-app if needed)"

  if [ "$DO_LAUNCH" = "1" ]; then
    say "Launch-smoke (catch a FrontBoard SBMainWorkspace denial before handing to simdrive)"
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
    if PID="$(xcrun simctl launch "$UDID" "$BUNDLE_ID" 2>&1)"; then
      echo "  ✓ launched: $PID"
    else
      die "LAUNCH FAILED — $PID
The app installed but the simulator refused to launch it. Do not hand to simdrive."
    fi
  fi
elif [ "$DO_INSTALL" = "1" ]; then
  echo "  (no -u UDID given — skipping install; build verified)"
fi

# ── 4. summary ────────────────────────────────────────────────────────────────
cat <<EOF

────────────────────────────────────────────────────────────────────────────
✓ READY FOR SIMDRIVE
  app        : $APP
  bundle id  : $BUNDLE_ID
  udid       : ${UDID:-<none — pass -u to install>}
  signing    : ad-hoc signed → keychain + download work on the sim (no entitlement / no fallback needed)
  dev menu   : showDeveloperSettings seeded → flip "Enable Hidden Libraries" in-app to add A1QA

  simdrive:  session_start(device_udid="${UDID:-<udid>}", app_bundle_id="$BUNDLE_ID")
────────────────────────────────────────────────────────────────────────────
EOF
