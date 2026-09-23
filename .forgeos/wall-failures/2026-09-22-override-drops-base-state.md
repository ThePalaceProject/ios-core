---
date: 2026-09-22
pr: "#TBD"
source: reviewer-block
reviewer_ids: []
changeset_id: ""
wall: implementer
walls: [implementer, TDD, mutation]
severity: high
wall_status: proposed
applied_in: ""
detector_script: "scripts/check-override-drops-base-state.py"
detector_status: built
no-detector: ""
name: override-drops-base-state
type: evolving
status: active
created: 2026-09-22
last_refresh: 2026-09-22
freshness_window: 365d
owners: [audiobooks]
description: An override that replaces a base method wholesale drops the state that method maintained — twice in one changeset, on the same property
---

# An override that replaces a base method wholesale drops its state

## Finding (verbatim from the architect reviewer)

> `queuedTrackPosition` is never cleared on a same-track `play(at:)` —
> `LCPStreamingPlayer.swift:182` sets it unconditionally, but the only clears are
> the streaming-timeout and the one gated on `lastStartedItemKey != currentKey`. A
> TOC/bookmark tap onto a chapter *inside the current track* reaches neither.
> `currentTrackPosition` prefers it and the 0.25s observer republishes it, so
> position freezes until the next track boundary — frozen timecodes and a frozen
> **saved** position (progress/bookmark loss). The base class clears it in its seek
> completion (`:287`); the override dropped that.

## What actually happened

The same property, the same method, twice in one changeset.

`OpenAccessPlayer.playCallback` both SETS `queuedTrackPosition` — so
`currentTrackPosition` reports where a seek is going rather than where the audio
still is — and CLEARS it when the seek lands. `LCPStreamingPlayer` overrides that
method wholesale.

**Omission 1:** the override never touched the property at all. Every
position-derived label therefore fell through to `avQueuePlayer.currentItem`, the
PREVIOUS track. That is the "you land on the previous chapter and then it
switches" the ticket was filed about.

**Omission 2:** the fix restored the set and put the clear in the `.playing`
observer, gated on the current item changing. A seek within the current track
changes no item. So the position froze at the target until the next track
boundary — and because that value is what gets SAVED, the freeze costs the patron
progress and bookmarks. Strictly worse than the defect being fixed.

Both have one shape: the base's bookkeeping is invisible at the override's call
site. Nothing in the type system requires an override to maintain what the base
maintained, and an override is exactly where a reader stops comparing.

## Walls that should have caught it (and why they didn't)

- **implementer**: the trap was already written down. This changeset ADDS trap 11
  to the area checklist — *"`LCPStreamingPlayer.playCallback` overrides the base
  seek path wholesale, so anything the base does there is silently absent for
  LCP"* — and then committed the second instance of it. Writing the rule is not
  applying it.
- **mutation**: a property that is never assigned has no line to mutate; a
  property assigned once has no second line either. `palace_mutate` reported 0
  mutation points on the relevant delta and was right to.
- **TDD**: `LCPStreamingPlayer` has no unit tests. Not "weak tests" — none. The
  existing `StubbedLCPStreamingPlayer` drives `move(to:)`; reaching `playCallback`
  needs a queue of real `AVPlayerItem`s.
- **device**: omission 2 only shows on a seek WITHIN a track, and the manual pass
  used cross-track chapter taps, which is the case that works.

## Proposed permanent fix

1. **Landed with this entry.** The clear is FUNNELLED: every exit from
   `playCallback` already routes through the fire-at-most-once completion wrapper,
   so the clear lives there and an exit that forgets is unrepresentable. Patching
   the exits individually is what produced omission 2 — the first patch covered
   four of five.

2. **Detector**, `scripts/check-override-drops-base-state.py`. For every
   `override func`, the properties the BASE method assigns — restricted to those
   the base class READS elsewhere, i.e. live state — must be assigned in the
   override too. Overrides that delegate via `super.<same method>` are exempt.
   Baselined by `<Class>.<method>:<property>` so the two pre-existing findings do
   not block, and failing when a baselined entry stops firing so the amnesty
   cannot go stale.

## Detector script

**Script:** `scripts/check-override-drops-base-state.py`
**Tests:** `scripts/tests/test_check_override_drops_base_state.py` (11 cases; every
violating fixture paired with a near-identical clean one)
**Wired into:** `scripts/verify-pr.sh`, asserted by
`scripts/tests/test_verify_pr_ratchet_wiring.sh` in both directions plus the
stale-baseline direction.

**What it catches:** an override that reimplements a base method without
maintaining the base's live instance state. **Proven** by reintroducing the
original defect — deleting `queuedTrackPosition = position` from the override
makes it exit 1 naming `LCPStreamingPlayer.playCallback`.

**What it does NOT catch, stated so a clean run is not over-read:** omission 2. A
set without a matching clear satisfies "assigned somewhere". It answers *was this
state considered*, never *was it handled correctly*. It is also line-based, not an
AST: an override that maintains the property through a helper reads as a miss.

**Five silent-pass vectors, all found by fixtures or review, none by the tree.**
`CLASS_RE` required an inheritance clause, so a base declared `class Foo {` was
invisible and every subclass was skipped. `STORED_PROP_RE` refused any declaration
with an initialiser, so `var isLoaded: Bool = false` and its whole category went
unchecked. Comments were stripped before every textual test EXCEPT the `super.`
exemption, so `// unlike super.playCallback(...)` in a doc comment exempted the
method — an escape hatch nobody wrote. `funcs` was keyed `(class, name)`, so
overloads collapsed and an override could be compared against the wrong base body
(`OpenAccessPlayer` really does have two `play` definitions). And counting a
property's own declaration as a "read" made every stored property look live.

The real tree could not have surfaced any of them: it exercises exactly one shape.
That is this repository's "a gate that cannot fail reports a pass", five times,
inside the gate written to stop one instance of it. Each now has a fixture.

**One baselined entry, not two.** The first draft baselined
`buildPlayerQueue:lastKnownPosition` as well, asserting both were real. An
architect review showed it was wrong in substance — the base assigns
first-track-at-0.0, a reset to book start, and the LCP override NOT doing that
preserves a restored position — and, worse, that baselining it would have
PERMANENTLY REQUIRED the omission, because a baselined entry that stops firing
fails the gate. An anti-rot control pointed at a false positive inverts into a
lock. It now carries an inline `// no-override-state:` with the reason beside the
code.

**False-positive escape hatch:** `// no-override-state: <reason>` on the
`override func` line itself. Line-adjacent deliberately — a marker on a preceding
line is silently ignored, which produces an annotation that looks applied and is
not.

**Severity: high.** The failure mode is silent, survives a green suite and a
device pass, and costs patron progress.

## Application log

- 2026-09-22 — omission 1 caught on device by the reporter; omission 2 caught by
  an independent architect review before merge. Both fixed in the PP-5205 PR.

## Related entries

- `2026-09-22-onchange-has-no-birth-fire.md` — the other reviewer block on the same
  changeset. Both are wiring defects under correct, well-tested pure rules.
