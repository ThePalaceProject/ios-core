# Triage bot: how remedies reach patrons

Status: implemented on `spike/triage-bot-keyword-strength-tiers`, pending review.
Supersedes nothing. Companion to the classifier comments in `LocalClassifier.swift`.

## The problem this solves

QA reported that the in-app triage bot answered nearly every message with "I
haven't seen exactly that before, let me file a ticket", and never showed
troubleshooting steps. That was accurate, and the cause was not the one it
looked like.

Guided troubleshooting steps exist only on `known_issue` entries, and those
entries required two distinct keyword match regions before the bot would offer
them. A patron writes one short sentence naming one symptom, so real messages
scored one region and escalated. The bot was frequently identifying the correct
entry and then discarding it.

Measured against 114 support tickets that postdate every catalog entry, the
shipped bot answered 13 and escalated 100 with no remedy offered at all. Against
that, 42 percent of real resolutions name an action the patron could have taken
themselves. The gap was not exotic. It was a handful of remedies that existed in
the catalog but were reachable only through an entry match that usually did not
happen.

## Three findings that shaped the design

**Keyword strength is the axis, not keyword count.** `symptom_keywords` mixed
evidence of very different quality in one flat list. KI-008 listed both "won't
download" (decisive) and "download" (meaningless alone) and the classifier could
only count them. The two-region floor was a blunt proxy for "do not trust weak
evidence", and it suppressed the decisive phrases along with the vague ones.
Splitting the list into strong evidence (sufficient alone) and corroborating
evidence (never sufficient) lets the gate ask the right question.

**Patron wording does not predict which remedy applies.** Grouping tickets by the
remedy support prescribed and mining for distinguishing patron language returns
noise. Four independent methods came up short on the same corpus: measured
keyword strength, extractive answer copy, discriminating phrase mining, and
on-device sentence embeddings. This is a property of the data, not a gap in
effort, and it is the single most important constraint on the design. Nothing in
this system may be, or resemble, a complaint-to-remedy classifier.

**Per-category priors do carry signal.** While individual complaints do not
predict a remedy, categories do. The clearest split is the class of tickets whose
resolution was "a fix exists or is coming", which the patron can act on only by
getting the build: 26 of 36 resolved audiobook tickets, and 0 of 44 resolved
sign-in tickets. That is what orders and filters the remedy ladders.

Counting that class needs care, and an earlier draft of this document had the
audiobook figure wrong. Its dominant phrasing is "known issue with certain
audiobooks; fixed in Palace v3.2.3" — which contains no form of the words
"update" or "wait", so a scan built from remedy names misses almost all of it
while a scan for "fix" sweeps in unrelated prose. The rate is only reproducible
by matching the resolution's shape, not its vocabulary, which is the same trap
as counting mentions instead of prescriptions.

## How a message becomes a response

A patron taps a category chip, which narrows scoring to that category, then
describes the problem. The classifier tokenises both the message and each
candidate entry's keywords, matches whole words only, and merges overlapping hits
into distinct regions so that an entry listing a phrase and its head noun scores
the concept once. Strong regions are worth a full unit and corroborating regions
half, saturating at three.

An entry is suggested only when it has at least one strong region, clears its own
threshold, and leads the runner-up. Otherwise the message escalates, and
escalation is where most patrons land.

Escalation is not a dead end. Three things happen there, in order of preference:

1. If an entry was recognised, the ticket carries its identity so support sees a
   scoped report rather than "a patron reports a problem". This holds on all
   three exits from a ladder: exhausting it, abandoning it, and declining it.
   The third was added late, after review found that declining a ladder filed the
   ladder's own id and dropped the recognition.
2. The patron is offered the category's remedy ladder, if one exists.
3. When the ladder is exhausted or the patron declines it, a question is asked
   before the ticket is filed. The entry's own question is used when recognition
   was strong; otherwise the category's catch-all, which presumes nothing.

## Remedy ladders

A ladder is a catalog entry of kind `generic_flow` whose steps carry remedy tags.
It claims nothing about what is wrong. It offers a short sequence of safe actions
and lets the patron eliminate them, which is the correct shape when classification
has no signal to work with.

Ladders reuse the existing guided-step engine rather than introducing new
machinery. Already-tried skipping, step advance, exhaustion, abandonment and
per-step telemetry all apply without modification, and no new conversation state
was added. Exactly one existing transition changed: an escalation that produced
no suggestion now offers the ladder before drafting a ticket. That includes
weakly-recognised escalations, not only wholly unrecognised ones — a weak match
scopes the ticket but does not answer the patron, so the ladder is still the
better thing to offer. It excludes `escalate_anyway` entries and patrons who said
they had tried everything. A catalog with no ladder for a category behaves
exactly as it did before.

### Rules a ladder must satisfy

