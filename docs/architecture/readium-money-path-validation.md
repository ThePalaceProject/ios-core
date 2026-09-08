# Readium money-path validation ledger

One entry per Readium pin. Added in the same change that moves the pin in
`Package.resolved`. `scripts/check-dependency-money-paths.sh` matches on the
version string, so it must appear literally in the heading — and only in the
heading: as of PP-5091 the gate reads `## ` lines rather than the whole file,
because an unanchored match let one entry's prose satisfy a later pin move.

A fork has no upstream version number, so its heading names whatever
`Package.resolved` records for it: the revision when it is pinned by bare
revision, and the tag *and* the revision when it is pinned by tag. Naming both
is the safe default — the gate demands the version when one is present and the
revision when one is not, and a heading carrying both satisfies either.

See [readium-upgrade-validation.md](./readium-upgrade-validation.md) for the
paths to exercise and why this ledger exists.

<!-- audit-verified -->

Entry format:

```
## <version>

- Validated against: Palace <marketing version> (<build>), <device/simulator>, <library>
- Validated by: <role>
- Date: <YYYY-MM-DD>

| Path | Result | Notes |
|---|---|---|
| ... | pass / fail / not validated | ... |
```

A path is only `pass` when someone exercised it against a build carrying this
pin and recorded the outcome. Adjacent work that happened to touch a path is not
validation, and recording it as such would defeat the purpose of the ledger.

---

## 3.9.0

- Validated against: Palace 3.2.3 (490), iPhone 17 Pro simulator (iOS 26.1), A1QA Test Library
- Validated by: iOS maintainer
- Date: 2026-07-30

Recorded retrospectively. This pin shipped in 3.2.0 without validation, which is
the omission that motivated the ledger. The entry records what is known about the
pin now; it does not imply the paths were checked at the time.

| Path | Result | Notes |
|---|---|---|
| EPUB, Adobe DRM | not validated | Predates the ledger. No known regression attributed to this pin. |
| EPUB, LCP | not validated | Predates the ledger. No known regression attributed to this pin. |
| PDF, LCP | not validated | Predates the ledger. No known regression attributed to this pin. |
| Audiobook, LCP | fail | Streaming-from-license unusable. Two upstream defects, only one of which arrived with this pin: the range-clamp removal in readium/swift-toolkit PR #723, and the older buffer-everything behaviour in issue #579 (filed against toolkit v3.2.0, predates this pin). Both are being fixed on the unmerged `fix-issue-579` branch. See [readium-upgrade-validation.md](./readium-upgrade-validation.md). Palace works around it by requiring the full `.lcpa` on disk before playback. Borrow, download and playback-from-local were exercised on build 490 against A1QA and pass; streaming does not. <!-- audit-verified --> |
| Audiobook, OverDrive | not validated | Hotfix work in the 3.2.x line touched this path, but no structured validation against this pin was recorded. |
| Audiobook, Findaway | not validated | The 3.2.2 hotfix addressed a Findaway playback-rate crash, which is not the same as validating the path against this pin. |
| Open-access EPUB | not validated | Predates the ledger. |

The next pin change is expected to be the one carrying the upstream #579 fix.
That entry should confirm the LCP audiobook path specifically, and should be
paired with restoring streaming in the app rather than only moving the pin.

---

## 3.11.0

- Validated against: not yet validated
- Validated by: not yet validated
- Date: —

Recorded when the gate arrived on `develop`, not when the pin moved. `main` is on
3.9.0; `develop` moved to 3.11.0 in PR #1356 (PP-4848, crossing 3.10 and 3.11,
merged to `develop` 2026-07-29), which predates this ledger and so recorded no
money-path validation. This entry exists so the omission is visible in the ledger
rather than absent from it — the gate reads the version heading, and an entry
claiming validation nobody performed would defeat the ledger's only purpose.
<!-- audit-verified -->

**This pin has not shipped.** 3.11.0 is `develop`-only and reaches patrons no
earlier than 3.3.0, so nothing below is a live patron-facing risk today. It is a
release blocker for 3.3.0, not an incident.

| Path | Result | Notes |
|---|---|---|
| EPUB, Adobe DRM | not validated | The pin-bump change reported a green build and an LCP-profile facade test; neither exercises this path. |
| EPUB, LCP | not validated | The bump changed EPUB HREF fragment/query preservation and font CORS handling upstream — both squarely on this path, so it needs exercising before 3.3.0 ships. |
| PDF, LCP | not validated | No structured validation against this pin. |
| Audiobook, LCP | fail (streaming) / not validated (local) | Streaming from license measured as 0 bytes transferred on 3.11.0, the same as 3.9.0 — the upstream defect is unchanged by this bump (readium/swift-toolkit issue #579, still unmerged on `fix-issue-579`). Palace does not stream: since 3.2.3 build 492 the full `.lcpa` must be on disk before playback, so this does not block the path. Playback-from-local against a 3.11.0 build is NOT yet exercised. |
| Audiobook, OverDrive | not validated | No structured validation against this pin. |
| Audiobook, Findaway | not validated | No structured validation against this pin. |
| Open-access EPUB | not validated | No structured validation against this pin. |

Before 3.3.0 ships, this entry needs a real validation pass — at minimum the two
paths the bump's own changelog touches (EPUB/LCP rendering, LCP audiobook
playback-from-local) exercised against a 3.11.0 build, with results recorded here.
Note the LCP device-ID moved to the Keychain in 3.10: that changes behaviour
across delete/reinstall, so validation should include a reinstall cycle rather
than a single install.

