---
date: 2026-09-29
source: near-miss
walls: [invariant-retirement-needs-a-census, unrepresentable-beats-tested]
severity: high
wall_status: open
glyph: SPEC.WrongPinned
glyph_fit: good
---

# collapsing-a-context-dependent-value-into-a-case-dependent-one

## Finding

Wave 6 extracted `AudiobookSessionManager`'s recovery logic into
`AudiobookPlaybackRecoveryReducer`. Shipped code published the player state
from a disjunction over the CONTEXT:

    // AudiobookSessionManager.swift:2798-2812 @ 10625c00d
    var willRecover = shouldTriggerSAMLReauthForPlaybackFailure(...)
    willRecover = willRecover || shouldTriggerOverdriveRefulfill...(...)
    willRecover = willRecover || shouldAutoReopenOnColdLoadFailure(
        hasEverStartedPlayback:, hasCurrentBook:, alreadyAttempted:)
    state = willRecover ? .loading(bookId:) : .error(bookId:, "Playback failed")

The extraction replaced it with a property of the DECISION CASE:

    // AudiobookPlaybackRecoveryReducer.swift:98-99
    case .bearerTokenRefulfill:
        return false          // unconditional

These are not the same function. `willRecover` reads three independent
predicates; `keepsPlayerLoading` reads only which arm won. They agree
everywhere except the cell where a LOWER-precedence term is true while the
winning arm's own term is false.

That cell is reachable: a bearer-token title (BiblioBoard / Unlimited Listens)
whose entitlement is expired on the **first play of the session**. The bearer
arm wins (it precedes cold-load), but `coldLoad` — `!hasEverStartedPlayback &&
hasCurrentBook && !alreadyAttempted` — is TRUE.

- shipped: `willRecover == true` → `.loading`
- branch:  `keepsPlayerLoading == false` → `.error(bookId:, "Playback failed")`

Blast radius is larger than a flicker: `AudiobookSessionPresenter.swift:539-540`
calls `clearActiveSession()` on **any** `.error`, so the player UI is torn down
and then re-opened by the refulfill. Audiobook playback critical path.

Verified firsthand at both ends before acting, not accepted on report.

## What actually happened

The author knew about a real pre-existing bug — `willRecover` never gained a
bearer-token term when 323-Cause-3 added that arm — and correctly decided to
PRESERVE it rather than fold a behaviour change into a decomposition. That
judgement was right and is not the failure.

The failure is that **preserving a context-dependent value through a
case-dependent representation is not possible**, and the representation change
was invisible as a change. Nothing in the diff says "this value now depends on
less than it used to". `decide(context) -> Recovery` plus
`Recovery.keepsPlayerLoading` type-checks, reads cleanly, and silently drops
two of the three inputs the shipped expression consumed.

