"""
test_lint_corpus_scan.py — pytest for scripts/lint-corpus-scan.swift.

The script is a reviewer tool, not a commit gate: it is wired into no hook and
no workflow, so nothing in the repo depends on its verdict. This suite exists
because a scan that reads prose as code, or reads nothing at all, prints a clean
census over a live defect.

Asserts both directions, per the CLAUDE.md gate rule:
  (a) an unguarded site       -> exit 1, the file:line named
  (b) the same site, guarded  -> exit 0, nothing reported
plus the shapes that distinguish a lexer from a grep (prose, trailing comments,
block comments, multiline string bodies, raw strings), the empty-corpus refusal,
the --expect-files pin, and lint mode.

Prior art: no other script under scripts/ reads Swift source through a lexer, so
this is not a second path to an existing one (prior-art-checked).

The behavioural cases drive the real script, so they need a Swift toolchain.
There is none on the ubuntu runner that hosts `pytest scripts/tests/`, so they
skip there and run on any machine with the Command Line Tools installed — which
is every machine that can build this project. A skip reads like a pass, so the
reason below names exactly what did not run.
"""

from __future__ import annotations

import json
import shutil
import subprocess
from pathlib import Path

import pytest

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_SCRIPT = _REPO_ROOT / "scripts" / "lint-corpus-scan.swift"

_SWIFT = shutil.which("swift")
_needs_swift = pytest.mark.skipif(
    _SWIFT is None,
    reason=(
        "no `swift` on PATH, so the behavioural suite for lint-corpus-scan.swift "
        "(planted violation, guarded pass, lexing, empty-corpus refusal) did not run "
        "here. Its enforcer is scripts/pre-push-test-gate.sh, which runs this whole "
        "suite on every push whose diff touches scripts/ — and the tool under test "
        "is scripts/lint-corpus-scan.swift, so a change to it always does. That gate "
        "runs on a developer machine with a toolchain; CI installs none, because an "
        "install per run buys nothing the push gate has not already proved."
    ),
)


def _run(*args: str) -> subprocess.CompletedProcess:
    assert _SWIFT is not None
    return subprocess.run(
        [_SWIFT, str(_SCRIPT), *args],
        cwd=str(_REPO_ROOT),
        capture_output=True,
        text=True,
        timeout=300,
    )


def _tree(tmp_path: Path, files: dict[str, str]) -> str:
    root = tmp_path / "Corpus"
    root.mkdir(parents=True, exist_ok=True)
    for name, body in files.items():
        (root / name).write_text(body, encoding="utf-8")
    return str(root)


# A function whose only announce site has no guard above it anywhere.
_UNGUARDED = """\
import Foundation

final class Handler {
    func fulfill() {
        delegate?.announce(for: book)
    }
}
"""

# The same site with the guard restored.
_GUARDED = """\
import Foundation

final class Handler {
    func fulfill() {
        guard mayStore(book) else { return }
        delegate?.announce(for: book)
    }
}
"""


# ----------------------------------------------------------------- integrity

def test_the_script_is_committed_executable_and_self_describing():
    """Runs with no toolchain, so a Swift-less runner still checks the shape."""
    assert _SCRIPT.is_file(), f"{_SCRIPT} is missing"
    source = _SCRIPT.read_text(encoding="utf-8")
    assert source.startswith("#!/usr/bin/env swift"), "the shebang is how it runs unaided"
    assert _SCRIPT.stat().st_mode & 0o111, "the executable bit is part of the interface"
    # A caller reading the exit codes out of --help must find all three there.
    for line in ("0  ran", "1  findings", "2  usage error"):
        assert line in source, f"--help must document exit code line {line!r}"


# ------------------------------------------------------------------ self-test

@_needs_swift
def test_self_test_passes_on_the_committed_lexer():
    r = _run("--self-test")
    assert r.returncode == 0, r.stdout + r.stderr
    assert "all cases pass" in r.stdout


