# Palace iOS Makefile
# Run `make help` to see available targets

.PHONY: help ledger-install ledger-full ledger-diff ledger-verify ledger-clean

# Default target
help:
	@echo "Palace iOS - Available targets:"
	@echo ""
	@echo "  Ledger Analysis:"
	@echo "    make ledger-install  - Install ledger CLI"
	@echo "    make ledger-full     - Run full codebase analysis"
	@echo "    make ledger-diff     - Run diff analysis (main..HEAD)"
	@echo "    make ledger-verify   - Verify codebase against specs"
	@echo "    make ledger-clean    - Clean ledger artifacts"
	@echo ""
	@echo "  For more info, see: tools/ledger/README.md"

# -----------------------------------------------------------------
# Ledger Targets
# -----------------------------------------------------------------

# Install ledger CLI from distribution repo
ledger-install:
	@./tools/ledger/install_ledger.sh

# Run full analysis on the entire codebase
ledger-full:
	@./tools/ledger/run_full.sh

# Run diff analysis comparing main..HEAD
ledger-diff:
	@./tools/ledger/run_diff.sh

# Verify codebase against recorded specifications
ledger-verify:
	@./tools/ledger/run_verify.sh

# Clean ledger artifacts (keeps binary)
ledger-clean:
	@echo "Cleaning ledger artifacts..."
	@rm -rf artifacts/ledger/full
	@rm -rf artifacts/ledger/spec
	@rm -rf artifacts/ledger/diff
	@rm -rf artifacts/ledger/latest
	@rm -rf artifacts/ledger/logs
	@echo "Done. Binary preserved at tools/bin/ledger"
	@echo "To remove binary: rm tools/bin/ledger"
