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
