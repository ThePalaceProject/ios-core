"""Tests for scripts/check-pr-hygiene.py."""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

_REPO = Path(__file__).resolve().parents[2]
_SCRIPT = _REPO / "scripts" / "check-pr-hygiene.py"
_TEMPLATE = _REPO / ".github" / "PULL_REQUEST_TEMPLATE.md"

CLEAN_TITLE = "PP-5202: honor show_title so a block message can stand alone"
CLEAN_BODY = """## What
Show the library's block message without the generic title when the
server sets `show_title: false`.

## Why
Patrons saw two contradictory headings on a blocked sign-in. PP-5202

## How verified
- ProblemDocumentTests asserts show_title false drops the title
- Signed in to a blocked test account on device

![screenshot](https://example.com/a.png)
"""


def run(tmp_path: Path, title: str, body: str, author: str | None = None):
    body_file = tmp_path / "body.md"
    body_file.write_text(body)
    cmd = [sys.executable, str(_SCRIPT), "--title", title, "--body-file", str(body_file)]
    if author:
        cmd += ["--author", author]
    return subprocess.run(cmd, capture_output=True, text=True, timeout=30)


def test_clean_title_and_body_pass(tmp_path):
    r = run(tmp_path, CLEAN_TITLE, CLEAN_BODY)
    assert r.returncode == 0, r.stdout


def test_filled_template_passes_because_its_comments_do_not_count(tmp_path):
    # The template's HTML comments are long; a PR that keeps them must not be
    # charged for them.
    template = _TEMPLATE.read_text()
    body = template.replace("-\n", "- FooTests asserts the fix\n")
    assert len(template) > 0
    r = run(tmp_path, CLEAN_TITLE, body)
    assert r.returncode == 0, r.stdout


def test_title_over_72_characters_fails(tmp_path):
    r = run(tmp_path, "x" * 73, CLEAN_BODY)
    assert r.returncode == 1
    assert "73 characters" in r.stdout


def test_title_of_exactly_72_characters_passes(tmp_path):
    r = run(tmp_path, "x" * 72, CLEAN_BODY)
    assert r.returncode == 0, r.stdout


@pytest.mark.parametrize("title", [
    "run the flag's consumer suites under ON (swarm_11522c07 B3)",
    "extract downloads package (wave 3b)",
    "add detector for Phase 3.5 class",
    "address review rev_742175c0 findings",
])
def test_title_with_internal_run_id_fails(tmp_path, title):
    r = run(tmp_path, title, CLEAN_BODY)
    assert r.returncode == 1
    assert "internal run identifier" in r.stdout


@pytest.mark.parametrize("footer", [
    "🤖 Generated with [Claude Code](https://claude.com/claude-code)",
    "Co-Authored-By: Claude Opus <noreply@anthropic.com>",
])
def test_ai_footer_fails(tmp_path, footer):
    r = run(tmp_path, CLEAN_TITLE, CLEAN_BODY + "\n" + footer + "\n")
    assert r.returncode == 1
    assert "banned text" in r.stdout


@pytest.mark.parametrize("token", [
    "heka verdict", "forge-review approved", "ForgeOS gates", "the swarm ran",
    "wall-failure logged", "SoD satisfied", "architect reviewer found",
    "qa_test", "blast_radius", "via rigorous-fix", "the intent file",
    "changeset cs_1", "attested-done", "verify-tiers", "simdrive session",
])
def test_harness_vocabulary_in_body_fails(tmp_path, token):
    r = run(tmp_path, CLEAN_TITLE, CLEAN_BODY + f"\nNote: {token}.\n")
    assert r.returncode == 1, token


def test_ordinary_words_near_banned_tokens_pass(tmp_path):
    # Near-misses: substrings and unrelated words that share letters.
    body = CLEAN_BODY + "\nRenders the waveform; the sod roof; SourceForge link; forget it.\n"
    r = run(tmp_path, CLEAN_TITLE, body)
    assert r.returncode == 0, r.stdout


