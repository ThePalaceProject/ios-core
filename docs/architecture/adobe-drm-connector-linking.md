# How the Adobe DRM connector is chosen, verified, and replaced

The Adobe DRM connector is not source. It is a set of prebuilt static libraries
delivered as a zip by the vendor, kept in a private repository, and linked into
the `Palace` target. Two generations of it now exist: the Adobe-era binaries,
which report `hobbes.build` 187526, and the ByteBooks binaries, which report
187639 and are built for ByteBooks' activation service.

Only one of them can be in a binary, and nothing selects between them at
runtime. That single fact drives everything below. It means the choice is made
at link time by configuration outside the app's source, that an activation made
by one generation is not usable by the other, and that one checkout cannot build
both release lines at once.

This document records where that choice is actually made, how to tell which
connector a build linked, and what has to move together when the connector is
replaced.

## What chooses the connector

Three mechanisms, in the order you will meet them.

**The connector record: the input defaults of the `checkout-adobe` action**
(`.github/actions/checkout-adobe/action.yml`). `repo` names the connector
repository, `ref` the exact commit (a full SHA, never a branch), and
`generation` the `AdobeConnectorGeneration` that commit carries. It is the only
copy:

* CI checks out `ref` through the action, then a step fails the job if the
  checked-out commit differs and prints the repo, commit and generation.
* `scripts/bootstrap-drm.sh` clones the repository and checks out `ref` through
  `scripts/drm_connector.py clone`. `git clone --branch` does not accept a SHA,
  which is why the clone and the checkout are separate steps.
* `scripts/drm_connector.py check` compares a local connector tree with it (see
  below).

No workflow passes `ref` or `repo`; `scripts/tests/test_drm_connector.py`
fails if one does. A reader auditing a workflow file for the connector version
will find nothing there; the value is in the action.

The record was first set to `7913158fa6b04ef8387a0b3bf32454bd795284fb` on
`feature/bytebooks-connector-20261104`, the commit every 3.4.1 build used. A
release branch cut before the record existed (3.4.1 and its hotfixes) still
fetches that branch by name, so the branch must not move while such a release
is supported.

**Locally, the `adobe-rmsdk` symlink.** `adept-ios/ADEPT/ADEPT.xcconfig` sets
`ADEPT_RMSDK = $(SRCROOT)/../adobe-rmsdk` and takes `LIBRARY_SEARCH_PATHS`,
`HEADER_SEARCH_PATHS` and the `-l` list from under it.
`scripts/setup-repo-drm.sh` creates that symlink, pointing at the `connector`
folder of a sibling checkout of the connector repository.

Two consequences follow:

* **The symlink is shared.** Every worktree whose `adobe-rmsdk` points at the
  same sibling checkout links the same connector tree, so whichever branch that
  one checkout has on disk is the connector every such local build links, for
  every branch.
* **A worktree that reuses the main checkout's `adept-ios` ignores its own
  symlink.** `adept-ios` is a submodule. If a worktree shares the main
  checkout's copy (for example through a symlink) instead of initializing its
  own, `SRCROOT` for the ADEPT project resolves to the main checkout, so
  repointing `adobe-rmsdk` inside the worktree changes nothing, and the build
  stays green while linking the connector you thought you had replaced.

**Overriding either, `ADEPT_RMSDK` on the command line.** Passing
`ADEPT_RMSDK=/path/to/a/connector/tree` to `xcodebuild` wins over the xcconfig
default and is the only way to build a specific connector without disturbing the
shared tree. This is the mechanism to reach for when two connector generations
have to be built from one machine.

## Why there is no runtime switch

A Remote Config flag over the two connectors was investigated under PP-5437 and
closed as not buildable. The two generations are different builds of the same
libraries and their exported symbols overlap almost completely: 823 of 830
shared in `libadept`, 9,351 of 9,532 in `libhobbes`, 633 of 636 in `libdp`. One
binary cannot hold both, so there is nothing for a flag to select.

The switch is therefore a build-time decision and a separate release, not a
configuration change.

## The generation constant, and the test that holds it honest

Because the connector generation is invisible at runtime but changes what an
activation means, the app records it.
`Palace/Reader2/ReaderStackConfiguration/AdobeDRM/AdobeConnectorGeneration.swift`
holds:

