# Reference toolchain

A test result can only be compared with another run when both used the same
Xcode build and the same simulator. `scripts/reference-toolchain.ini` names
them in one profile, `reference`: the Xcode version and build, the simulator
SDK, the simulator runtime and device, the arch, the build configuration and
the runner image.

The CI test lanes (unit-test shards, UI journeys, toolkit tests,
ThreadSanitizer) and local `verify-pr.sh` and `xcode-test-optimized.sh` use the
profile. The release lanes (`upload.yml`, `upload-on-merge.yml`,
`release-rc.yml`, `release-on-merge.yml`) request the same Xcode version and run
on the same runner image, so the binary that is tested and the one that ships
come from one compiler.

`scripts/reference_toolchain.py` reads the file:

- `select-sim` prints the UDID of the profile's device on the profile's
  runtime, matched by exact name. If the device is missing it exits 3 and
  prints how to install the runtime or create the device.
- `report --strict` prints what the job actually uses and fails on any
  difference from the profile. Every CI test lane and every unit-test shard
  runs it, so each job log has a `TOOLCHAIN ...` line, with the runner image
  version, and a table in the job summary. The image version is recorded, not
  compared.
- `check-available` checks that a host provides the profile's Xcode build,
  SDK, runtime and device, and names each item that is missing. The
  `toolchain-availability.yml` workflow runs it every Monday and on demand on
  the profile's runner image, so an image update that removes one of them shows
  up before pull requests fail on it.

## Local runs

`verify-pr.sh` and `xcode-test-optimized.sh` use an explicit
`PALACE_TEST_SIMULATOR_ID` or `HARNESS_SESSION_SIM_UDID` first. Otherwise they
pick the reference device on its runtime. If that device is not installed,
they print the install command and use the same device on the newest
installed runtime instead. A local run does not fail when the installed Xcode
differs from the profile (for example, a workstation with only Xcode 27): the
report prints a warning for each difference and marks the run as
off-reference. Only CI lanes fail on a difference.

## Updating the profile

1. Read the new values from a CI run, not from documentation. Run the lanes on
   the candidate setup (a branch that changes only the profile and the
   `xcode-version` values), then read the `Set up Xcode` step for the version
   and build, and the `TOOLCHAIN` line for the SDK, runtime and device. A failed
   `toolchain-availability.yml` run lists what the current image lacks.
2. Change the profile in `scripts/reference-toolchain.ini`.
3. Change every setup-xcode `xcode-version:`, release lanes included, to the
   new `xcode_version`. `scripts/tests/test_reference_toolchain.py` fails until
   the workflows and the file agree, and it maps runner labels to the profile
   (`macos-26`). Change that map when the lanes move runner.
4. Expect tests that pass only on the old setup. Each one is a finding to
   report, not a test to skip.
