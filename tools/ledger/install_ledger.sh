#!/usr/bin/env bash
#
# install_ledger.sh - Install CodeAtlas ledger CLI for Palace iOS
#
# This script installs ledger from the official distribution repository
# with SHA256 verification. It is designed for both local development
# and CI/CD pipelines.
#
# Usage:
#   ./tools/ledger/install_ledger.sh
#
# Environment variables:
#   VERSION             - Override version from ledger_version.txt
#   LEDGER_INSTALL_DIR  - Installation directory (default: tools/bin)
#   LEDGER_OS           - Override OS detection (macos, linux)
#   LEDGER_ARCH         - Override arch detection (arm64, x64)
#
# Exit codes:
#   0 - Success
#   1 - General error
#   2 - Version not found in manifest
#   3 - Checksum verification failed
#   4 - Download failed
#   5 - Missing dependencies

set -euo pipefail

# -----------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VERSION_FILE="${SCRIPT_DIR}/ledger_version.txt"

DIST_REPO="mauricecarrier7/ledger-dist"
MANIFEST_URL="https://raw.githubusercontent.com/${DIST_REPO}/main/versions.json"
RELEASES_URL="https://github.com/${DIST_REPO}/releases"

# Defaults
DEFAULT_INSTALL_DIR="${REPO_ROOT}/tools/bin"

# -----------------------------------------------------------------
# Colors (disabled in CI or non-TTY)
# -----------------------------------------------------------------
if [[ -t 1 ]] && [[ -z "${CI:-}" ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' NC=''
fi

log_info()    { echo -e "${BLUE}[INFO]${NC} $*" >&2; }
log_success() { echo -e "${GREEN}[OK]${NC} $*" >&2; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

die() {
    log_error "$1"
    exit "${2:-1}"
}

# -----------------------------------------------------------------
# Dependency checks
# -----------------------------------------------------------------
check_dependencies() {
    local missing=()

    command -v curl >/dev/null 2>&1 || missing+=("curl")
    if ! command -v shasum >/dev/null 2>&1 && ! command -v sha256sum >/dev/null 2>&1; then
        missing+=("shasum or sha256sum")
    fi
    command -v jq >/dev/null 2>&1 || missing+=("jq")

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required dependencies: ${missing[*]}"
        log_info "Install with: brew install ${missing[*]}"
        exit 5
    fi
}

# -----------------------------------------------------------------
# Platform detection
# -----------------------------------------------------------------
detect_platform() {
    local os arch

    # OS detection (allow override)
    if [[ -n "${LEDGER_OS:-}" ]]; then
        os="${LEDGER_OS}"
    else
        case "$(uname -s | tr '[:upper:]' '[:lower:]')" in
            darwin) os="macos" ;;
            linux)  os="linux" ;;
            *)      die "Unsupported operating system: $(uname -s)" 1 ;;
        esac
    fi

    # Architecture detection (allow override)
    if [[ -n "${LEDGER_ARCH:-}" ]]; then
        arch="${LEDGER_ARCH}"
    else
        case "$(uname -m)" in
            arm64|aarch64) arch="arm64" ;;
            x86_64|amd64)  arch="x64" ;;
            *)             die "Unsupported architecture: $(uname -m)" 1 ;;
        esac
    fi

    echo "${os}-${arch}"
}

# -----------------------------------------------------------------
# SHA256 computation
# -----------------------------------------------------------------
compute_sha256() {
    local file="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" | awk '{print $1}'
    else
        shasum -a 256 "$file" | awk '{print $1}'
    fi
}

# -----------------------------------------------------------------
# Fetch version manifest
# -----------------------------------------------------------------
fetch_manifest() {
    log_info "Fetching version manifest..."
    
    local manifest
    if ! manifest=$(curl -fsSL --connect-timeout 10 --max-time 30 "$MANIFEST_URL" 2>/dev/null); then
        log_error "Failed to fetch manifest from ${MANIFEST_URL}"
        log_info "Check your network connection and try again."
        log_info "Manifest URL: ${MANIFEST_URL}"
        exit 4
    fi
    
    echo "$manifest"
}

# -----------------------------------------------------------------
# Get version info from manifest
# -----------------------------------------------------------------
get_version_info() {
    local manifest="$1"
    local version="$2"
    local platform="$3"

    local version_entry
    version_entry=$(echo "$manifest" | jq -r --arg v "$version" '.versions[] | select(.version == $v)')

    if [[ -z "$version_entry" || "$version_entry" == "null" ]]; then
        log_error "Version '${version}' not found in manifest"
        log_info ""
        log_info "Available versions:"
        echo "$manifest" | jq -r '.versions[].version' | sed 's/^/  - /'
        log_info ""
        log_info "To fix:"
        log_info "  1. Check available versions at: ${RELEASES_URL}"
        log_info "  2. Update ${VERSION_FILE} with a valid version"
        log_info "  3. Re-run this script"
        exit 2
    fi

    local artifact_info
    artifact_info=$(echo "$version_entry" | jq -r --arg p "$platform" '.artifacts[$p]')

    if [[ -z "$artifact_info" || "$artifact_info" == "null" ]]; then
        log_error "Platform '${platform}' not available for version '${version}'"
        log_info ""
        log_info "Available platforms for ${version}:"
        echo "$version_entry" | jq -r '.artifacts | keys[]' | sed 's/^/  - /'
        log_info ""
        log_info "See: ${RELEASES_URL}/tag/v${version}"
        exit 2
    fi

    echo "$artifact_info"
}