Then the documentation asserted the opposite of what the code did
(`AudiobookPlaybackRecoveryReducer.swift:88-90`, "This move reproduces the
shipped behaviour exactly"), and the TEST pinned the new value as if it were
the old one:

    // AudiobookPlaybackRecoveryDecisionTableTests.swift:224-233
    context(..., coldLoadAttempted: false, hasEverStartedPlayback: false)
    XCTAssertEqual(decision.keepsPlayerLoading, false,
      "The decision and the state it publishes are one value — ...")

That assertion message is the false premise stated out loud. In shipped code
the decision and the published state were emphatically NOT one value; they were
two functions of overlapping inputs. The sentence that justifies the design is
the sentence that is wrong.

## Why every instrument we had reported green

This is the part worth keeping.

- **Mutation: 41/41, 100%.** QA's observation is the sharpest statement of the
  limit: *mutating `.bearerTokenRefulfill` to `true` IS killed — by the three
  tests that pin the wrong value.* The mutant that would have FIXED the bug
  dies against tests asserting the bug. A kill rate measures agreement between
  code and tests; when both encode the same wrong spec it is a perfect score
  over a wrong answer. CLAUDE.md already says mutation is blind to cases you
  never wrote; this is stronger — it is blind to cases you wrote WRONG, and it
  actively rewards them.
- **The decision table was a real table.** Both reviewers confirmed every
  simultaneously-satisfiable pair is enumerated with a which-arm-wins
  assertion. Enumerating the table is necessary and was done. It does not help
  when the expected value in a cell is derived from the new code rather than
  from the old.
- **The full suite was green (9174/0)** and stays green, because the only test
  covering the cell asserts the new value.
- **`git range-diff` / net-diff showed zero logic lines lost.** The architect
  verified the decision ORDER is verbatim. It is. The order was never the
  problem; the state derivation was, and it was not a moved line — it was a
  rewritten expression that happens to be shorter.

**The one instrument that would have caught it** is the one neither automated
check performs: for each extracted value, name every input the ORIGINAL
expression read, and confirm the replacement still reads all of them. Both
reviewers found it by doing exactly that, by hand, independently.

## Walls that should have caught it

- **[[invariant-retirement-needs-a-census]]** — closest fit, and it fired for
  the PRE-EXISTING bug (a recovery arm added without updating `willRecover`, a
  second encoding of the same invariant). It did not fire for the new one
  because the entry is framed around *adding an arm to a set*; here an
  expression was narrowed. Same disease, different syntax. The entry should say
  that REPLACING an encoding needs the same census as adding to one — and that
  the census is over INPUTS, not over call sites.
- **[[unrepresentable-beats-tested]]** — prescribes exactly the right remedy
  and nobody reached for it. `Recovery.keepsPlayerLoading` makes the wrong
  thing effortless to express; a signature that cannot yield the state without
  the context makes it unrepresentable.
- **[[test-the-producer-not-the-helper]]** — adjacent. The tests drive
  `decide` (the new pure function) and nothing drives `handleManagerState`,
  which is where the published state actually reaches a patron. The hub file
  itself records "nothing in PalaceTests drives `handleManagerState`".
- **Nothing covers "a refactor narrowed a function's inputs."** That is the
  gap.

## Proposed permanent fix

**1. The rule.** *When extraction replaces an expression, enumerate the inputs
the original read and prove the replacement reads all of them.* Verbatim-move
review checks that lines did not change. This checks that a rewritten line
still DEPENDS on the same things — which is what "behaviour preserved" actually
means, and which a diff cannot show.

**2. Make it unrepresentable, per the wall above.** `decide` should return the
recovery and the published state together, with the state computed from the
context:

    static func decide(_ c: Context) -> Outcome    // { recovery, keepsPlayerLoading }

so no caller can obtain a recovery and then ask a case-only property for the
state. The shipped disjunction moves into `decide` intact. The pre-existing
bearer-token bug is then still preserved and still one line to fix — the
original, correct goal — but preserved FAITHFULLY.

**3. Derive the expected value in a characterization test from the OLD code,
never the new.** The cell at `:224-233` was written by reading the reducer. For
a pin whose whole purpose is "this equals what shipped", the expected value has
to come from the shipped expression — ideally by running it. A characterization
test that agrees with the implementation it characterizes is a tautology with
extra steps.

**Detector: not proposed.** "A refactor narrowed an expression's inputs" is a
dataflow property, not a grep, and I will not pretend a regex approximates it.
CLAUDE.local.md's admission test and ~150-line ask-first threshold both apply.
Recorded so a second instance has something to attach to; two instances would
justify a real analysis pass over extracted pure functions.

## Application log

- 2026-09-29: Caught by BOTH Wave 6 reviewers independently, before merge.
  Branch `arch/wave6-audiobook-session` @ `90fe0ef0f` blocked; fix not yet
  applied. The pre-existing bearer-token `willRecover` gap is recorded
  as a LOCAL-ONLY record (`~/harness/findings/2026-09-29-willrecover-missing-
  bearer-token-term.md`, not reachable by other contributors — the same trap
  this entry was moved here to escape). Its substance is in the tree and needs
  no external reference: the preserved behaviour is documented at
  `Palace/Audiobooks/AudiobookPlaybackRecoveryReducer.swift:184-198` and pinned
  by `testPublishedState_bearerTokenMidListen_publishesError`
  — that one is a genuine shipping defect and needs product validation before
  anyone flips it.
