# Ledger CLI Integration for Palace iOS

This directory contains tooling to run [CodeAtlas Ledger](https://github.com/mauricecarrier7/CodeAtlas) analysis on the Palace iOS codebase.

## Quickstart

```bash
# Run full analysis
./tools/ledger/run_full.sh

# Run diff analysis (PR changes)
./tools/ledger/run_diff.sh

# Verify against specs
./tools/ledger/run_verify.sh
```

Or use the Makefile:

```bash
make ledger-full
make ledger-diff
make ledger-verify
```

## How It Works

### Version Pinning

The ledger version is pinned in `tools/ledger/ledger_version.txt`:

```
0.1.0
```

**Important:** Never use "latest" in CI. Always pin to a specific version.

### Installation

The install script (`install_ledger.sh`):
1. Reads the pinned version from `ledger_version.txt`
2. Downloads the binary from [ledger-dist](https://github.com/mauricecarrier7/ledger-dist)
3. Verifies SHA256 checksum (required)
4. Installs to `tools/bin/ledger`

```bash
# Manual installation
./tools/ledger/install_ledger.sh

# Override version (for testing)
VERSION=0.2.0 ./tools/ledger/install_ledger.sh
```

### Artifacts

All outputs are written under `artifacts/ledger/`:

```
artifacts/ledger/
├── full/           # Full analysis output
├── spec/           # Generated specifications
├── diff/           # Diff analysis output
│   └── spec-diff/  # Specification diffs
├── latest/         # Copy of latest full outputs
└── logs/           # Run summaries and logs
    ├── run-summary.md
    └── diff-summary.md
```

## Updating Ledger Version

To upgrade to a new version:

1. Check available versions at: https://github.com/mauricecarrier7/ledger-dist/releases

2. Update the version pin:
   ```bash
   echo "0.2.0" > tools/ledger/ledger_version.txt
   ```

3. Delete the existing binary to force reinstall:
   ```bash
   rm tools/bin/ledger
   ```

4. Run installation:
   ```bash
   ./tools/ledger/install_ledger.sh
   ```

5. Verify the new version:
   ```bash
   ./tools/bin/ledger --version
   ```

6. Run tests to ensure compatibility:
   ```bash
   ./tools/ledger/run_full.sh
   ```

## Configuration

Palace-specific configuration is in `tools/ledger/codeatlas.yml`:

- **Domains:** `arch`, `reach`, `a11y`
- **Excludes:** DerivedData, Carthage, Pods, .build, Generated
- **Roots:** Palace, PalaceTests

### Available Domains

| Domain | Description |
|--------|-------------|
| `arch` | Architecture patterns and dependency analysis |
| `reach` | Code reachability and dead code detection |
| `a11y` | Accessibility compliance checking |
| `qa` | AI-powered quality analysis (requires QAAtlas, optional) |

To enable the `qa` domain, uncomment the qa section in `codeatlas.yml` and ensure QAAtlas is configured.

## Troubleshooting

### "Version not found"

```
[ERROR] Version '0.2.0' not found in manifest
```

**Cause:** The requested version doesn't exist in ledger-dist.

**Fix:**
1. Check available versions: https://github.com/mauricecarrier7/ledger-dist/releases
2. Update `ledger_version.txt` with a valid version
3. Re-run installation

### "Checksum verification FAILED"

```
[ERROR] Checksum verification FAILED!
  Expected: abc123...
  Actual:   def456...
```

**Cause:** Downloaded binary doesn't match expected checksum.

**Fix:**
1. Delete cached binary: `rm tools/bin/ledger`
2. Retry installation
3. If persistent, check for network proxies or report to maintainers

### "Download failed"

```
[ERROR] Download failed
```

**Cause:** Network issues or GitHub unavailability.

**Fix:**
1. Check network connection
2. Verify GitHub status: https://www.githubstatus.com/
3. Wait and retry

### "Spec directory not found"

```
[ERROR] Spec directory not found
```

**Cause:** Trying to verify without generating specs first.

**Fix:**
```bash
# Generate specs first
./tools/ledger/run_full.sh

# Then verify
./tools/ledger/run_verify.sh
```

### "Missing dependencies"

```
[ERROR] Missing required dependencies: jq
```

**Fix (macOS):**
```bash
brew install jq
```

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | General error |
| 2 | Version not found in manifest |
| 3 | Checksum verification failed |
| 4 | Download failed |
| 5 | Missing dependencies |

## CI Integration

The ledger analysis runs on every PR via GitHub Actions. See `.github/workflows/ledger.yml`.

The CI job:
1. Installs ledger from the pinned version
2. Runs diff analysis on changed files
3. Uploads artifacts for review

**Note:** The CI job is currently non-blocking. To enable gating, see the commented section in the workflow file.

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `VERSION` | Override version from file | (from ledger_version.txt) |
| `LEDGER_INSTALL_DIR` | Installation directory | `tools/bin` |
| `LEDGER_OS` | Override OS detection | (auto-detected) |
| `LEDGER_ARCH` | Override arch detection | (auto-detected) |
| `BASE_REF` | Base ref for diff | `main` |
| `HEAD_REF` | Head ref for diff | `HEAD` |

## Local Development

For local development, you can:

1. Install ledger once:
   ```bash
   ./tools/ledger/install_ledger.sh
   ```

2. Run directly:
   ```bash
   ./tools/bin/ledger analyze --repo . --domains arch --format md
   ```

3. Use the runner scripts for common workflows:
   ```bash
   ./tools/ledger/run_full.sh   # Full analysis
   ./tools/ledger/run_diff.sh   # Changes only
   ```

## Links

- [Ledger Distribution](https://github.com/mauricecarrier7/ledger-dist)
- [CodeAtlas Source](https://github.com/mauricecarrier7/CodeAtlas)
- [Palace iOS](https://github.com/ThePalaceProject/ios-core)
