---
date: 2026-09-22
pr: "#TBD"
source: shipped-bug
reviewer_ids: []
changeset_id: ""
wall: implementer
walls: [implementer, TDD]
severity: medium
wall_status: open
applied_in: ""
detector_script: ""
detector_status: no-detector
no-detector: "The class is a cached @Published whose only writer is a reactive event stream, while a sibling label on the same row reads the same fact live. Both halves are ordinary, correct-looking code in different files; nothing in either signature distinguishes a cache that may lag from one that may not, and the defect is the RELATIVE latency of two readers of one fact — not a call-pattern a static scan can name. The durable guard is the area checklist trap plus the state table, both landed with this entry."
name: cache-written-only-by-the-signal-it-outruns
type: evolving
status: active
created: 2026-09-22
last_refresh: 2026-09-22
freshness_window: 365d
owners: [audiobooks]
description: A cached chapter label lagged four seconds behind the timecodes beside it, because its only writer was the event stream the user action outran
---

# A cache written only by the signal the user action outruns

## Finding (verbatim from bug report)

> "currently, toc is dismissed immediately, you land on the preivous chpater and
> then it switches, this is where we were showing the loading screen preivoulsy"

Device recording, build 509, 2026-09-22. Frames 19-29 of the capture show the
player after tapping Chapter 42:

| label | reads | belongs to |
|---|---|---|
| chapter title | "Chapter 18" | the chapter just left |
| chapter time-left | `-17:48` | Chapter 42 (TOC: 42 = 17:48) |
| book remaining | "11 hr 03 min" | Chapter 42 |

The title flipped to "Chapter 42" at frame 30, on the first frame showing audio
had started (0:02 elapsed).

## What actually happened

One fact — which chapter is playing — reaches that row through two paths.

The timecodes are computed live: `AudiobookPlaybackModel.timeLeft` reads
`audiobookManager.currentChapter`, which derives from the player's
`currentTrackPosition`, and that already prefers `queuedTrackPosition` — the
optimistic seek target the player publishes the moment a seek begins. So they
moved to Chapter 42 immediately.

The title reads `AudiobookSessionManager.currentChapter`, a `@Published` CACHE
whose only writer is `handlePositionUpdate`, called from the manager's
`.positionUpdated` stream. `skipToChapter(at:)` called `playAtPosition` and
touched the cache not at all. A seek pauses the player, so the stream that is the
cache's only writer is exactly the stream a seek silences — the cache could not
update until playback resumed, which is the four seconds the recording shows.

Neither half looks wrong alone. The cache is a legitimate optimisation, written
from the correct event; the live readers are correct. The defect is that a user
action moved the underlying fact and only one of the two readers could see it
before the next event arrived.

It shipped invisible because the full-screen "Downloading…" panel covered that
window. PP-5205 removed the panel, which is what made a pre-existing latency
visible as a bug.

## Walls that should have caught it (and why they didn't)

- **implementer**: the PP-5205 fix reasoned about the overlay's own state machine
  and about the player's `queuedTrackPosition`, and verified both. It did not ask
  the different question — *once the panel is gone, what is under it?* Removing a
  cover is a change to everything the cover was hiding, and that set was never
  enumerated.
- **TDD**: every chapter-label test drives the reactive path, because that is the
  only path that existed. A test written from the writer's side cannot discover a
  writer that should exist and does not. The states × events table would have:
  `currentChapter` has exactly one writer and two triggering events (reactive
  position, explicit selection), and the explicit-selection cell was empty.
- **verify-pr / mutation**: both are closed over code that exists. A missing
  writer has no line to mutate.

## Proposed permanent fix

1. **Landed with this entry.** `ChapterNavigationPolicy` in
   `Palace/Audiobooks/AudiobookPositionPolicy.swift` — `skipToChapter(at:)`
   publishes the chosen chapter immediately, and a content-keyed hold
   (`navigationTargetTrackKey`) stops an update for the track being left from
   flipping the label back during the fire-and-forget seek. The transition table
   ({no hold, hold matches, hold mismatches} × {chapter changed, unchanged}) is
   asserted whole in `ChapterNavigationPolicyTests`.

2. **Checklist trap**, `docs/architecture/areas/audiobooks/verification-checklist.md`
   §7: when a change makes an area of the player visible that a blocking overlay
   previously covered, enumerate every value rendered in that area and name, per
   value, which writer updates it and on which event. A value whose only writer is
   an event stream the user action suppresses is the defect.

3. **The generalisation, for the area checklist:** when two labels on one screen
   render the same underlying fact and one of them is cached, they must share a
   writer or the cache must be written by the action too. Ranking readers by
   latency is the diagnostic that names this class in one step — the split display
   in the table above localised this bug before any code was read.

## No detector — justification

See the `no-detector:` field. Concretely: the violating shape is
`@Published private(set) var currentChapter` assigned in exactly one private
method reached from one Combine sink, with a sibling computed property in a
different module reading the same fact from a different object. A static check
strong enough to flag that would flag every cache in the app; one narrow enough
not to would be keyed to this instance and catch no future one. The two guards
above are the wall.

## Application log

- 2026-09-22 — fix applied in the PP-5205 PR (see `applied_in` once merged).

## Related entries

- `2026-09-21-guard-refusal-renders-as-success.md` — same shape one level up: a
  state that is correct in isolation reads as the good outcome to whoever
  consumes it.
