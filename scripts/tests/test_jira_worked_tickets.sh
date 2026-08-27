#!/usr/bin/env bash
# test_jira_worked_tickets.sh — covers `extract_worked_tickets` in
# scripts/jira-integration.sh.
#
# Why this exists: the post-commit hook used to comment on EVERY ticket a commit
# message mentioned. Commit bodies routinely name a ticket in order to say the
# change deliberately does NOT touch it — "that belongs to PP-5005" — and each
# such sentence posted a machine comment on someone else's ticket. PP-5005, a
# design story owned by another person, collected six of them from a branch
# whose whole point was to stay out of its way.
#
# The rule under test: a ticket is WORKED if the subject line names it, or a
# claiming trailer does. A mention anywhere else in the body is a reference.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/jira-integration.sh"
PASS=0
FAIL=0

expect_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  ok   — $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL — $label"
    echo "         expected: [$expected]"
    echo "         actual:   [$actual]"
    FAIL=$((FAIL + 1))
  fi
}

# Source only the function under test; the script's main() would try to talk to
# Jira.
FN_SRC=$(awk '/^extract_worked_tickets\(\) \{/,/^\}/' "$SCRIPT")
if [ -z "$FN_SRC" ]; then
  echo "FAIL — could not find extract_worked_tickets() in $SCRIPT"
  exit 1
fi
eval "$FN_SRC"

JIRA_PROJECT_KEY="PP"

# Collapse the newline-separated result so it is comparable in one line.
worked() {
  extract_worked_tickets "$1" | tr '\n' ' ' | sed 's/ *$//'
}

echo "extract_worked_tickets:"

expect_eq "subject ticket is worked" \
  "PP-5006" \
  "$(worked "feat(reader): prototype a chapter scrubber (PP-5006)")"

# The exact shape that caused the spam. This body is close to a real one: it
# names PP-5005 only to say the work stays out of it.
expect_eq "a ticket named in the body to EXCLUDE it is not worked" \
  "PP-5006" \
  "$(worked "redesign(reader): a rail at rest, a card in hand (PP-5006)

**Scope:** PP-5006 only. What the reader states AT REST, and how each figure is
labelled, is PP-5005's open design question and belongs to a designer.

**Deferred:** the at-rest readout is still the thing PP-5005 exists to fix.")"

expect_eq "'Related:' does not claim a ticket" \
  "PP-5006" \
  "$(worked "fix(reader): something (PP-5006)

Related: PP-5005")"

expect_eq "'Refs:' does not claim a ticket" \
  "PP-5006" \
  "$(worked "fix(reader): something (PP-5006)

Refs: PP-4988")"

# Trailers that DO claim, for a commit whose subject omits the key.
expect_eq "Fixes: trailer claims the ticket" \
  "PP-1234" \
  "$(worked "fix(net): stop the retry storm

Fixes: PP-1234")"

expect_eq "Closes: trailer claims the ticket" \
  "PP-1234" \
  "$(worked "fix(net): stop the retry storm

Closes: PP-1234")"

expect_eq "Ticket: trailer claims the ticket" \
  "PP-1234" \
  "$(worked "chore: tidy

Ticket: PP-1234")"

expect_eq "Tickets: trailer claims several" \
  "PP-1234 PP-5678" \
  "$(worked "chore: tidy

Tickets: PP-1234, PP-5678")"

expect_eq "trailer matching is case-insensitive" \
  "PP-1234" \
  "$(worked "chore: tidy

FIXES: PP-1234")"

expect_eq "a subject naming two tickets claims both" \
  "PP-1 PP-2" \
  "$(worked "fix: two at once (PP-1, PP-2)")"

expect_eq "the same ticket in subject and trailer is claimed once" \
  "PP-1234" \
  "$(worked "fix: thing (PP-1234)

Fixes: PP-1234")"

expect_eq "a body with no subject key and no trailer claims nothing" \
  "" \
  "$(worked "chore: unrelated tidy-up

While here, note that PP-5005 covers the readout.")"

# A trailer-shaped line that is really prose must not claim. This matters
# because commit bodies are written by humans mid-paragraph.
expect_eq "a mid-sentence 'fixes' is not a trailer" \
  "" \
  "$(worked "chore: unrelated tidy-up

This fixes: PP-5005 eventually, but not here.")"

echo
echo "regression guard:"

# The old behaviour must not creep back by the hook calling the wrong helper.
if grep -q "extract-worked-tickets" "$REPO_ROOT/scripts/jira-integration.sh"; then
  echo "  ok   — extract-worked-tickets is exposed as a subcommand"
  PASS=$((PASS + 1))
else
  echo "  FAIL — extract-worked-tickets subcommand is missing"
  FAIL=$((FAIL + 1))
fi

# Amend/rebase dedupe: the fingerprint must be both computed and recorded, or
# the next run cannot recognise the same change under a new SHA.
if grep -q "patch-id --stable" "$SCRIPT" && grep -q "change-id: \$patch_id" "$SCRIPT"; then
  echo "  ok   — link_commit fingerprints the change and records it"
  PASS=$((PASS + 1))
else
  echo "  FAIL — link_commit does not fingerprint the change (amends will re-post)"
  FAIL=$((FAIL + 1))
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