def test_banned_token_inside_html_comment_is_ignored(tmp_path):
    body = "<!-- heka swarm ForgeOS -->\n" + CLEAN_BODY
    r = run(tmp_path, CLEAN_TITLE, body)
    assert r.returncode == 0, r.stdout


def test_body_over_limit_fails(tmp_path):
    body = CLEAN_BODY + "\n" + ("word " * 320)
    r = run(tmp_path, CLEAN_TITLE, body)
    assert r.returncode == 1
    assert "characters excluding images and comments" in r.stdout


def test_images_and_comments_do_not_count_toward_length(tmp_path):
    images = "\n".join(f"![shot {i}](https://example.com/{'a' * 80}{i}.png)" for i in range(30))
    imgs = "\n".join(f'<img width="300" src="https://example.com/{"b" * 80}{i}.png">' for i in range(10))
    comment = "<!-- " + ("c" * 3000) + " -->"
    r = run(tmp_path, CLEAN_TITLE, CLEAN_BODY + images + "\n" + imgs + "\n" + comment)
    assert r.returncode == 0, r.stdout


JIRA_REF = (
    "[PP-1234]: https://ebce-lyrasis.atlassian.net/browse/PP-1234"
    "?atlOrigin=eyJpIjoiNWRkNTljNzYxNjVmNDY3MDlhMDU5Y2ZhYzA5YTRkZjUiLCJwIjoiZ2l0aHViLWNvbS1KU1cifQ"
)