# -----------------------------------------------------------------
# Download and verify binary
# -----------------------------------------------------------------
download_and_verify() {
    local url="$1"
    local expected_sha256="$2"
    local output_file="$3"

    # Create temp file for download
    local temp_file
    temp_file=$(mktemp)
    
    # Cleanup on exit
    cleanup() {
        rm -f "$temp_file" 2>/dev/null || true
    }
    trap cleanup EXIT

    log_info "Downloading ledger binary..."
    log_info "  URL: ${url}"
    
    if ! curl -fsSL --connect-timeout 10 --max-time 120 -o "$temp_file" "$url" 2>/dev/null; then
        log_error "Download failed"
        log_info ""
        log_info "Possible causes:"
        log_info "  - Network connectivity issues"
        log_info "  - GitHub rate limiting"
        log_info "  - Version/platform not available"
        log_info ""
        log_info "Try:"
        log_info "  1. Check your network connection"
        log_info "  2. Verify the URL is accessible: ${url}"
        log_info "  3. Wait a few minutes and retry"
        exit 4
    fi

    log_info "Verifying SHA256 checksum..."
    local actual_sha256
    actual_sha256=$(compute_sha256 "$temp_file")

    if [[ "$actual_sha256" != "$expected_sha256" ]]; then
        log_error "Checksum verification FAILED!"
        log_error ""
        log_error "  Expected: ${expected_sha256}"
        log_error "  Actual:   ${actual_sha256}"
        log_error ""
        log_error "This could indicate:"
        log_error "  - Corrupted download"
        log_error "  - Tampered binary"
        log_error "  - Man-in-the-middle attack"
        log_error ""
        log_error "DO NOT USE THIS BINARY"
        log_error ""
        log_info "Try:"
        log_info "  1. Delete any cached files and retry"
        log_info "  2. Check for network proxies"
        log_info "  3. Report this issue to maintainers"
        exit 3
    fi

    log_success "Checksum verified: ${actual_sha256}"

    # Move to final location
    mkdir -p "$(dirname "$output_file")"
    mv "$temp_file" "$output_file"
    chmod +x "$output_file"
    
    # Disable cleanup since we moved the file
    trap - EXIT
}

# -----------------------------------------------------------------
# Read version from file
# -----------------------------------------------------------------
read_version() {
    local version="${VERSION:-}"
    
    if [[ -n "$version" ]]; then
        log_info "Using VERSION from environment: ${version}"
        echo "$version"
        return
    fi
    
    if [[ ! -f "$VERSION_FILE" ]]; then
        log_error "Version file not found: ${VERSION_FILE}"
        log_info "Create it with: echo '0.1.0' > ${VERSION_FILE}"
        exit 1
    fi
    
    version=$(tr -d '[:space:]' < "$VERSION_FILE")
    
    if [[ -z "$version" ]]; then
        log_error "Version file is empty: ${VERSION_FILE}"
        exit 1
    fi
    
    # Strip 'v' prefix if present (manifest uses bare versions)
    version="${version#v}"
    
    echo "$version"
}

# -----------------------------------------------------------------
# Main
# -----------------------------------------------------------------
main() {
    log_info "Palace iOS - Ledger CLI Installer"
    log_info "================================="
    echo ""

    # Check dependencies
    check_dependencies

    # Read configuration
    local version platform install_dir output_file
    version=$(read_version)
    platform=$(detect_platform)
    install_dir="${LEDGER_INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
    output_file="${install_dir}/ledger"

    log_info "Configuration:"
    log_info "  Version:     ${version}"
    log_info "  Platform:    ${platform}"
    log_info "  Install dir: ${install_dir}"
    echo ""

    # Check if already installed with correct version
    if [[ -x "$output_file" ]]; then
        local installed_version
        installed_version=$("$output_file" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
        if [[ "$installed_version" == "$version" ]]; then
            log_success "Ledger v${version} already installed at ${output_file}"
            log_info "Skipping download (use 'rm ${output_file}' to force reinstall)"
            echo ""
            echo "Installation details:"
            echo "  Version:  ${version}"
            echo "  Location: $(cd "$(dirname "$output_file")" && pwd)/$(basename "$output_file")"
            return 0
        fi
        log_info "Upgrading from v${installed_version} to v${version}"
    fi

    # Fetch manifest and get version info
    local manifest artifact_info url sha256
    manifest=$(fetch_manifest)
    artifact_info=$(get_version_info "$manifest" "$version" "$platform")
    
    url=$(echo "$artifact_info" | jq -r '.url')
    sha256=$(echo "$artifact_info" | jq -r '.sha256')

    if [[ -z "$url" || "$url" == "null" ]]; then
        die "Failed to extract download URL from manifest" 1
    fi
    if [[ -z "$sha256" || "$sha256" == "null" ]]; then
        die "Failed to extract SHA256 checksum from manifest" 1
    fi

    # Download and verify
    download_and_verify "$url" "$sha256" "$output_file"

    # Verify installation
    echo ""
    log_success "Ledger CLI installed successfully!"
    echo ""
    echo "Installation details:"
    echo "  Version:  ${version}"
    echo "  Platform: ${platform}"
    echo "  Location: $(cd "$(dirname "$output_file")" && pwd)/$(basename "$output_file")"
    echo ""
    
    # Show version output
    local version_output
    version_output=$("$output_file" --version 2>&1 | head -1) || true
    echo "  Binary:   ${version_output}"
}

main "$@"