* `current`, the generation this build links. Hand-assigned, deliberately
  coarse, and raised only when a drop changes the activation contract rather
  than on every vendor build number.
* `generationsByBuild`, the map from a known `hobbes.build` string to its
  generation. An unmapped build resolves to `nil` on purpose, so a new drop
  cannot inherit "already migrated".
* `preMarker`, the generation an activation carrying no marker is read as. The
  comments in that file carry the reasoning for why backfilling is safer than
  treating an absent marker as unknown.
* `needsReactivation(recorded:current:)`, the pure predicate the gate asks.

The reason the recorded generation matters at all is PP-5026: the ByteBooks
binaries report a device activated under the Adobe-era binaries as authorized,
and then fail every operation with `E_ACT_NOT_READY`. `isUserAuthorized` answers
a weaker question than the app needs, so every site deciding whether to skip
activation asks `canUseRecordedActivation` instead.

**`current` is hand-assigned.** A connector swap that
nobody paired with a bump of that constant leaves every migration decision
reading the wrong generation. While the shipped generation equals `preMarker`,
nothing fails: the migration simply never fires. One test closes
that gap. `testCurrentGenerationDescribesTheLinkedConnector` in
`PalaceTests/Accounts/AdobeConnectorGenerationTests.swift` reads
`AdobeConnectorBuild.current` out of the linked libraries and asserts it maps to
`AdobeConnectorGeneration.current`.

Know what that test does and does not cover:

* It runs only under `FEATURE_DRM_CONNECTOR`, so it is inert in the
  `Palace-noDRM` target.
* It fails if the linked connector is unknown to the table, if the table maps it
  to a different generation than `current`, or if the SDK reports no build
  string at all.
* It is the only mechanical link between the constant and the binaries.
  `generationsByBuild` and `AdobeConnectorBuild.current` have no production call
  sites; the protection is a CI-time one.

`AdobeConnectorBuild` (`.h` and `.mm` in the same directory) reads
`dp::getVersionInfo("hobbes.build")`. The SDK registers its version strings from
a static initializer, so this is readable without starting a DRM workflow or
activating a device, and it is defined in both targets so the test bridging
header can declare it without the open-source target failing to link.

## Verifying which connector a build linked

Ask the binaries, never the configuration. The configuration is what the three
mechanisms above fight over.

1. **Run the keystone test.** A green
   `testCurrentGenerationDescribesTheLinkedConnector` is a direct statement that
   the linked build and the constant agree. A red one names the build it found.
2. **Check the shared tree's revision** before trusting a local build:
   `python3 scripts/drm_connector.py check`. It resolves `adobe-rmsdk` (or
   `ADEPT_RMSDK` when set) to the connector checkout and exits 0 when that
   checkout is at the recorded commit with no modified tracked files, 1 when it
   is not (with the commands to fix it), 2 when there is no connector tree (a
   noDRM setup), and 3 when it cannot tell. `scripts/setup-repo-drm.sh` runs it
   after creating the link, and `scripts/verify-pr.sh` records it as the
   `drm_connector` leg.
3. **For a CI run**, read the "Verify Adobe RMSDK revision" step in the run
   log, not the workflow file.

A build that compiles, links, and passes everything else does not show which
connector it used. The keystone test is the only check that does.

## Replacing the connector, or publishing a new drop

The connector repository's own README carries the mechanical recipe, and it is
the authority. The shape is: put the vendor zip at that repository's root, then
run its three build scripts in order (uncompress, then the openssl and curl
build, then the connector build), then commit the result. Those scripts live in
the connector repository, not in this one. The prebuilt objects are large and are
tracked with Git LFS, so a clone without LFS installed produces pointer files and
a link failure rather than an obvious error.

The two generations are kept side by side rather than as successive commits on
one branch (the Adobe-era drop on `main`, ByteBooks on its own branch), so both
stay available: the app picks one at link time, and nothing selects
between them at runtime. A new drop that changes the activation contract
therefore lands as a branch, and the app points at it.

Changing the record is the only way to change the connector. When it changes,
these move together in one PR or the migration is wrong:

1. The connector commit is pushed to a branch of the connector repository,
   with its LFS objects.
2. The `ref` default in `.github/actions/checkout-adobe/action.yml` is set to
   that commit's full SHA, and its comment names the branch it is on.
