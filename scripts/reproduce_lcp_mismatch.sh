#!/usr/bin/env bash
# =============================================================================
# reproduce_lcp_mismatch.sh
#
# Reproduces the two-device LCP "Content Protection Error" on a single
# simulator by injecting a fake (wrong-licenseId) license document into a
# downloaded LCP EPUB.  The embedded LCPL becomes invalid, causing Readium to
# return LCPError.licenseIntegrity on the next open — exactly the recoverable
# error the fix handles.
#
# What happens:
#   1. Script corrupts META-INF/license.lcpl inside the EPUB.
#   2. You open the book in the app.
#   3. Readium detects the invalid license → LCPError.licenseIntegrity.
#   4. ReaderService.attemptLicenseRefreshAndReopen fires:
#        • Fetches fresh .lcpl from the CM fulfill URL (requires network + sign-in).
#        • Injects it back into the EPUB.
#        • Retries opening.
#   5. Book opens normally — no "Content Protection Error" shown.
#
# Prerequisites:
#   • Palace app installed and running in the iOS Simulator (booted).
#   • Signed in to a library with at least one LCP EPUB already downloaded.
#   • python3 available (pre-installed on macOS).
#   • sqlite3 CLI available (pre-installed on macOS).
#
# Usage:
#   bash scripts/reproduce_lcp_mismatch.sh          # interactive book picker
#   bash scripts/reproduce_lcp_mismatch.sh --restore # restore all backups
# =============================================================================

set -euo pipefail

PALACE_BUNDLE_ID="org.thepalaceproject.palace"
RESTORE_MODE=false
[[ "${1:-}" == "--restore" ]] && RESTORE_MODE=true

# ─── Colour helpers ──────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${CYAN}[info]${RESET}  $*"; }
success() { echo -e "${GREEN}[ok]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[warn]${RESET}  $*"; }
error()   { echo -e "${RED}[error]${RESET} $*"; exit 1; }

