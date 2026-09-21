---
name: pp5138-epub-position-read-dialect
created: 2026-09-16
author: claude-opus-5
---

**ADR refs:** none — no prior decisions recorded for the touched areas. Checked
`docs/architecture/` for any decision governing the reading-position wire format
or annotation dialect; there is none. The ForgeOS ADR ledger was not queried
because ForgeOS governance is OFF in this environment (`FORGEOS_ENABLED` unset,
per CLAUDE.local.md) and the MCP tools reach an external API the harness does
not require here.

## Context

Palace POSTs an EPUB reading position as Readium `Locator` JSON:

    {"href":…,"type":…,"title":…,"locations":{progression,totalProgression,position}}

and reads it back through `TPPBookLocation.convertToLocator`, which parses the
flat Palace dialect:

    {"href":…,"@type":…,"progressWithinChapter":…,"progressWithinBook":…,"position":…}

Nothing reconciles the two. Proven at the byte level in
`PalaceTests/Sync/EPUBPositionWireFormatTests.swift` (committed red, 3012905cc).

Two user-visible consequences, both on PP-5138:

1. `TPPLastReadPositionSynchronizer.syncReadPosition` suppresses the sync prompt
   when `localLocation?.locationString == serverLocationString`. Those are two
   different dialects, so the comparison is unreachable — the prompt fires even
   when both devices sit on the identical page, and never settles.
2. Converting the posted bytes back yields `progression == nil`,
   `totalProgression == nil`, `position` defaulting to 1 — so "Move" drops the
   within-chapter offset and lands the patron at the top of the chapter.