## 3.11.0-palace.1 — ThePalaceProject/swift-toolkit @ 58413f8680a310ed6d98278687ab711e6be639c8

- Validated against: Palace 3.3.0 (494), iPhone Air simulator (iOS 26.1), A1QA Test Library
- Validated by: engineering (agent-assisted), SoD-reviewed (architect + qa_test + blast_radius)
- Date: 2026-08-14 (pin re-expressed as a tag 2026-09-08, PP-5091 — **no new validation**)
- Pin: `ThePalaceProject/swift-toolkit` fork = Readium 3.11.0 + the upstream `fix-issue-579` series (restores LCP audiobook chunked streaming-from-license). Gated behind `lcp_audiobook_streaming_enabled` (default OFF).

**Pin form.** Originally taken by bare revision. PP-5091 tagged that exact commit
`3.11.0-palace.1` in the fork and moved `Palace.xcodeproj` to
`exact: "3.11.0-palace.1"`. `Package.resolved` still records
`58413f8680a310ed6d98278687ab711e6be639c8` — the resolved revision did not move,
so **no code changed and the rows below carry forward unaltered**.
<!-- audit-verified -->

`Package.resolved` records the revision **and no `version` key**, even though the
project now states a version requirement. That is not an oversight. The
`ios-audiobooktoolkit` subproject is part of the same SwiftPM graph and still
pins this package by bare revision; SwiftPM unifies the two requirements and
resolves by revision, and a revision-resolved pin carries no version. Observed
directly: with both projects on the tag the resolve reports
`Readium … @ 3.11.0-palace.1` and writes the version; with the toolkit on a bare
revision it reports `@ 58413f8` and writes none. **The `version` key appears here
only once the `ios-audiobooktoolkit` pin moves too** (PP-5106) — committing it
before then would commit a state the repository cannot reproduce, since every
developer's and CI's next resolve would strip it straight back out.
<!-- audit-verified -->

Both open items below are tracked, not just described: PP-5106 for the toolkit
repin, PP-5107 for the EPUB/PDF/Adobe exercise.

The heading names the tag *and* the SHA for that reason: the gate demands the
version when `Package.resolved` carries one and the revision when it does not,
and today it does not.

> `3.11.0-palace.1` is a SemVer *prerelease*, which sorts **below** upstream
> `3.11.0`. It is safe only under an `exact:` requirement. Relaxing either
> project to a range would silently resolve to un-fixed upstream code, and the
> build would stay green. The non-SemVer alternative (`palace-3.11.0-issue-579.1`)
> was rejected for the opposite reason: SwiftPM would not parse it as a version,
> so the pin would have stayed revision-only and the tag would have bought
> nothing but a name.

| Path | Result | Notes |
|---|---|---|
| Audiobook, LCP (streaming) | pass | Flag ON: fresh borrow → instant Listen → **`.lcpa`: 0 bytes** on disk → plays via on-demand chunked decryption. Verified live on the A1QA "Reign of Terror" (Palace Marketplace LCP audiobook). Relaunch durability pinned (reconcile keeps `.downloadSuccessful`). |
| Audiobook, LCP (local / download-first) | pass | Flag OFF preserves today's download-first path byte-for-byte (unit + reconcile-table + fulfillment tests; full `.lcpa` lands, then Listen). |
| EPUB, LCP | not validated | **Justification corrected (PP-5091).** This row previously read "not exercised by this change (streaming is audiobook-only)". That is not the whole picture. The fork is 8 commits ahead of, and 0 behind, upstream `3.11.0`, and four of the files it edits are *not* audiobook-specific: `Shared/Toolkit/Data/Resource/BufferingResource.swift`, `Shared/Toolkit/ZIP/ZIPFoundation/ZIPFoundationContainer.swift`, `Shared/Toolkit/Data/ReadError.swift`, and `LCP/Content Protection/LCPDecryptor.swift`. Every LCP EPUB read traverses all four. The row stays `not validated` — nobody has opened an LCP EPUB against this pin — but the reason is "unvalidated shared-code change", not "unrelated code". |
| EPUB, Adobe DRM | not validated | Same correction: Adobe EPUBs are still ZIP containers read through `ZIPFoundationContainer` and buffered through `BufferingResource`, both of which the fork edits. Not exercised against this pin. |
| PDF, LCP | not validated | Same correction, and it also traverses `LCPDecryptor`. Not exercised against this pin. |
| Audiobook, OverDrive / Findaway | not validated | Unaffected (non-LCP fulfillment), but likewise never exercised against this pin. |

Known follow-up: the LCP resource-loader over-fetches (prefetches most of the book); time-to-first-audio win realized, storage win pending a read-ahead cap. Orthogonal to the flag; flag ships OFF.

Known follow-up (PP-5091): the shared-code exposure above is in neither PP-5091's
scope nor its out-of-scope list. Someone has to open an LCP EPUB, an Adobe EPUB
and an LCP PDF against a build carrying this pin before 3.3.0 ships, and record
the outcome here. Until then the four `not validated` rows are the honest state.
