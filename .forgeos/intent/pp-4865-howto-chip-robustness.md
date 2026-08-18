# PP-4865 follow-up — reach the answer from any topic chip

Follow-up to `pp-4865-triage-bot-keyword-strength-tiers.md` (PR #1379/#1382).
That change fixed *whether* the bot suggests; this one fixes *whether the patron
can reach the suggestion at all*.

## Problem

With the AI fallback off, a paraphrase × chip sweep (12 intents, several
phrasings each, under every chip a patron might plausibly pick) answered 35 of
80 cells. Known issues were fine — 12/15, because a patron with a broken
audiobook does pick "Audiobook". How-tos collapsed to 22/65, and nearly every
failure on a plausible-but-different chip was a BLIND escalation: the catalog
held the answer and the patron could not reach it.

Worse, the absence was not neutral. With the right how-to excluded from the
candidate set, a known issue could win the category by default — "can I get
notified when my hold is ready?" under `library` was confidently answered with
the KI-006 hold-desync workaround.

## Claims

- How-to entries are matched from EVERY category; known issues stay scoped to
  the selected chip. `KnowledgeBase.entries(matchableFrom:)` replaces
  `entries(in:)`, which is deleted (it had one caller, and its semantics are the
  defect).
- The match card's badge is derived from `kind` before `status`, so a
  `generic_flow` ladder no longer badges as "How to". The decision moves to
  `KBMatchBadgePolicy` in TriageBotCore, because `TriageBotUI` is behind
  `canImport(UIKit)` and macOS `swift test` cannot reach it.
- The card's VoiceOver label announces the badge instead of
  "Known issue match: <internal id>", which was factually wrong for how-tos and
  ladders.

## Anti-claims

- does NOT add, remove, or reword any KB entry, keyword, workaround, or guided
  step — `catalog.json` is byte-identical to `origin/develop`.
- does NOT change the matcher. Filler-variation matching was implemented,
  measured, and REMOVED during review; `TextTokenizer` is byte-identical to
  `origin/develop`. See "Retracted" below.
- does NOT change the reducer, the conversation state machine, the telemetry
  contract, or `ResolutionTrace`.
- does NOT change scoring, the strength partition, the runner-up/ambiguity
  guards, `confidence_threshold`, the version gate, or the context filters.
- does NOT enable or change the AI fallback wiring.
- DOES change UI: one badge label and one accessibility label on `KBMatchCard`
  (the previous intent file's blanket "does NOT change any UI" does not hold for
  this change, which is why this is a separate intent).

## Retracted during review

Filler-variation matching — letting a determiner in a keyword match a different
determiner in the patron's text, so `keep the book longer` matched "keep this
book longer". Two SoD review rounds each surfaced a defect from it:

1. `"that"` is a complementizer, not a determiner, in the only two shipped
   keywords using it (`notification that`, KI-006). Substitution collapsed them
   to "notification + <any determiner>", handing the hold-desync workaround to a
   patron asking about due-date reminders. Chaos-qa F-002, via a new vector.
2. `add my card` (HT-008) then covered "add a card" (KI-009), so the two entries
   became indistinguishable and the bot asked instead of answering.
3. The fix for (2) — narrowing KI-009's keyword — cost KI-009 real reach:
   "I add a card and nothing happens" moved from KI-009 to HT-008.

It bought +2 of 80 paraphrase cells. Insertion had already been refused for
costing one misroute to buy four cells; substitution cost more and bought less,
so it goes by the same rule. Removing it also removes a thin-keyword guard, a
collision lint, a catalog edit, and ~100 lines of KMP port contract.

Determiner variation remains a real gap in patron phrasing. The evidence says
the answer is catalog phrasing coverage grounded in real tickets, not a matcher
rule — that is a separate, ticketed piece of work.

## Files in scope

- `Palace/Packages/PalaceTriageBot/Sources/TriageBotCore/KB/KnowledgeBase.swift`
- `Palace/Packages/PalaceTriageBot/Sources/TriageBotCore/Classifier/LocalClassifier.swift`
- `Palace/Packages/PalaceTriageBot/Sources/TriageBotCore/KBMatchBadgePolicy.swift`
- `Palace/Packages/PalaceTriageBot/Sources/TriageBotUI/KBMatchCard.swift`
- `Palace/Packages/PalaceTriageBot/Tests/TriageBotCoreTests/` (4 new files)
- `docs/architecture/triage-bot-v1-as-built.md`