**Direction (owner's call, 2026-09-16): fix the READ side only.** The write side
stays on Readium `Locator` JSON and will be reworked later in line with the
Android client. That makes this change client-local: it requires no CM or
Android coordination, and it fixes positions already stored server-side in
either dialect.

## Claims

- adds `EPUBPositionDialect` in `Palace/Reader2/Bookmarks/EPUBPositionDialect.swift`,
  a parser reading href/progression/totalProgression/position/title/cssSelector
  from EITHER dialect (nested `locations` preferred, flat keys as fallback)
- migrates `TPPBookLocation.convertToLocator(publication:)` to read its fields
  via `EPUBPositionDialect` instead of flat keys only
- migrates `TPPLastReadPositionSynchronizer.syncReadPosition`'s
  same-page check from raw string equality to a dialect-independent
  comparison of the parsed position fields
- migrates `TPPBookmarkFactory.make(fromServerAnnotation:)` to read
  href/progressWithinChapter/progressWithinBook via `EPUBPositionDialect`
- adds tests covering both dialects and the mixed-dialect same-page case

## Anti-claims

- does NOT change what Palace POSTs. `TPPLastReadPositionPoster.makeSnapshot`
  keeps emitting Readium `Locator` JSON; the wire format is unchanged and this
  change is invisible to the CM and to Android.
- does NOT change `TPPBookLocation(locator:type:publication:)` — the flat
  dialect remains what the local registry stores.
- does NOT change `TPPBookmarkSpec.init`'s `progressWithinBook` derivation.
  That reads the same bytes and therefore posts `progressWithinBook: 0.0` in
  every EPUB reading-position annotation body — a real defect of the same root
  cause, but it is a WRITE-side field and is deferred to the Android alignment.
- does NOT change the device-stamp arm (`EPUBPositionAdapter.post` dropping
  `PositionSnapshot.device`; `TPPAnnotations.postReadingPosition` re-deriving
  it as `currentUserAccount.deviceID ?? ""`). Also write-side, also deferred.
- ~~does NOT change the audiobook or PDF position paths.~~ **RETRACTED —
  see the 2026-09-21 amendment below.** The `device:` stamp is written by
  `TPPAnnotations.postReadingPosition`, which is shared by four callers,
  two of them audiobook paths.
- does NOT change public surface of `TPPBookLocation` or `TPPReadiumBookmark`.

## Files in scope

Consolidated across both amendments below — the intent-recorded gate reads
this section only, so every file the branch touches is listed here.

- Palace/Reader2/Bookmarks/EPUBPositionDialect.swift
- Palace/Reader2/Bookmarks/TPPBookLocation+Locator.swift
- Palace/Reader2/Bookmarks/TPPBookmarkFactory.swift
- Palace/Reader2/Bookmarks/TPPAnnotations.swift
- Palace/Reader2/BusinessLogic/TPPLastReadPositionSynchronizer.swift
- Palace/Reader2/BusinessLogic/TPPLastReadPositionPoster.swift
- Palace/Reader2/ReaderPresentation/ReaderModule.swift
- Palace/AppInfrastructure/ReaderService.swift
- PalaceTests/Sync/EPUBPositionWireFormatTests.swift
- PalaceTests/Sync/BookmarkSpecConformanceTests.swift
- PalaceTests/Reader/EPUBPositionDialectTests.swift
- PalaceTests/Reader2/TPPLastReadPositionPosterTests.swift
- PalaceTests/Reader2/TPPLastReadPositionSynchronizerTests.swift
- Palace.xcodeproj/project.pbxproj
- .gitmodules
- mobile-specs
- mobile-bookmark-spec
- .claude/skills/swarm/SKILL.md
- docs/SystemRequirements.md
- docs/architecture/triage-bot-shared-architecture-proposal.md

---

## Amendment, 2026-09-16 — write side now in scope

The original plan deferred the write side "for unification with the Android
client later". Investigating that unification showed there is nothing to
negotiate: the format is already specified, and this client is the one
diverging from it.

`ThePalaceProject/mobile-specs` (current; the vendored `mobile-bookmark-spec`
submodule is its archived predecessor, pinned at that repo's first commit and
loaded by no test) defines the EPUB reading position as `LocatorHrefProgression`
— a FLAT object requiring `@type`, `href`, `progressWithinChapter`. Android
emits exactly that, parses only that, vendors the spec as a submodule, and runs
its fixture corpus as a conformance suite.

Palace posts the Readium `Locator` shape, which has no `@type`. The spec directs
a client meeting an untyped locator to read it as `LocatorLegacyCFI`; Android's
`SerializedLocators.parseLocator` does that, and `Reader2Bookmarks` then returns
null for a CFI locator on an EPUB. Every EPUB reading position iOS has written
is silently discarded on Android.

The local registry format is already spec-conformant, so the fix is to post the
bytes we already store.

## Additional claims

- migrates `TPPLastReadPositionPoster.makeSnapshot` from `locator.jsonString()`
  to the stored `TPPBookLocation.locationString`
- adds `TPPBookLocation.unitInterval` clamping both progressions to 0.0…1.0
- migrates `TPPAnnotations.postReadingPosition`'s device stamp from
  `currentUserAccount.deviceID ?? ""` to `AnnotationDevice.currentID()`
- migrates the two reading-position `drmDeviceID` call sites (`ReaderModule`,
  `ReaderService`) to `AnnotationDevice.currentID()`
- adds `"null"` as `AnnotationDevice.currentID()`'s fallback for an empty
  device identifier, matching the spec and the Android client

## Additional anti-claims

- does NOT change the bookmark (`oa#bookmarking`) locator shape — explicit
  bookmarks already serialize through `TPPReadiumBookmark` in the flat dialect
- does NOT change `TPPBaseReaderViewController`'s `drmDeviceID`, which feeds
  `TPPReaderBookmarksBusinessLogic`, not the position synchronizer
- does NOT repoint the `mobile-bookmark-spec` submodule at `mobile-specs`, and
  does NOT wire its fixture corpus into the suite — both are recommended and
  neither is done here
- ~~does NOT change the audiobook or PDF position paths~~ **RETRACTED — see
  the 2026-09-21 amendment below**

### Files added to scope by this amendment (see the consolidated list above)

- Palace/Reader2/BusinessLogic/TPPLastReadPositionPoster.swift
- Palace/Reader2/Bookmarks/TPPAnnotations.swift
- Palace/Reader2/ReaderPresentation/ReaderModule.swift
- Palace/AppInfrastructure/ReaderService.swift
- PalaceTests/Reader2/TPPLastReadPositionPosterTests.swift

---

## Amendment 2, 2026-09-16 — vendored spec repointed and wired

The earlier anti-claim "does NOT repoint the submodule, does NOT wire the
fixture corpus" is withdrawn at the owner's direction; both are done here.

- migrates the `mobile-bookmark-spec` submodule to `mobile-specs` (path and
  name both change; the old repo is archived and was pinned at its first commit)
- adds `PalaceTests/Sync/BookmarkSpecConformanceTests.swift`, running the
  spec's own fixture corpus and reading the required-key list out of
  `locatorSchema.json` rather than restating it
- updates the submodule-name guard lists in `.claude/skills/swarm/SKILL.md`,
  which protect against the gitlink-to-symlink destruction incident

The corpus is read from the working tree via `#filePath`, and its absence
FAILS rather than skips. Verified by hiding the corpus: all 5 cases fail.
Verified the suite catches the real defect by reintroducing it in
`makeSnapshot`: the posted-payload assertions go red on `@type`,
`progressWithinChapter` and `locations`.

### Files added to scope by this amendment (see the consolidated list above)

- .gitmodules
- mobile-specs
- mobile-bookmark-spec
- PalaceTests/Sync/BookmarkSpecConformanceTests.swift
- .claude/skills/swarm/SKILL.md
- docs/SystemRequirements.md
- docs/architecture/triage-bot-shared-architecture-proposal.md

---

## Amendment, 2026-09-21 — the audiobook/PDF anti-claim was false

Raised by the blast_radius reviewer, and it is correct: the anti-claim "does
NOT change the audiobook or PDF position paths" does not hold.

`TPPAnnotations.postReadingPosition` (`Palace/Reader2/Bookmarks/TPPAnnotations.swift`)
is the single POST used by **four** callers, not one:

1. EPUB reading positions — the subject of this ticket
2. PDF positions (`TPPPDFDocumentMetadata` -> `EPUBPositionAdapter.post`)
3. Audiobook **listening** positions (`postListeningPosition`)
4. Audiobook **bookmarks** (`postAudiobookBookmark`, motivation `.bookmark`)

Changing the `device:` argument there changes the wire bytes for all four on
any non-Adobe library. The original anti-claim was written against the
read-side scope and was not revisited when the 2026-09-16 amendment brought
the write side in. That is the scope-drift the anti-claims exist to catch,
and it took a reviewer rather than the gate to catch it.

**Behavioural reach is contained** — traced, not assumed:

- `AudioBookmark` has no `device` field, and `isSimilar` compares positional
  fields only, so audiobook dedup cannot observe the stamp.
- `AudiobookBookmarkBusinessLogic` and `TPPPDFDocumentMetadata` already called
  `AnnotationDevice.currentID()` themselves, so this **aligns** those paths
  with the EPUB one rather than splitting them.

So the correct disposition is this amendment plus coverage, not a code change.

### Follow-up from the same review round

- `TPPLastReadPositionSynchronizer.identifiesADevice` was added so a
  non-identifying stamp (`nil`, `""`, or the spec's shared `"null"`) can never
  satisfy the same-device rule. Two devices both reporting one of those used
  to look like the same device, which SUPPRESSED the prompt — the silent
  inverse of the over-prompting this ticket fixes. Covered by
  `TPPLastReadPositionSynchronizer_NonIdentifyingDeviceTests` (all three
  variants confirmed RED before the fix).
- `AnnotationDevice.currentID()`'s `"null"` fallback now has coverage on both
  arms; deleting the guard fails two named tests (verified by mutation).

### Still NOT in scope

- explicit EPUB bookmarks still post `userAccount.deviceID` via
  `TPPBaseReaderViewController` -> `TPPBookmarkFactory`, so they can still put
  `""` on the wire on a non-Adobe library. Pre-existing, unchanged here.
- `TPPReadiumBookmark` bookmark writes remain unclamped by `unitInterval`.