@_needs_swift
def test_self_test_fails_when_the_lexer_stops_stripping_line_comments(tmp_path):
    """Green is evidence only if red was reachable.

    Neutering the line-comment arm must redden the self-test; otherwise the
    self-test is decoration and the census it blesses carries no weight.
    """
    needle = 'if chars[i + 1] == "/" { break }'
    original = _SCRIPT.read_text(encoding="utf-8")
    assert needle in original, "the line-comment arm moved; update this mutation"
    mutated = tmp_path / "mutated.swift"
    mutated.write_text(
        original.replace(needle, 'if chars[i + 1] == "/" { i += 1; continue }'),
        encoding="utf-8",
    )
    r = subprocess.run([_SWIFT, str(mutated), "--self-test"],
                       capture_output=True, text=True, timeout=300)
    assert r.returncode == 1, "a lexer that keeps comments must fail its own self-test"
    assert "self-test FAILED" in r.stdout


# -------------------------------------------------------- census, both ways

@_needs_swift
def test_an_unguarded_site_is_reported_and_exits_nonzero(tmp_path):
    root = _tree(tmp_path, {"Handler.swift": _UNGUARDED})
    r = _run("--match", "announce(for:", "--guarded-by", "mayStore", "--root", root)
    assert r.returncode == 1, r.stdout + r.stderr
    assert "Handler.swift:5:" in r.stdout, r.stdout


@_needs_swift
def test_the_same_site_with_its_guard_restored_is_clean(tmp_path):
    root = _tree(tmp_path, {"Handler.swift": _GUARDED})
    r = _run("--match", "announce(for:", "--guarded-by", "mayStore", "--root", root)
    assert r.returncode == 0, r.stdout + r.stderr
    assert "Handler.swift:" not in r.stdout, r.stdout


@_needs_swift
def test_a_guard_in_a_sibling_function_does_not_cover_this_one(tmp_path):
    root = _tree(tmp_path, {"Two.swift": """\
final class Two {
    func guarded() {
        guard mayStore(book) else { return }
        delegate?.announce(for: book)
    }

    func unguarded() {
        delegate?.announce(for: book)
    }
}
"""})
    r = _run("--match", "announce(for:", "--guarded-by", "mayStore", "--root", root)
    assert r.returncode == 1
    assert "Two.swift:8:" in r.stdout, r.stdout
    assert "Two.swift:4:" not in r.stdout, "the guarded site must not be reported"


# -------------------------------------------------------- prose is not code

@pytest.mark.parametrize("prose", [
    "    // mayStore is asked on the other path\n",
    "    /* why:\n       mayStore covers this\n     */\n",
    '    Log.info("mayStore was asked")\n',
    '    let r = #"mayStore"#\n',
])
@_needs_swift
def test_prose_naming_the_guard_does_not_satisfy_it(tmp_path, prose):
    body = ("final class P {\n    func f() {\n"
            + prose
            + "        delegate?.announce(for: book)\n    }\n}\n")
    root = _tree(tmp_path, {"Prose.swift": body})
    r = _run("--match", "announce(for:", "--guarded-by", "mayStore", "--root", root)
    assert r.returncode == 1, f"prose satisfied the guard: {prose!r}\n{r.stdout}"


@_needs_swift
def test_a_brace_inside_a_multiline_string_does_not_pull_in_a_sibling_guard(tmp_path):
    root = _tree(tmp_path, {"Css.swift": '''\
final class C {
    func f() {
        if streaming {
            let css = """
            .cls { color: red;
            """
            guard mayStore(book) else { return }
            delegate?.announce(for: book)
        }
        if other {
            delegate?.announce(for: book)
        }
    }
}
'''})
    r = _run("--match", "announce(for:", "--guarded-by", "mayStore", "--root", root)
    assert r.returncode == 1
    assert "Css.swift:11:" in r.stdout, r.stdout
    assert "Css.swift:8:" not in r.stdout, "the guarded arm must stay guarded"


