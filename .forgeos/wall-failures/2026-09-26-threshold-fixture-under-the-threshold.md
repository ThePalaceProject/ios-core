---
date: 2026-09-26
pr: "#TBD (arch/phase-a-rearm-gates)"
source: reviewer-block
reviewer_ids: []
changeset_id: ""
wall: TDD
walls: [TDD, mutation]
severity: high
wall_status: applied
applied_in: arch/phase-a-rearm-gates
detector_script: ""
detector_status: no-detector
no-detector: "The class is 'the fixture's magnitude does not reach the gate's threshold'. Detecting it statically requires knowing each test's intended threshold and the magnitude its fixture produces — both arbitrary expressions in arbitrary test code. The mechanical detector for this class already exists and is mutation testing: all four arms were found by killing a mutant and none was findable by reading. The enforceable rule is procedural (mutate before claiming an arm is covered), which palace_mutate.py and the per-gate mutant tables already carry."
name: threshold-fixture-under-the-threshold
type: incident
---

# A test for "X does not count toward a limit" that never reaches the limit

## What happened

A reviewer found a surviving mutant in `check-file-size-ceiling.sh`: deleting
`if (s ~ "^/?[*]") next` — the block-comment skip — left every test green. I
wrote `test_block_comment_bodies_do_not_count` to close it, ran the suite, saw
10 passed, and reported the mutant killed.

It was not. The fixture emitted a 502-line block comment above 100 code lines.
With the skip deleted the file counts as 602 lines — **under the 800 ceiling**.
The gate returned 0 either way. The test asserted `returncode == 0` and passed
against both the correct gate and the defective one.

Three more arms in the same diff had the same shape, all found the same way:

- `test_bare_mention_does_not_count_as_wired` put its mention on a `#` line.
  The comment strip, a *different* mechanism, already rejected it, so dropping
  the invocation anchor the test existed to protect changed nothing.
- `test_many_wired_packages_still_pass` padded the workflow with comment lines
  (stripped upstream, so no bytes left to buffer) and placed the wired steps
  *after* the padding, so the match landed once the upstream had already
  finished. It could not produce the SIGPIPE it was written to detect.
- `test_package_tests_are_out_of_scope` had no assertion separating "Tests
  excluded" from "all packages excluded", so a mutant excluding both passed.

Four inert arms out of thirteen, in tests written deliberately to be red-capable,
by an author who had just been shown a surviving mutant.

## The class

An assertion of the form *"input of kind K does not contribute to threshold T"*
can only fail when the fixture supplies **enough K to cross T** if it did
contribute. Below that magnitude the test passes for a reason unrelated to its
claim, and the docstring is the only place the intent exists.

The general form is broader than magnitude: **an arm is inert whenever some
other mechanism in the pipeline already produces the asserted outcome.** The
comment-strip case is not about size at all — it is a second guard masking the
first. Both are invisible to reading, because reading confirms the *intent*, and
the intent was correct in all four cases.

This is `green-is-evidence-only-if-red-was-possible` and
`a-vacuous-test-cannot-diagnose-itself`, recurring inside the PR whose entire
thesis is that a gate which cannot fail reports a pass. The thesis was right and
the tests for it were the instance.

## What it cost

Nothing shipped — the mutants caught all four before the re-review. What it cost
was a false claim already made: I told a reviewer the mutant was killed, on the
evidence of a green suite. That claim was wrong at the moment it was made.

## The rule

Never report a mutant killed on the evidence of a passing suite. Killing is a
**named test failing against the defective code**. Revert the fix, run the
suite, and require the specific test named in the docstring to be the one that
fails — "some test failed" is not a kill either, because a coincidental
`test_live_repo_passes` masked the SIGPIPE arm here until the dedicated fixture
was made able to fail on its own.

For threshold assertions specifically: size the fixture so the *wrong* answer
crosses the threshold, and state the margin in the failure message.
