# Reference toolchain

A test result can only be compared with another run when both used the same
Xcode build and the same simulator. `scripts/reference-toolchain.ini` names
them, per profile:

| Profile | Used by | Runner image |
|---|---|---|
| `reference` | unit-test shards, UI journeys, toolkit tests, local `verify-pr.sh` and `xcode-test-optimized.sh` | `macos-15-arm64` |
| `release` | archive and upload lanes, the non-DRM build, ThreadSanitizer | `macos-26-arm64` |

Each profile pins the Xcode version and build, the simulator SDK, the
simulator runtime and device, the arch and the build configuration.
`scripts/reference_toolchain.py` reads the file:

- `select-sim --profile P` prints the UDID of the profile's device on the
  profile's runtime, matched by exact name. If the device is missing it exits 3
  and prints how to install the runtime or create the device.
- `report --profile P --udid U --strict` prints what the job actually uses and
  fails on any difference from the profile. Every CI test lane and every unit
  test shard runs it, so each job log has a `TOOLCHAIN ...` line and a table in
  the job summary.

## Local runs

`verify-pr.sh` and `xcode-test-optimized.sh` use an explicit
`PALACE_TEST_SIMULATOR_ID` or `HARNESS_SESSION_SIM_UDID` first. Otherwise they
pick the reference device on its runtime. If that device is not installed,
they print the install command and use the same device on the newest
installed runtime instead. A local run does not fail when the installed Xcode
differs from the profile (for example, a workstation with only Xcode 27): the
report prints a warning for each difference and marks the run as
off-reference. Only CI lanes fail on a difference.

## Updating a profile

1. Read the new values from a CI run, not from documentation. Run the lane on
   the candidate setup (a branch that changes only the profile and the
   `xcode-version` values), then read the `Set up Xcode` step for the version
   and build, and the `TOOLCHAIN` line for the SDK, runtime and device. The
   runner image's installed simulators are listed in
   [actions/runner-images](https://github.com/actions/runner-images/tree/main/images/macos).
2. Change the profile in `scripts/reference-toolchain.ini`.
3. Change every setup-xcode `xcode-version:` that uses the profile to the new
   `xcode_version`. `scripts/tests/test_reference_toolchain.py` fails until the
   workflows and the file agree, and it maps runner labels to profiles
   (`macos-15` to `reference`, `macos-26` to `release`). Change that map when a
   lane moves runner.
4. Expect tests that pass only on the old setup. Each one is a finding to
   report, not a test to skip.

The two profiles differ because the macos-15 image has no Xcode later than
26.3 and the macos-26 image has no iPhone 16 Pro or iOS 18.5 simulator. Using
one toolchain for both is an open decision.
