# Validating Readium upgrades against the money paths

Readium renders and decrypts the content patrons borrow. A version bump can
change behaviour on those paths without producing a compile error, a failing
unit test, or any signal at all until a patron opens a book. This document
records why Palace gates Readium upgrades on manual validation, which paths must
be exercised, and how the evidence is recorded.

<!-- audit-verified -->

## What happened in 3.2.0

<!-- audit-verified -->
<!-- Provenance: PR #723 diff read directly (the BufferingResource.swift hunk
     shows the removed `clamped(to: 0 ..< length)` and bufferSize 8192 ->
     256*1024); issue #579 createdAt and body read via gh; the fix-issue-579
     commit list read via gh api. Checked 2026-07-30. -->

Palace 3.2.0 moved the Readium pin from 3.7 to 3.9. Two separate upstream
defects sit on LCP audiobook streaming, and it is worth keeping them apart
because they have different origins and only one of them arrived with the bump.

**The range clamp removal.** readium/swift-toolkit PR #723, "Remove the HTTP
server from the EPUB navigator", rewrote the shared `BufferingResource` even
though its title names only the EPUB navigator. The old `stream(range:)` clamped
the request with `requestedRange = requestedRange.clamped(to: 0 ..< length)`. The
rewrite drops that clamp, stops consulting the resource length, and adds a
read-ahead of `lowerBound + bufferSize` with the buffer size raised from 8 KB to
256 KB. Reads can therefore run past end of file, which surfaces through the ZIP
layer as an out-of-range read. This behaviour arrived with the 3.7 to 3.9 bump.

**The buffer-everything behaviour.** readium/swift-toolkit issue #579, "[Bug]
Audiobook Streaming Delay (`audioBook.lcpl`) - Chunks Fully Buffered Before
Playback Starts", was filed against toolkit v3.2.0, roughly ten months before
PR #723. Playback does not begin until every chunk has been buffered, and the
navigator reports `.playing` while it is still buffering. The maintainer's first
assessment was that `AVPlayer`'s resource loader requests the full length of the
resource regardless of byte-range support. A reporter has confirmed the
behaviour persists in 3.9.0. This one predates the bump.

Upstream is addressing both on the unmerged `fix-issue-579` branch, which is why
the two are easy to conflate. That branch carries, among others,
`7db3839c` "Clamp out-of-range ZIP reads and cap BufferingResource read-ahead"
and `3767d85d` "Stream LCP CBC resources in decrypted chunks". Nothing on that
branch has shipped in a release.

The practical consequence for planning: restoring the clamp alone would not give
back responsive streaming, because the buffer-everything behaviour is
independent of it and older. A future Readium bump should not be assumed to fix
open latency; the LCP audiobook path has to be validated against it directly.

Nothing in the 3.2.0 upgrade exercised LCP audiobook playback, so the clamp
change shipped unnoticed and was diagnosed months later, after patron reports.

The consequence outlives the diagnosis. Without streaming, an LCP audiobook's
entire `.lcpa` archive has to be on disk before playback begins, because the
archive is a single encrypted container with no partial-play threshold. Open
time became proportional to the size of the audiobook where it had previously
been independent of it. Measured against the A1QA staging library on build 490,
archives ranged from 438 MB to 1,897 MB, which on a typical connection is a wait
of minutes rather than seconds.

## The contract

A change to the Readium pin in
`Palace.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
requires an entry in `readium-money-path-validation.md` naming the new version.
`scripts/check-dependency-money-paths.sh` enforces this and runs in the
`tooling-integrity` CI job. A pull request that does not touch the pin is
unaffected.

The gate checks that validation was recorded, not that it was done well. It
exists to make the omission visible, which is the specific failure mode that
produced the 3.2.0 regression.

## Paths to exercise

Each path is exercised against a build carrying the new pin, on a simulator or a
device, using a real library account. Automated tests do not substitute here:
the failure modes are in rendering, decryption, and playback, which the test
suite stubs out.

| Path | What to confirm |
|---|---|
| EPUB, Adobe DRM | Borrow, download, open, page forward, reopen at saved position |
| EPUB, LCP | Borrow, download, open, page forward, reopen at saved position |
| PDF, LCP | Borrow, download, open, page through, reopen |
| Audiobook, LCP | Borrow, download to completion, play, seek across a track boundary, resume after backgrounding |
| Audiobook, OverDrive | Borrow, download, play, seek |
| Audiobook, Findaway | Borrow, download, play, seek |
| Open-access EPUB | Download and open with no account |

Record the outcome of each, including any that were skipped and why. A skipped
path is then a known gap rather than a silent one.

## Recording the result

Add an entry to `readium-money-path-validation.md` in the same change that moves
the pin. The entry names the version, the build it was validated against, the
role that validated it, and the per-path outcome. The gate matches the version
string against the entry's `## ` heading, so the version must appear literally
*there*; naming it only in the body does not satisfy the gate, and as of PP-5091
no longer appears to.