@_needs_swift
def test_raw_mode_matches_the_prose_the_lexer_hides(tmp_path):
    """--raw is how a reviewer sees what the lexing removed."""
    root = _tree(tmp_path, {"Only.swift": "// announce(for: book) in a comment\n"})
    lexed = _run("--match", "announce(for:", "--root", root, "--fail-on-match")
    assert lexed.returncode == 0, lexed.stdout
    raw = _run("--match", "announce(for:", "--root", root, "--raw", "--fail-on-match")
    assert raw.returncode == 1, raw.stdout


# ------------------------------------------------------- refusals and pins

@_needs_swift
def test_a_corpus_below_min_files_is_refused_rather_than_passed(tmp_path):
    root = _tree(tmp_path, {"One.swift": _GUARDED})
    r = _run("--match", "announce(for:", "--root", root, "--min-files", "100")
    assert r.returncode == 2, r.stdout + r.stderr
    assert "below --min-files" in r.stderr, r.stderr


@_needs_swift
def test_an_expect_files_mismatch_fails_even_when_every_site_is_guarded(tmp_path):
    root = _tree(tmp_path, {"Handler.swift": _GUARDED})
    ok = _run("--match", "announce(for:", "--root", root, "--expect-files", "Handler.swift")
    assert ok.returncode == 0, ok.stdout
    moved = _run("--match", "announce(for:", "--root", root, "--expect-files", "Renamed.swift")
    assert moved.returncode == 1, moved.stdout
    assert "expected matches in exactly" in moved.stdout


@_needs_swift
def test_inventory_mode_lists_sites_without_calling_them_findings(tmp_path):
    root = _tree(tmp_path, {"Handler.swift": _UNGUARDED})
    r = _run("--match", "announce(for:", "--root", root)
    assert r.returncode == 0, "a census is not a verdict"
    assert "Handler.swift:5:" in r.stdout


@_needs_swift
def test_lint_mode_fails_on_any_match(tmp_path):
    root = _tree(tmp_path, {"Sync.swift": "func f() {\n    DispatchQueue.main.sync { x() }\n}\n"})
    hit = _run("--match-regex", r"DispatchQueue\.main\.sync", "--root", root, "--fail-on-match")
    assert hit.returncode == 1, hit.stdout
    clean = _run("--match-regex", r"DispatchQueue\.main\.async", "--root", root, "--fail-on-match")
    assert clean.returncode == 0, clean.stdout


@_needs_swift
def test_a_missing_predicate_and_a_missing_root_are_usage_errors(tmp_path):
    assert _run("--root", str(tmp_path)).returncode == 2
    assert _run("--match", "x", "--root", str(tmp_path / "nope")).returncode == 2
    assert _run("--match", "x", "--bogus-flag").returncode == 2


@_needs_swift
def test_json_output_carries_the_counts_and_the_sites(tmp_path):
    root = _tree(tmp_path, {"Handler.swift": _UNGUARDED})
    r = _run("--match", "announce(for:", "--guarded-by", "mayStore", "--root", root, "--json")
    assert r.returncode == 1
    payload = json.loads(r.stdout)
    assert payload["mode"] == "census"
    assert payload["matches"] == 1
    assert payload["reported"] == 1
    assert payload["filesWithMatches"] == ["Handler.swift"]
    assert payload["sites"][0]["line"] == 5


@_needs_swift
def test_the_ext_flag_replaces_the_default_rather_than_widening_it(tmp_path):
    root = _tree(tmp_path, {"A.swift": "announce(for: book)\n",
                            "B.m": "announce(for: book);\n"})
    swift_only = _run("--match", "announce(for:", "--root", root)
    assert "A.swift:1:" in swift_only.stdout, swift_only.stdout
    assert "B.m" not in swift_only.stdout, "the default extension list is swift only"
    objc_only = _run("--match", "announce(for:", "--root", root, "--ext", "m")
    assert "B.m:1:" in objc_only.stdout, objc_only.stdout
    assert "A.swift" not in objc_only.stdout, "--ext replaces the default, it does not widen it"