3. `generationsByBuild` gains the new `hobbes.build` with its generation.
4. `AdobeConnectorGeneration.current` moves, if and only if the activation
   contract changed, and the `generation` default moves with it
   (`test_drm_connector.py` fails if the two differ).
5. Any test that asserts an activation is usable passes the generation
   explicitly rather than relying on the default, or it will assert the old
   generation against the new constant.
6. Each developer moves their connector tree to the new commit (the fix
   commands `drm_connector.py check` prints), and the keystone test passes on
   that tree.
7. A DRM build from the new commit opens an Adobe-protected book from the test
   library on a device, before merge. The unit suite does not exercise
   fulfillment against the real connector.

Step 5 is the one that surfaces late. Tests that seed an activation through
`setAdobeActivation(userID:deviceID:generation:)` keep working across a bump;
tests that set the identifiers directly and leave the marker absent are asserting
`preMarker` behaviour and will change meaning when `current` moves past it.

## The other pinned build inputs

The connector is one of several outside inputs whose revision a DRM build
depends on. The others are recorded the same way or where they already live:

* **mobile-certificates** holds the reader certificate, `AddLCP.swift` (which
  sets the LCP library version and download location) and the release-notes
  script. Its record is the input defaults of
  `.github/actions/checkout-certificates/action.yml` (`repo`, `ref`), first set
  to `855e8752fab169afd262102f75f3b22d793d013e`, the commit every 3.4.1 build
  used. Every workflow checks it out through that action and bootstrap clones
  it at `ref`. Because people also develop tooling in that repository in place,
  `drm_connector.py check` compares content, not the commit: the files listed
  in `paths` (the ones `build-carthage.sh` and `update-certificates.sh` read)
  must match `ref`, committed or not, in `../mobile-certificates` locally or
  `./mobile-certificates` in CI. Files in `tooling` (the release-notes script)
  are not compared. `test_drm_connector.py` derives every certificates path the
  scripts read and fails if one is in neither list. A change to a build file
  reaches builds only when the record moves.
* **liblcp**, the LCP library Carthage downloads, is checked after
  `carthage bootstrap` by `scripts/build-carthage.sh`, which records its
  version and the SHA-256 of the archive. A different version in
  `Cartfile.resolved` or a different archive fails the build and removes the
  framework built from it. Carthage itself does not verify binary-only
  frameworks. The script prints no download URL; it is licensed.
* **The sibling `ios-audiobook-overdrive` checkout** that bootstrap clones is
  checked out at the commit the `ios-audiobook-overdrive` submodule records.
  The build reads the submodule, not the sibling.

* **The audiobook toolkit** is the `ios-audiobooktoolkit` submodule. The
  gitlink in this repository is its exact commit; CI runs
  `git submodule update --init`, never `--remote`. Move it with a normal
  submodule bump.
* **Findaway's AudioEngine** is downloaded by `scripts/fetch-audioengine.sh`,
  which records the version and the SHA-256 of the archive and fails, without
  installing anything, when the download does not match. To change the version,
  change both values together and check a Findaway title plays.

## Traps worth knowing before you start

**No single local state satisfies two release lines.** The shared connector tree
is at one commit at a time. While one release line needs the Adobe-era connector
and the next needs the ByteBooks one, a local full-suite run is valid for exactly
one of them, and the keystone test is what tells you which. Build the other with
`ADEPT_RMSDK` pointed at a second tree.

**The reader certificate is shared between generations.** `ReaderClientCert.sig`
is gitignored and copied in by `scripts/update-certificates.sh`. One certificate
signs both connectors, so a signing error on one generation is not evidence that
the certificate needs reissuing. Establish which service rejected the signature
before requesting a reissue.

**Activation endpoints already resolve to the new service.** The Adobe-era
activation and signing hostnames are CNAMEs to ByteBooks infrastructure, so an
activation minted today is a ByteBooks-service activation whichever connector
made it. An upgrade test on a freshly activated device therefore does not
represent a patron whose activation predates that change, and a clean pass there
is weaker evidence than it looks.

**Two trailing errors are workflow noise.** `E_ADEPT_DOCUMENT_CREATE_ERROR`
followed by `E_ADEPT_NOT_READY` at the end of a fulfillment log appear on runs
that demonstrably succeeded, including on the shipping connector against the
production server. They carry no verdict in either direction. Calibrate any new
diagnostic against a known-good run before reading it as a failure.
