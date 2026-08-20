#!/usr/bin/env bash
# Shared precondition: prove the chain can test before spending the budget.
#
# Sourced by every campaign entry point (regression-area-worker.sh,
# regression-chaos-fan.sh). It lived as an 18-line block copy-pasted into each,
# which is drift risk on a gate — the two copies could diverge and only one
# would be enforcing.
#
# THE HELPER'S OWN ABSENCE MUST BE A HARD FAILURE IN THE CALLER. These scripts
# run `set -uo pipefail` with no `-e`, so a failed `source` does not abort on
# its own: without an explicit check, extracting the block would reintroduce
# the exact silent-skip bug it was extracted to fix, one level up.

# regression_require_preflight <script_dir> <sim_id>
#
# Refuses the run unless the preflight passes. REGRESSION_SKIP_PREFLIGHT=1 is
# the single named bypass, for deliberately exercising the harness itself.
regression_require_preflight() {
    local script_dir="$1" sim_id="$2"
    local preflight="$script_dir/regression-preflight.sh"

    if [[ "${REGRESSION_SKIP_PREFLIGHT:-0}" == "1" ]]; then
        echo "warn: preflight bypassed (REGRESSION_SKIP_PREFLIGHT=1) — results are unearned" >&2
        return 0
    fi

    # Absence is a refusal, not a skip. `-x` as a GUARD made the precondition
    # optional exactly when the file was missing, which is indistinguishable
    # from a passing preflight.
    if [[ ! -x "$preflight" ]]; then
        {
            echo ""
            echo "!!! PREFLIGHT MISSING OR NOT EXECUTABLE — expected $preflight"
            echo "!!! Refusing rather than skipping: a campaign that cannot verify its"
            echo "!!! chain must not start, because a vacuous green looks like a pass."
            echo "!!! Set REGRESSION_SKIP_PREFLIGHT=1 to bypass deliberately."
        } >&2
        exit 2
    fi

    # Keep the diagnosis in THIS run's stderr. Discarding it to /dev/null meant
    # the reason for a refusal was absent from the artifact that recorded the
    # refusal, and the operator had to reproduce it by hand.
    local out
    out="$(mktemp)"
    if ! "$preflight" --udid "$sim_id" --skip-agent >"$out" 2>&1; then
        {
            echo ""
            echo "!!! PREFLIGHT FAILED — refusing to run. A campaign started now would"
            echo "!!! report a result it did not earn. Diagnosis follows; reproduce with:"
            echo "!!!   $preflight --udid $sim_id"
            echo "--- preflight output ---"
            cat "$out"
            echo "--- end preflight output ---"
        } >&2
        rm -f "$out"
        exit 6
    fi
    rm -f "$out"
}
