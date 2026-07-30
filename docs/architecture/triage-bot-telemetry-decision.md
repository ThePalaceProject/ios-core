---
name: triage-bot-telemetry-decision
type: decision-record
status: pending-signoff
created: 2026-07-29
owners: [product, infrastructure, support]
description: Where the triage bot's usage telemetry should land, and the three metrics plus starting thresholds that let someone answer "is the bot helping?" with a number. Resolves open decision 4 of the shared-architecture proposal (PP-4885).
---

<!-- audit-verified: PP-4882/PP-4885 verified via Jira API 2026-07-29; event names and TelemetryParameterKey cases recomputed from TriageBotCore source 2026-07-29; open-decision-4 / section-7 references checked against triage-bot-shared-architecture-proposal.md on origin/docs/pp-4858-triage-bot-architecture -->

# Triage bot telemetry: destination and yardstick

The bot already reports what happens as patrons use it, and nothing on the other
end reads those events. This record resolves two things that gate a useful
rollout: where the events should land, and what a good result looks like, stated
as numbers agreed before the bot is turned on rather than after.

This is the iOS-facing resolution of open decision 4 in
`triage-bot-shared-architecture-proposal.md`, section 7. That section holds the
backend detail; this record holds the decision and the metric definitions. The
recommendation below is engineering's; the destination and the thresholds are a
product and infrastructure call, recorded in the Decision section.

## The fork

The events flow through a fixed twelve-key allow-list (`TelemetryParameterKey`),
never patron text, and in release builds they reach Firebase Analytics. Two
destinations are viable.

- Firebase. The events already arrive there. Readable in the console immediately,
  queryable through the BigQuery export, zero new infrastructure. Limitation: no
  Palace reporting warehouse reads Firebase, so this data stays in a Firebase or
  BigQuery silo and is not joined to the rest of Palace reporting.
- A Circulation Manager ingestion endpoint, modeled on the playtimes path, which
  plausibly reaches the existing reporting warehouse. This is the larger change:
  Circulation Manager code, a decision about whether telemetry carries patron
  auth, a permanence commitment, and an ETL owner that section 7 records as
  unverified.

## Recommendation

Use Firebase for this rollout, and treat the Circulation Manager endpoint as the
follow-on if the bot graduates past the pilot.

The reasoning: the argument for the whole shared-architecture effort is that we
learn from how iOS performs in the field first, then decide what to build. That
learning loop needs data now, not a new backend path first. Firebase already has
the data the moment the bot is enabled, at zero infrastructure cost, and the
three metrics below are answerable from it. Choosing the Circulation Manager path
first spends the rollout window building ingestion before a single number has
told us the bot is worth the larger investment. Warehouse integration is the
right destination once the feature has earned it; it is not the right gate on
finding out whether it has.

## The three questions, as metrics

Each maps to events the bot already emits. Names are the literal event strings in
`ConversationReducer`; keys are `TelemetryParameterKey` values.

### 1. How often does the bot resolve something without a ticket

Auto-resolution rate = sessions that reach a resolution without a ticket,
divided by sessions started.

- Denominator: `triage_chat_opened`.
- Resolved without a ticket: a session carrying `triage_guided_step_resolved`, or
  a `triage_kb_match` the patron did not escalate, with no
  `triage_ticket_submit_requested` and no `triage_ticket_submitted` in the same
  session.
- Escalated: `triage_ticket_submit_requested` or `triage_user_file_anyway`
  present.

This is the headline number for "is it helping." Sessioning is by device and
time window in the query layer, because the events do not carry a session id
today. If per-session accuracy proves too coarse, adding a session id is a
future allow-list key, not a redesign.

### 2. Which questions does it consistently fail to match

Miss signal per category = sessions where the patron chose a category and
described a problem but the bot produced no confident match, grouped by
`category`.

- Chose a category: `triage_category_chosen` (carries `category`).
- No confident match: no `triage_kb_match` in the session, or
  `triage_ai_fallback_invoked` fired, or a match with `candidate_count` zero.

Honest limit: the events deliberately carry no patron text, so telemetry answers
this at the category grain, not at the phrasing grain. The list of the actual
unmatched phrasings does not live in telemetry and must come from the support
inbox: the tickets the bot escalated are the corpus of what it could not answer.
The category miss rate says where to look; the escalated tickets say what to add
to the knowledge base. Both are needed, and neither substitutes for the other.

### 3. Where do patrons abandon a guided flow

Guided-flow abandonment = guided flows started that neither resolved nor
escalated, bucketed by the step reached.

- Started: `triage_guided_flow_started`.
- Progressed: `triage_guided_step_advanced` (carries `step_id`, `next_index`).
- Completed well: `triage_guided_step_resolved`, or an escalation after the flow.
- Abandoned: `triage_user_dismiss` or session end with neither resolution nor
  escalation. Bucket by the highest `next_index` reached to see which step loses
  people.

## Proposed starting thresholds

These are starting numbers to ratify, not decreed targets. They exist so the
rollout has a yardstick before it begins. The reviewing roles set the final
values in the Decision section.

- Auto-resolution rate: a proposed floor to ratify (starting proposal: at least
  a quarter of opened sessions resolve without a ticket within the first weeks of
  enablement). Below the floor, the corpus needs work before wider enablement.
- Category miss rate: a watch list rather than a single number. Any category
  whose miss rate is persistently the highest is the next corpus target.
- Guided-flow completion: a proposed floor to ratify, and any single step that
  loses a disproportionate share of patrons is a content fix.

## What is needed to produce a number

Nothing in the app. Events reach Firebase in release builds today. Producing the
numbers requires the destination decision below, then the queries above built
against the Firebase or BigQuery export, owned by whoever holds that console.
Before the bot is enabled there is no field data to read; these definitions and
queries are what turn the data into an answer the moment the flag is turned on.

## Decision

To be completed by the product and infrastructure roles. Resolves open decision 4.

- Reviewed by (roles):
- Date:
- Destination (Firebase for pilot / Circulation Manager endpoint / other):
- Ratified thresholds (auto-resolution floor, guided-flow completion floor,
  miss-rate watch policy):
- Query owner (who builds and holds the three metrics):
- Reference (ticket or meeting record):