def _near_limit_body() -> str:
    # CLEAN_BODY padded to within 100 characters of the 1,500 limit, so any
    # appended reference line pushes it over if it is counted.
    filler = "word " * ((1400 - len(CLEAN_BODY.strip())) // 5)
    return CLEAN_BODY + "\n" + filler.rstrip() + "\n"


def test_jira_bot_link_reference_does_not_count_toward_length(tmp_path):
    body = _near_limit_body()
    assert len(body.strip()) + len(JIRA_REF) > 1500
    r = run(tmp_path, CLEAN_TITLE, body + "\n" + JIRA_REF + "\n")
    assert r.returncode == 0, r.stdout


def test_body_over_limit_with_jira_bot_reference_still_fails(tmp_path):
    body = CLEAN_BODY + "\n" + ("word " * 320) + "\n\n" + JIRA_REF + "\n"
    r = run(tmp_path, CLEAN_TITLE, body)
    assert r.returncode == 1
    assert "characters excluding images and comments" in r.stdout


def test_author_link_reference_without_atlorigin_still_counts(tmp_path):
    own_ref = "[notes]: https://example.com/" + "n" * 140
    r = run(tmp_path, CLEAN_TITLE, _near_limit_body() + "\n" + own_ref + "\n")
    assert r.returncode == 1
    assert "characters excluding images and comments" in r.stdout


def test_inline_jira_link_with_atlorigin_still_counts(tmp_path):
    # Only whole reference-definition lines are dropped; an inline link is
    # visible text and keeps counting.
    inline = "See [PP-1234](" + JIRA_REF.split(": ", 1)[1] + ") for details."
    r = run(tmp_path, CLEAN_TITLE, _near_limit_body() + "\n" + inline + "\n")
    assert r.returncode == 1


def test_inline_jira_link_in_short_body_passes(tmp_path):
    inline = "Tracked in [PP-1234](https://ebce-lyrasis.atlassian.net/browse/PP-1234)."
    r = run(tmp_path, CLEAN_TITLE, CLEAN_BODY + "\n" + inline + "\n")
    assert r.returncode == 0, r.stdout


def test_dependabot_is_exempt(tmp_path):
    r = run(tmp_path, "chore(deps): bump fastlane from 2.239.0 to 2.240.1 in /some/long/path",
            "x" * 5000, author="dependabot[bot]")
    assert r.returncode == 0


def test_reads_pull_request_event(tmp_path):
    event = tmp_path / "event.json"
    event.write_text(json.dumps({"pull_request": {
        "title": "x" * 80, "body": CLEAN_BODY, "user": {"login": "someone"}}}))
    r = subprocess.run([sys.executable, str(_SCRIPT), "--event", str(event)],
                       capture_output=True, text=True, timeout=30)
    assert r.returncode == 1
    assert "80 characters" in r.stdout


def test_event_with_null_body_is_checked_as_empty(tmp_path):
    event = tmp_path / "event.json"
    event.write_text(json.dumps({"pull_request": {
        "title": CLEAN_TITLE, "body": None, "user": {"login": "someone"}}}))
    r = subprocess.run([sys.executable, str(_SCRIPT), "--event", str(event)],
                       capture_output=True, text=True, timeout=30)
    assert r.returncode == 0, r.stdout


def test_non_pull_request_event_is_an_input_error(tmp_path):
    event = tmp_path / "event.json"
    event.write_text(json.dumps({"push": {}}))
    r = subprocess.run([sys.executable, str(_SCRIPT), "--event", str(event)],
                       capture_output=True, text=True, timeout=30)
    assert r.returncode == 2


def test_workflow_runs_the_check_on_edits_and_exempts_dependabot():
    import yaml
    wf = yaml.safe_load((_REPO / ".github" / "workflows" / "pr-hygiene.yml").read_text())
    on = wf.get("on", wf.get(True))
    types = on["pull_request"]["types"]
    assert {"opened", "edited", "synchronize"} <= set(types)
    job = next(iter(wf["jobs"].values()))
    assert "dependabot[bot]" in job.get("if", "")
    runs = " ".join(s.get("run", "") for s in job["steps"])
    assert "scripts/check-pr-hygiene.py" in runs


# --- Evidence section ---------------------------------------------------------

EVIDENCE = """
## Evidence
- Red first: ProblemDocumentTests.testShowTitleFalse_DropsTitle
- Mutation: killed 6, survived 0, errored 0 on changed lines
- Simulator: signed in to a blocked account; one heading shown
- Reviews: 2 independent reviews, approved at 1a2b3c4
- Known behavior kept: none
"""

PRODUCT_FILES = ["Palace/SignInLogic/ProblemDocument.swift", "PalaceTests/ProblemDocumentTests.swift"]
TOOLING_FILES = ["scripts/check-pr-hygiene.py", "docs/README.md", "CLAUDE.md"]

MARKER_DIFF = """diff --git a/PalaceTests/BorrowTests.swift b/PalaceTests/BorrowTests.swift
--- a/PalaceTests/BorrowTests.swift
+++ b/PalaceTests/BorrowTests.swift
@@ -10,2 +10,4 @@ final class BorrowTests: XCTestCase {
     func testCancel() {
+        // Known: PP-1234 an alert still shows after a cancelled borrow
+        ContractSnapshot.assert(log, named: "cancel")
     }
"""

CLEAN_DIFF = MARKER_DIFF.replace("// Known: PP-1234 an alert still shows after a cancelled borrow",
                                 "// The cancel path records no alert call.")


def run_ev(tmp_path: Path, body: str, files=None, diff: str | None = None, author=None):
    body_file = tmp_path / "body.md"
    body_file.write_text(body)
    cmd = [sys.executable, str(_SCRIPT), "--title", CLEAN_TITLE, "--body-file", str(body_file)]
    if files is not None:
        (tmp_path / "files.txt").write_text("\n".join(files) + "\n")
        cmd += ["--changed-files", str(tmp_path / "files.txt")]
    if diff is not None:
        (tmp_path / "pr.diff").write_text(diff)
        cmd += ["--diff-file", str(tmp_path / "pr.diff")]
    if author:
        cmd += ["--author", author]
    return subprocess.run(cmd, capture_output=True, text=True, timeout=30)


def test_product_change_without_evidence_section_fails(tmp_path):
    r = run_ev(tmp_path, CLEAN_BODY, PRODUCT_FILES)
    assert r.returncode == 1
    assert "no '## Evidence' section" in r.stdout


def test_product_change_with_complete_evidence_passes(tmp_path):
    r = run_ev(tmp_path, CLEAN_BODY + EVIDENCE, PRODUCT_FILES)
    assert r.returncode == 0, r.stdout


def test_tooling_only_change_without_evidence_passes(tmp_path):
    r = run_ev(tmp_path, CLEAN_BODY, TOOLING_FILES)
    assert r.returncode == 0, r.stdout


def test_tooling_only_change_with_template_placeholders_passes(tmp_path):
    # The empty template keys are optional when no product or test code changed.
    template = _TEMPLATE.read_text().replace("-\n", "- FooTests asserts the fix\n")
    r = run_ev(tmp_path, template, TOOLING_FILES)
    assert r.returncode == 0, r.stdout


def test_product_change_with_unfilled_template_evidence_fails(tmp_path):
    template = _TEMPLATE.read_text().replace("-\n", "- FooTests asserts the fix\n")
    r = run_ev(tmp_path, template, PRODUCT_FILES)
    assert r.returncode == 1
    assert "Evidence 'Red first:' is empty" in r.stdout


def test_dependabot_product_change_without_evidence_is_exempt(tmp_path):
    r = run_ev(tmp_path, CLEAN_BODY, PRODUCT_FILES, author="dependabot[bot]")
    assert r.returncode == 0, r.stdout


@pytest.mark.parametrize("key", ["Red first", "Mutation", "Simulator", "Reviews",
                                 "Known behavior kept"])
def test_product_change_missing_one_evidence_key_fails(tmp_path, key):
    evidence = "\n".join(ln for ln in EVIDENCE.splitlines() if f"{key}:" not in ln)
    r = run_ev(tmp_path, CLEAN_BODY + evidence, PRODUCT_FILES)
    assert r.returncode == 1
    assert f"missing the '{key}:' line" in r.stdout


@pytest.mark.parametrize("key", ["Red first", "Mutation", "Simulator"])
def test_skip_value_without_reason_fails(tmp_path, key):
    word = "not run" if key == "Mutation" else "not applicable"
    lines = [f"- {key}: {word}:" if ln.startswith(f"- {key}:") else ln for ln in EVIDENCE.splitlines()]
    r = run_ev(tmp_path, CLEAN_BODY + "\n".join(lines), PRODUCT_FILES)
    assert r.returncode == 1
    assert "needs a reason after it" in r.stdout


def test_skip_values_with_reasons_pass(tmp_path):
    evidence = """
## Evidence
- Red first: not applicable: copy change only
- Mutation: not run: no mutation tooling on this machine
- Simulator: not applicable: no visible change
- Reviews: none
- Known behavior kept: none
"""
    r = run_ev(tmp_path, CLEAN_BODY + evidence, PRODUCT_FILES)
    assert r.returncode == 0, r.stdout


@pytest.mark.parametrize("line,message", [
    ("- Mutation: all killed", "'Mutation:' should read"),
    ("- Reviews: approved", "'Reviews:' should read"),
    ("- Reviews: two approvals", "'Reviews:' should read"),
    ("- Mutation: 20/0/0", "'Mutation:' should read"),
    ("- Known behavior kept: the alert", "should list PP keys"),
])
def test_malformed_evidence_value_fails(tmp_path, line, message):
    key = line.split(":")[0]
    lines = [line if ln.startswith(key + ":") else ln for ln in EVIDENCE.splitlines()]
    r = run_ev(tmp_path, CLEAN_BODY + "\n".join(lines), PRODUCT_FILES)
    assert r.returncode == 1
    assert message in r.stdout


def test_evidence_over_600_characters_fails(tmp_path):
    evidence = EVIDENCE.replace("one heading shown", "one heading shown " + "x" * 500)
    r = run_ev(tmp_path, CLEAN_BODY + evidence, PRODUCT_FILES)
    assert r.returncode == 1
    assert "Evidence section is" in r.stdout


def test_evidence_does_not_count_toward_body_limit(tmp_path):
    body = _near_limit_body() + EVIDENCE
    assert len(countable(body)) > 1500
    r = run_ev(tmp_path, body, PRODUCT_FILES)
    assert r.returncode == 0, r.stdout


def test_section_after_evidence_still_counts_toward_body_limit(tmp_path):
    body = CLEAN_BODY + EVIDENCE + "\n## Not done\n" + ("word " * 320)
    r = run_ev(tmp_path, body, PRODUCT_FILES)
    assert r.returncode == 1
    assert "characters excluding images and comments" in r.stdout


def test_banned_vocabulary_in_evidence_fails(tmp_path):
    evidence = EVIDENCE.replace("2 independent reviews", "2 independent reviews (architect reviewer)")
    r = run_ev(tmp_path, CLEAN_BODY + evidence, PRODUCT_FILES)
    assert r.returncode == 1
    assert "reviewer role" in r.stdout


def test_added_known_marker_not_listed_fails(tmp_path):
    r = run_ev(tmp_path, CLEAN_BODY + EVIDENCE, PRODUCT_FILES, MARKER_DIFF)
    assert r.returncode == 1
    assert "Known markers for PP-1234" in r.stdout


def test_added_known_marker_listed_passes(tmp_path):
    evidence = EVIDENCE.replace("Known behavior kept: none", "Known behavior kept: PP-1234")
    r = run_ev(tmp_path, CLEAN_BODY + evidence, PRODUCT_FILES, MARKER_DIFF)
    assert r.returncode == 0, r.stdout


def test_clean_diff_without_markers_passes(tmp_path):
    r = run_ev(tmp_path, CLEAN_BODY + EVIDENCE, PRODUCT_FILES, CLEAN_DIFF)
    assert r.returncode == 0, r.stdout


def test_known_marker_in_a_doc_is_not_a_marker(tmp_path):
    diff = MARKER_DIFF.replace("PalaceTests/BorrowTests.swift", "CLAUDE.md")
    r = run_ev(tmp_path, CLEAN_BODY, None, diff)
    assert r.returncode == 0, r.stdout


def test_changed_files_come_from_the_diff_when_no_list_is_given(tmp_path):
    r = run_ev(tmp_path, CLEAN_BODY, None, CLEAN_DIFF)
    assert r.returncode == 1
    assert "no '## Evidence' section" in r.stdout


def test_event_mode_takes_changed_files(tmp_path):
    event = tmp_path / "event.json"
    event.write_text(json.dumps({"pull_request": {
        "title": CLEAN_TITLE, "body": CLEAN_BODY, "user": {"login": "someone"}}}))
    (tmp_path / "files.txt").write_text("\n".join(PRODUCT_FILES))
    r = subprocess.run([sys.executable, str(_SCRIPT), "--event", str(event),
                        "--changed-files", str(tmp_path / "files.txt")],
                       capture_output=True, text=True, timeout=30)
    assert r.returncode == 1
    assert "no '## Evidence' section" in r.stdout


def countable(body: str) -> str:
    import importlib.util
    spec = importlib.util.spec_from_file_location("cph", _SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.countable_body(body)


# --- Workflow wiring: run the step's script with a stub `gh` -------------------

def _hygiene_step():
    import yaml
    wf = yaml.safe_load((_REPO / ".github" / "workflows" / "pr-hygiene.yml").read_text())
    job = next(iter(wf["jobs"].values()))
    step = next(s for s in job["steps"] if "check-pr-hygiene.py" in s.get("run", ""))
    return wf, job, step


def _run_step(tmp_path: Path, body: str, files: list[str], diff: str, diff_fails=False):
    _, _, step = _hygiene_step()
    bindir = tmp_path / "bin"
    bindir.mkdir()
    (tmp_path / "files.txt").write_text("\n".join(files) + "\n")
    (tmp_path / "pr.diff.src").write_text(diff)
    gh = bindir / "gh"
    gh.write_text(f"""#!/usr/bin/env bash
case "$1 $2" in
  "api --paginate") cat "{tmp_path}/files.txt" ;;
  "pr diff") {"exit 1" if diff_fails else f'cat "{tmp_path}/pr.diff.src"'} ;;
  *) echo "unexpected gh call: $*" >&2; exit 9 ;;
esac
""")
    gh.chmod(0o755)
    event = tmp_path / "event.json"
    event.write_text(json.dumps({"pull_request": {
        "title": CLEAN_TITLE, "body": body, "user": {"login": "someone"}}}))
    runner_temp = tmp_path / "runner"
    runner_temp.mkdir()
    env = {"PATH": f"{bindir}:/usr/bin:/bin", "GITHUB_EVENT_PATH": str(event),
           "RUNNER_TEMP": str(runner_temp), "PR": "1", "REPO": "o/r", "GH_TOKEN": "x"}
    # The step runs with the repository root as its working directory.
    return subprocess.run(["bash", "-c", step["run"]], cwd=_REPO, env=env,
                          capture_output=True, text=True, timeout=60)


def test_workflow_grants_pull_request_read_and_checks_out_both_scripts():
    wf, job, _ = _hygiene_step()
    assert wf["permissions"].get("pull-requests") == "read"
    sparse = job["steps"][0]["with"]["sparse-checkout"]
    assert "scripts/check-pr-hygiene.py" in sparse
    assert "scripts/list-known-behaviors.py" in sparse


def test_workflow_step_fails_product_pr_without_evidence(tmp_path):
    r = _run_step(tmp_path, CLEAN_BODY, PRODUCT_FILES, CLEAN_DIFF)
    assert r.returncode == 1, r.stdout + r.stderr
    assert "no '## Evidence' section" in r.stdout


def test_workflow_step_passes_tooling_pr_without_evidence(tmp_path):
    r = _run_step(tmp_path, CLEAN_BODY, TOOLING_FILES, "")
    assert r.returncode == 0, r.stdout + r.stderr


def test_workflow_step_matches_markers_from_the_diff(tmp_path):
    r = _run_step(tmp_path, CLEAN_BODY + EVIDENCE, PRODUCT_FILES, MARKER_DIFF)
    assert r.returncode == 1, r.stdout + r.stderr
    assert "Known markers for PP-1234" in r.stdout


def test_workflow_step_passes_clean_product_pr(tmp_path):
    r = _run_step(tmp_path, CLEAN_BODY + EVIDENCE, PRODUCT_FILES, CLEAN_DIFF)
    assert r.returncode == 0, r.stdout + r.stderr


def test_workflow_step_still_checks_when_the_diff_is_refused(tmp_path):
    r = _run_step(tmp_path, CLEAN_BODY, PRODUCT_FILES, "", diff_fails=True)
    assert r.returncode == 1, r.stdout + r.stderr
    assert "::warning::gh pr diff failed" in r.stdout
    assert "no '## Evidence' section" in r.stdout


@pytest.mark.parametrize("value", ["none;", "none; ", "not run: .", "none"])
def test_none_without_reason_fails_for_a_run_key(tmp_path, value):
    lines = [f"- Simulator: {value}" if ln.startswith("- Simulator:") else ln
             for ln in EVIDENCE.splitlines()]
    r = run_ev(tmp_path, CLEAN_BODY + "\n".join(lines), PRODUCT_FILES)
    assert r.returncode == 1, value


# The first Evidence section written for a real PR (#1878), verbatim.
PR_1878_EVIDENCE = """
## Evidence
- Red first: the 58 snapshots were recorded on the old code (#1868) before the move.
- Mutation: `BorrowReducerCore` 20/0/0, `BorrowOperation` 1/0/0 (killed/survived/errored).
- Simulator: none; no patron-visible change.
- Reviews: 2 approvals on d8aad0d29.
- Known behavior kept: PP-5565 (alert on a cancelled borrow).
"""


def test_evidence_in_the_first_real_pr_passes(tmp_path):
    diff = MARKER_DIFF.replace("PP-1234", "PP-5565")
    r = run_ev(tmp_path, CLEAN_BODY + PR_1878_EVIDENCE, PRODUCT_FILES, diff)
    assert r.returncode == 0, r.stdout