Enforced by `CatalogValidator` at catalog load, not only in tests, because the
schema is designed to be server-supplied later. A rule that lives only in the test
suite is a rule the shipped app does not have. A ladder that breaks a rule is
dropped and the rest of the catalog survives.

- **Suppressed remedies per category.** Derived from resolution data using a
  pre-registered threshold rather than per-cell judgement: suppress only where a
  category has at least 15 resolved tickets and the remedy was prescribed in at
  most 3 percent of them. Categories below that count are unknown, not zero.
- **Destructive remedies never go first, and are always refusable.**
- **At most three rungs.** The quarter of patrons whose problem only staff can
  resolve pay the whole ladder as delay before reaching a human.

### Remedy cost tiers

The claim that a generic remedy is never wrong, only unhelpful, is false in this
app, and the design does not rely on it.

Signing out removes that library's downloaded content, and a patron who then
cannot sign back in, which describes a quarter of real tickets, has gone from an
app that misbehaves to books they cannot open. Reinstalling deletes every
download across every library, and given the Adobe activation history in PP-4951,
re-fulfilment afterwards is not guaranteed. Both are classified `destructive`.

Recommending an update is `free` but can still be wrong when the patron is
already current, so the catalog may declare `latest_known_app_version` and the
ladder skips that rung for anyone at or past it. Unknown values offer the rung: a
wasted step costs seconds, a withheld one may cost the fix.

## What the bot will not do

- Ask a patron to do something they already said they did. Messages are scanned
  for past-tense statements of having tried a remedy, and those steps are skipped
  with an acknowledgement so the omission does not read as steps going missing.
- Walk a patron through remedies after they said they had tried everything.
- Offer a ladder for an `escalate_anyway` entry, which encodes that no safe
  self-serve fix exists.
- Ask an entry's bug-specific question off weak evidence. Every such question in
  the catalog presumes its own bug, and asked off a lone generic word it reads as
  the bot inventing a problem.
- Adapt rung ordering in-app. Reproducibility is half of what consistency means
  for a support tool, and 204 tickets sliced six ways cannot support online
  learning.

## Sign-in has no ladder, deliberately

Both cheap remedies were suppressed for sign-in by evidence: support prescribed
"update the app" zero times in 41 resolved sign-in tickets, and "sign out and back
in" once. The remaining candidate rung asserted a mechanism nobody had measured,
and was tagged with a remedy it did not actually perform, which would have
polluted its own telemetry from the first day.

Copy review rejected it. Sign-in goes directly to the question that separates its
two largest real clusters: whether the card came from the library or was created
in the app. A test pins this, so a future sign-in ladder has to be argued for.

## Measuring this

Two rates, and they trade against each other. A change that moves only one has not
been evaluated.

**Capture** is how many messages with a real answer in the catalog receive it.
**Misroute** is how many receive the wrong entry's workaround, which is worse than
escalating because the patron acts on it.

The scored corpus in `Fixtures/MatchCorpus.json` slices cases by provenance, and
the slice determines what a score means:

- `mined` tickets are the ones the catalog was authored from. A high score here
  is memorisation and is an upper bound only.
- `held_out` tickets postdate the catalog. This is the honest generalisation
  measure, and it is reported rather than asserted, because gating it would create
  pressure to close gaps by writing keywords against it, spending the only
  unbiased signal available.
- `trap` cases are generic complaints that must escalate.
- `near_miss` cases contain a strong keyword but were resolved to a different
  cause. This slice exists because the trap slice cannot fail: it samples only
  inputs whose overlap is a weak word, and the partition decides what is weak, so
  a mis-partitioned strong keyword can never appear there. The near-miss slice
  found two real misroutes on its first run.

Resolution traces are persisted on all three terminal outcomes, including
resolved, which previously produced no record because success files no ticket.
Nothing reads that log yet. It is the precondition for replacing today's
per-category priors with measured rates, and the rule for doing so is
pre-registered so it cannot later be set by whoever wants a number to move:
re-rank at catalog review cadence only, only for rungs with at least 50 recorded
attempts, ranking on the Wilson lower bound of their resolution rate.

## Known limits

- Roughly 8 percent of real messages are under a dozen words. No keyword and no
  catalog reaches those; they are the permanent argument for asking one good
  question rather than guessing.
- The category chip is a hard filter. A decisive match in another category is
  discarded unseen, and because the filter runs before scoring, the conflict is
  not merely unresolved but undetectable. When no chip is tapped at all the
  classifier already scans the whole catalog, which is token-driven area
  identification and is the cheapest place to start improving this.
- A message asking two questions is answered with one entry or none.
- The per-category priors are era-bound. Audiobook's update-the-app rate reflects
  one broken release and will decay, which is why they live in catalog data and
  why trace persistence matters.
- On-device sentence embeddings were measured against keywords and performed
  worse, with no usable confidence threshold. Lemmatisation remains worth taking:
  it would let the catalog carry one spelling instead of hand-listing variants.
