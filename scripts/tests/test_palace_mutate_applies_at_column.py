"""A mutation must be written at the column it was discovered at.

`guard a > 0, b > 0` yields two mutants of `>` -> `>=`. Applied by
first-occurrence replacement they write the SAME file, so the second operator is
never actually mutated: one mutant is compiled twice and the other is graded
without having been tested. Seen 2026-10-18 on a mutant an existing test killed
by hand while the harness reported it survived.
"""
import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SPEC = importlib.util.spec_from_file_location(
    "palace_mutate", os.path.join(HERE, "..", "palace_mutate.py"))
pm = importlib.util.module_from_spec(SPEC)
sys.modules["palace_mutate"] = pm
SPEC.loader.exec_module(pm)

LINE = "        guard byteCount > 0, bytesPerSecond > 0 else { return 0 }\n"


def _mutants_for(line: str):
    """Both `>` -> `>=` mutants the discovery step finds on one line."""
    return [m for m in pm.discover_mutations(line)
            if m.original == ">" and m.mutated == ">="]


def _write(tmp_path, text):
    p = tmp_path / "Subject.swift"
    p.write_text(text)
    return str(p)


def test_each_mutant_on_one_line_writes_a_distinct_file(tmp_path):
    mutants = _mutants_for(LINE)
    assert len(mutants) == 2, "fixture must yield two same-operator mutants"
    written = []
    for m in mutants:
        path = _write(tmp_path, LINE)
        pm.apply_mutation(path, m)
        written.append(open(path).read())
    assert written[0] != written[1], (
        "two mutants on one line wrote identical files, so one was never applied")


def test_the_second_operator_is_the_one_mutated(tmp_path):
    """The later mutant must change `bytesPerSecond`, not `byteCount` again."""
    second = sorted(_mutants_for(LINE), key=lambda m: m.col)[1]
    path = _write(tmp_path, LINE)
    pm.apply_mutation(path, second)
    got = open(path).read()
    assert "bytesPerSecond >= 0" in got, got
    assert "byteCount > 0" in got, "the first operator must be left alone"


def test_a_mutation_that_cannot_be_applied_raises(tmp_path):
    """A no-op write must fail loudly, never be graded as a verdict."""
    mutants = _mutants_for(LINE)
    path = _write(tmp_path, "        guard somethingElse != nil else { return 0 }\n")
    try:
        pm.apply_mutation(path, mutants[0])
    except RuntimeError:
        return
    raise AssertionError("apply_mutation silently accepted a line it could not mutate")