Three things the gate does not cover, and cannot be assumed away:

- It reads only `Package.resolved`, so a change to the *requirement* in the
  `.pbxproj` is invisible to it whenever the resolved revision stays put. Moving
  from `kind = revision` (a 40-character commit, immutable by construction) to
  `kind = exactVersion` (a tag, which can be force-moved) is exactly that shape:
  the pin's guarantees weaken and the gate waves it through, because the
  resolved bytes did not change. The **one-time form change** is what needs a
  human reviewer. Be precise about what this does and does not leave open: a tag
  that is later force-moved, or an `exact:` that is later relaxed to a range,
  both change the resolved revision, so both trip the gate normally. It is only
  the moment of changing the requirement's shape that passes unseen.

- It reads only the app's `Package.resolved`. The `ios-audiobooktoolkit`
  submodule pins `swift-toolkit` in its own project too, and that pin is
  ungated. Keeping the two identical is manual discipline; a drift between them
  means the app and the audiobook toolkit compile against different Readium
  code with no signal (see `submodule-tree-drift`).
- It cannot tell you *which* money paths a pin change touches. A fork whose
  stated purpose is audiobook streaming can still edit shared container,
  buffering, and decryption code that EPUB and PDF reads traverse — the
  `3.11.0-palace.1` entry is exactly that case. Read the pin's actual diff
  before writing the per-path rows.

## The fork, and what a migration owes

Palace pins a fork, `ThePalaceProject/swift-toolkit`, not upstream Readium. Any
change to the pin should establish where the fork now stands relative to
upstream before it moves, because the fork's content is three different things
and only one of them is a migration burden.

Measured 2026-10-26, with the pin at `3.11.0-palace.3`
(`6c8baddf38d135cb2d5ba24c9c7eb0d7d3fb2108`): the fork is 14 commits ahead of
upstream `3.11.0` and 3 commits **behind** upstream `3.11.1`, which was released
2026-10-16. So the pin is a fork of a superseded release.

The 14 commits are:

- **Upstream's own unreleased work, vendored early.** The clamped out-of-range
  ZIP read and capped `BufferingResource` read-ahead, streaming LCP CBC
  resources in decrypted chunks, honest playback state in `AudioNavigator`,
  media resources cached across loading requests, cancelled HTTP reads no longer
  reported as loading errors, and streamed reads failing when they end short.
  These came from upstream's `fix-issue-579` branch, taken before any release
  carried them because the LCP audiobook streaming path needed them. **That
  branch no longer exists upstream** — it 404s as of 2026-10-26 — so it either
  merged into `3.11.1` or was abandoned. Which of the two decides whether a
  migration sheds these commits or has to keep carrying them, and that has not
  been established: the comparison above matched commit subjects, not content.
- **Ours, and it has to be carried.** `Let a caller supply a CBC resource's
  plaintext length`, which adds `KnownLengthAcceptingResource`. The audiobook
  toolkit depends on it: computing a CBC resource's plaintext length reads the
  last encrypted blocks, and on device that 32-byte tail read cost 17.8 MB to
  35.5 MB of origin traffic. Nothing upstream has this.
- **Fork plumbing, discard on migration.** `Point the SPM integration check at
  this fork`.

So the question "do we need to bring our changes over" has a small answer —
roughly one real graft — but it rests on an unestablished premise. Before the
next pin move, compare the fork's twelve vendored commits against the target
upstream release by content rather than by subject, and record which are
already there. That turns the migration from a merge into a graft, or proves it
is not one.

## Scope

The gate covers Readium because that is the dependency with a demonstrated
history of silent money-path breakage in this codebase. The same reasoning
applies to any dependency that renders, decrypts, or fulfills content.
Extending the check is a matter of adding package identities to the script.