# ─── 1. Find the booted simulator ────────────────────────────────────────────
info "Looking for a booted iOS Simulator…"
SIM_UDID=$(xcrun simctl list devices booted --json 2>/dev/null \
  | python3 -c "
import sys, json
devs = json.load(sys.stdin)
for runtime, devices in devs.get('devices', {}).items():
    for d in devices:
        if d.get('state') == 'Booted':
            print(d['udid'])
            exit()
" 2>/dev/null || true)

if [[ -z "$SIM_UDID" ]]; then
  error "No booted simulator found.  Boot a simulator and run the Palace app first."
fi
success "Simulator: $SIM_UDID"

# ─── 2. Find the Palace app data container ───────────────────────────────────
SIM_ROOT="$HOME/Library/Developer/CoreSimulator/Devices/$SIM_UDID/data"
APP_CONTAINER=$(find "$SIM_ROOT/Containers/Data/Application" -maxdepth 2 \
  -name ".com.apple.mobile_container_manager.metadata.plist" \
  -exec grep -l "$PALACE_BUNDLE_ID" {} \; 2>/dev/null \
  | head -1 | xargs dirname 2>/dev/null || true)

if [[ -z "$APP_CONTAINER" ]]; then
  error "Palace data container not found under $SIM_ROOT.
Make sure the Palace app has been launched at least once on this simulator."
fi
success "App container: $(basename "$APP_CONTAINER")"

# ─── Restore mode: undo all previous corruptions ─────────────────────────────
if $RESTORE_MODE; then
  echo ""
  info "Restore mode — looking for .epub.bak files…"
  RESTORED=0
  while IFS= read -r -d '' bak; do
    orig="${bak%.bak}"
    mv "$bak" "$orig"
    success "Restored: $(basename "$orig")"
    (( RESTORED++ ))
  done < <(find "$APP_CONTAINER" -name "*.epub.bak" -print0 2>/dev/null)

  if (( RESTORED == 0 )); then
    warn "No backup files found — nothing to restore."
  else
    success "Restored $RESTORED file(s).  Re-launch Palace to reload books."
  fi
  exit 0
fi

# ─── 3. Find downloaded LCP EPUBs ────────────────────────────────────────────
info "Scanning for downloaded LCP EPUBs…"
mapfile -d '' EPUBS < <(find "$APP_CONTAINER" -name "*.epub" -print0 2>/dev/null)

if (( ${#EPUBS[@]} == 0 )); then
  error "No .epub files found.  Download at least one LCP EPUB in Palace first."
fi

# Filter to only those that contain an LCP license
LCP_EPUBS=()
for epub in "${EPUBS[@]}"; do
  if python3 -c "
import zipfile, sys
try:
    with zipfile.ZipFile('$epub', 'r') as z:
        names = z.namelist()
        if 'META-INF/license.lcpl' in names:
            sys.exit(0)
    sys.exit(1)
except:
    sys.exit(1)
" 2>/dev/null; then
    LCP_EPUBS+=("$epub")
  fi
done

if (( ${#LCP_EPUBS[@]} == 0 )); then
  error "No LCP-protected EPUBs found (none contained META-INF/license.lcpl).
Make sure you have downloaded an LCP EPUB, not just an open-access book."
fi

# ─── 4. Let user pick a book ─────────────────────────────────────────────────
echo ""
echo -e "${BOLD}LCP EPUBs available:${RESET}"
for i in "${!LCP_EPUBS[@]}"; do
  epub="${LCP_EPUBS[$i]}"
  size=$(du -h "$epub" | cut -f1)
  # Try to extract the book title from OPF metadata
  title=$(python3 -c "
import zipfile, re, sys
try:
    with zipfile.ZipFile('$epub') as z:
        opf = next((n for n in z.namelist() if n.endswith('.opf')), None)
        if opf:
            text = z.read(opf).decode('utf-8', errors='ignore')
            m = re.search(r'<dc:title[^>]*>([^<]+)</dc:title>', text)
            if m:
                print(m.group(1).strip())
                sys.exit()
    print('(unknown title)')
except:
    print('(unknown title)')
" 2>/dev/null)
  echo -e "  ${CYAN}[$((i+1))]${RESET} $title  ${YELLOW}($size)${RESET}"
  echo "       $(basename "$epub")"
done
echo ""

if (( ${#LCP_EPUBS[@]} == 1 )); then
  CHOICE=1
else
  read -rp "Enter number to corrupt [1-${#LCP_EPUBS[@]}]: " CHOICE
fi

if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || (( CHOICE < 1 || CHOICE > ${#LCP_EPUBS[@]} )); then
  error "Invalid choice."
fi

TARGET_EPUB="${LCP_EPUBS[$((CHOICE-1))]}"
echo ""
info "Target: $(basename "$TARGET_EPUB")"

# ─── 5. Show the current real licenseId (for reference) ──────────────────────
REAL_LICENSE_ID=$(python3 -c "
import zipfile, json, sys
try:
    with zipfile.ZipFile('$TARGET_EPUB') as z:
        data = json.loads(z.read('META-INF/license.lcpl').decode())
        print(data.get('id', 'unknown'))
except Exception as e:
    print('(could not read: ' + str(e) + ')')
" 2>/dev/null)
info "Real license ID: $REAL_LICENSE_ID"

# ─── 6. Back up and inject a fake LCPL ───────────────────────────────────────
BACKUP="${TARGET_EPUB}.bak"
if [[ -f "$BACKUP" ]]; then
  warn "Backup already exists at $(basename "$BACKUP") — skipping backup (previous run not restored?)"
else
  cp "$TARGET_EPUB" "$BACKUP"
  success "Backed up to $(basename "$BACKUP")"
fi

FAKE_LCPL=$(python3 -c "
import json, uuid
# Well-formed LCPL JSON but with a random licenseId and an invalid signature.
# Readium will parse it successfully but fail the integrity check →
# LCPError.licenseIntegrity (a recoverable error in ReaderService).
doc = {
    'id': str(uuid.uuid4()),
    'issued': '2020-01-01T00:00:00Z',
    'updated': '2020-01-01T00:00:00Z',
    'provider': 'https://example.com',
    'encryption': {
        'profile': 'http://readium.org/lcp/basic-profile',
        'content_key': {
            'algorithm': 'http://www.w3.org/2001/04/xmlenc#aes256-cbc',
            'encrypted_value': '/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='
        },
        'user_key': {
            'algorithm': 'http://www.w3.org/2001/04/xmlenc#sha256',
            'key_check': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==',
            'text_hint': 'Test passphrase hint'
        }
    },
    'rights': {
        'start': '2020-01-01T00:00:00Z',
        'end': '2099-01-01T00:00:00Z'
    },
    'links': [
        {'rel': 'hint',   'href': 'https://example.com/hint',   'type': 'text/html'},
        {'rel': 'status', 'href': 'https://example.com/status', 'type': 'application/vnd.readium.license.status.v1.0+json'},
        {'rel': 'publication', 'href': 'https://example.com/book.epub', 'type': 'application/epub+zip'}
    ],
    'signature': {
        'algorithm': 'http://www.w3.org/2001/04/xmlenc#sha256WithRSAEncryption',
        'certificate': 'FAKE',
        'value': 'FAKE'
    }
}
print(json.dumps(doc, indent=2))
")

python3 << PYEOF
import zipfile, shutil, os, tempfile

epub_path = "$TARGET_EPUB"
fake_lcpl = '''$FAKE_LCPL'''

# Rewrite the ZIP replacing META-INF/license.lcpl
tmp = epub_path + ".tmp"
with zipfile.ZipFile(epub_path, 'r') as zin, \
     zipfile.ZipFile(tmp, 'w', compression=zipfile.ZIP_DEFLATED) as zout:
    for item in zin.infolist():
        if item.filename == 'META-INF/license.lcpl':
            zout.writestr(item, fake_lcpl.encode('utf-8'))
        else:
            zout.writestr(item, zin.read(item.filename))

os.replace(tmp, epub_path)
print("Injection complete")
PYEOF

success "Fake LCPL injected into $(basename "$TARGET_EPUB")"

# ─── 7. Also clear the passphrase from the LCP SQLite DB for this licenseId ──
LCP_DB="$APP_CONTAINER/Library/lcpdatabase.sqlite"
if [[ -f "$LCP_DB" ]]; then
  DELETED=$(sqlite3 "$LCP_DB" \
    "DELETE FROM Transactions WHERE licenseId = '$REAL_LICENSE_ID'; SELECT changes();" \
    2>/dev/null || echo "0")
  if [[ "$DELETED" -gt 0 ]]; then
    success "Cleared cached passphrase for license $REAL_LICENSE_ID from SQLite"
  else
    info "No cached passphrase found in SQLite for this license (that's fine)"
  fi
else
  warn "LCP database not found at expected path — passphrase cache not cleared"
fi

# ─── 8. Instructions ─────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${BOLD}  What to do next${RESET}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
echo -e "  ${GREEN}✓${RESET} Make sure you are ${BOLD}signed in${RESET} and have ${BOLD}network access${RESET} in the simulator."
echo -e "    (The fix needs to reach the CM to re-download the fresh .lcpl)"
echo ""
echo -e "  ${GREEN}1${RESET} Force-quit Palace in the simulator (so it re-reads files from disk)."
echo -e "  ${GREEN}2${RESET} Re-open Palace and navigate to the book you just corrupted."
echo -e "  ${GREEN}3${RESET} Tap the book to open it."
echo ""
echo -e "  ${BOLD}Expected with the fix:${RESET}"
echo -e "    → Book opens normally.  No error shown."
echo -e "    → Xcode console shows: 'LCP open failed with recoverable error'"
echo -e "      followed by 'injected fresh license into EPUB — retrying open'"
echo ""
echo -e "  ${BOLD}Expected WITHOUT the fix (on old builds):${RESET}"
echo -e "    → 'Content Protection Error' alert appears."
echo ""
echo -e "  ${BOLD}To restore the original EPUB:${RESET}"
echo -e "    ${CYAN}bash scripts/reproduce_lcp_mismatch.sh --restore${RESET}"
echo ""
