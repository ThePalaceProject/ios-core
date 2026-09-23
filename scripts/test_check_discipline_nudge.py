#!/usr/bin/env python3
"""
test_check_discipline_nudge.py — self-verify check-discipline-nudge.py.

Asserts the advisory nudge: (1) always exits 0 (never blocks), (2) fires on a
fix commit lacking a root-cause line, (3) fires on a fix/feat source change with
no test, (4) stays silent when the body has a root-cause AND a test is present,
(5) stays silent for non-fix/feat (chore/docs) commits.
"""
import os
import subprocess
import sys
import tempfile

_SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "check-discipline-nudge.py")

_SRC_NO_TEST = "diff --git a/Palace/Foo.swift b/Palace/Foo.swift\n--- a/Palace/Foo.swift\n+++ b/Palace/Foo.swift\n@@\n+x\n"
_SRC_WITH_TEST = _SRC_NO_TEST + "diff --git a/PalaceTests/FooTests.swift b/PalaceTests/FooTests.swift\n--- a/PalaceTests/FooTests.swift\n+++ b/PalaceTests/FooTests.swift\n@@\n+t\n"


def _run(msg, diff):
    with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as mf:
        mf.write(msg)
        msgpath = mf.name
    try:
        p = subprocess.run([sys.executable, _SCRIPT, "--commit-msg", msgpath, "--diff", "-"],
                           input=diff, capture_output=True, text=True)
        return p.returncode, p.stderr
    finally:
        os.unlink(msgpath)


def main():
    fails = []

    rc, err = _run("fix: crash on open\n\nReworked the loader.", _SRC_NO_TEST)
    if rc != 0: fails.append("fix/no-root-cause should still exit 0")
    if "root-cause line" not in err: fails.append("fix/no-root-cause should nudge root-cause")
    if "0 test files" not in err: fails.append("fix/no-test should nudge test:source")

    rc, err = _run("fix: crash on open\n\nThe bug was that the cache tore because of a race; added a guard.", _SRC_WITH_TEST)
    if rc != 0: fails.append("fix/with-root-cause+test should exit 0")
    if err.strip(): fails.append("fix/with-root-cause+test should be silent, got: " + err.strip()[:80])

    rc, err = _run("chore: bump deps\n\nRoutine.", _SRC_NO_TEST)
    if rc != 0: fails.append("chore should exit 0")
    if err.strip(): fails.append("chore should be silent (not fix/feat), got: " + err.strip()[:80])

    rc, err = _run("feat: add rotor\n\nNew rotor.", _SRC_NO_TEST)
    if "0 test files" not in err: fails.append("feat/no-test should nudge test:source")

    if fails:
        print("FAIL: test_check_discipline_nudge.py:")
        for f in fails:
            print("  -", f)
        return 1
    print("PASS: test_check_discipline_nudge.py (advisory nudge, exit-0, 5 cases)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
