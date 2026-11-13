"""`pbxproj_add_swift.rb` must never write a path only one machine can resolve.

The script resolved every file argument against its own checkout, with no way
to say otherwise, while `--project` accepted a path anywhere. Run from one
worktree against another with absolute paths, the relative path it computed
began `../<other-worktree>`, and each component of that became a PBXGroup — so
the project carried a group whose `path` was a worktree directory name. The
build worked on the machine that ran it and CI reported "Build input file cannot
be found" for a file the commit plainly contained.

`--repo-root` fixes the case that happened. The group-shape assertions below are
the part that holds whatever the root resolved to: a group this script creates
carries one bare directory name, never a separator and never `..`.
"""

import os
import shutil
import subprocess
import textwrap

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.dirname(HERE)
TOOL = os.path.join(SCRIPTS, "pbxproj_add_swift.rb")

PROD_TARGETS = ("Palace", "Palace-noDRM")

# Building the fixture project needs the same gem the tool under test needs, so
# this adds no dependency. It is asserted rather than skipped: a skip here is
# indistinguishable from a pass, and this suite is the only automated coverage
# the tool has.
MAKE_FIXTURE = textwrap.dedent(
    """
    require 'fileutils'
    require 'xcodeproj'
    root = ARGV[0]
    FileUtils.mkdir_p(File.join(root, 'Palace', 'SignInLogic'))
    FileUtils.mkdir_p(File.join(root, 'PalaceTests'))
    proj = Xcodeproj::Project.new(File.join(root, 'Palace.xcodeproj'))
    proj.new_target(:application, 'Palace', :ios, '17.0')
    proj.new_target(:application, 'Palace-noDRM', :ios, '17.0')
    proj.new_target(:unit_test_bundle, 'PalaceTests', :ios, '17.0')
    proj.save
    """
)

# Prints one line per group as `<path>\t<name>`, so the assertions read the
# parsed object graph rather than guessing at pbxproj block boundaries.
DUMP_GROUPS = textwrap.dedent(
    """
    require 'xcodeproj'
    proj = Xcodeproj::Project.open(ARGV[0])
    proj.objects.each do |o|
      next unless o.is_a?(Xcodeproj::Project::Object::PBXGroup)
      puts "#{o.path}\\t#{o.name}"
    end
    """
)

# Prints one line per `<target>\t<group chain>/<file>`. `hierarchy_path` is
# rooted at the main group and so carries a leading separator; stripping it
# leaves the repo-relative path the tool was asked to add.
DUMP_SOURCES = textwrap.dedent(
    """
    require 'xcodeproj'
    proj = Xcodeproj::Project.open(ARGV[0])
    proj.targets.each do |t|
      t.source_build_phase.files.each do |bf|
        ref = bf.file_ref
        next if ref.nil?
        puts "#{t.name}\\t#{ref.hierarchy_path.to_s.sub(%r{\\A/}, '')}"
      end
    end
    """
)


def _require_ruby():
    if shutil.which("ruby") is None:
        pytest.fail("ruby is not on PATH; pbxproj_add_swift.rb cannot be tested")
    probe = subprocess.run(["ruby", "-e", "require 'xcodeproj'"],
                           capture_output=True, text=True)
    if probe.returncode != 0:
        pytest.fail(
            "the xcodeproj gem is missing, so pbxproj_add_swift.rb cannot be "
            "tested. Install it with: gem install xcodeproj\n" + probe.stderr
        )


def _ruby(script: str, *args: str, cwd: str | None = None):
    return subprocess.run(["ruby", "-e", script, *args],
                          capture_output=True, text=True, cwd=cwd)


def make_checkout(path) -> str:
    """A throwaway checkout: a Palace.xcodeproj plus a copy of the tool."""
    _require_ruby()
    path.mkdir(parents=True, exist_ok=True)
    made = _ruby(MAKE_FIXTURE, str(path))
    assert made.returncode == 0, made.stderr
    scripts = path / "scripts"
    scripts.mkdir()
    # Copied in so the script's own notion of its checkout is this fixture,
    # which is the whole subject of the test.
    shutil.copy(TOOL, scripts / "pbxproj_add_swift.rb")
    return str(path)


def run_tool(checkout: str, *args: str):
    tool = os.path.join(checkout, "scripts", "pbxproj_add_swift.rb")
    assert os.path.isfile(tool), f"tool not copied into fixture: {tool}"
    return subprocess.run(["ruby", tool, *args], capture_output=True, text=True)


def project_of(checkout: str) -> str:
    return os.path.join(checkout, "Palace.xcodeproj")


def group_paths(checkout: str) -> list[str]:
    out = _ruby(DUMP_GROUPS, project_of(checkout))
    assert out.returncode == 0, out.stderr
    rows = [line.split("\t") for line in out.stdout.splitlines() if line.strip()]
    return [path for path, _name in rows if path]


def sources_of(checkout: str) -> dict[str, list[str]]:
    out = _ruby(DUMP_SOURCES, project_of(checkout))
    assert out.returncode == 0, out.stderr
    by_target: dict[str, list[str]] = {}
    for line in out.stdout.splitlines():
        if not line.strip():
            continue
        target, path = line.split("\t", 1)
        by_target.setdefault(target, []).append(path)
    return by_target


def assert_groups_are_bare_components(checkout: str):
    """The output property: a group's path is one bare directory name.

    Independent of how the root resolved, so it covers invocations nobody
    thought to write a case for.
    """
    for path in group_paths(checkout):
        assert "/" not in path, f"group path has a separator: {path!r}"
        assert ".." not in path.split("/"), f"group path escapes the root: {path!r}"
        assert not path.startswith("/"), f"group path is absolute: {path!r}"


def assert_no_machine_paths(checkout: str):
    with open(os.path.join(project_of(checkout), "project.pbxproj"),
              encoding="utf-8") as fh:
        text = fh.read()
    assert checkout not in text, "the project records its own absolute location"
    assert "/Users/" not in text
    assert os.path.basename(checkout) not in text, (
        "the project records the checkout's directory name, which is the "
        "worktree-name group this fix is about"
    )


def write_source(checkout: str, rel: str, body: str = "struct Fixture {}\n") -> str:
    full = os.path.join(checkout, rel)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    with open(full, "w", encoding="utf-8") as fh:
        fh.write(body)
    return full


@pytest.fixture
def checkout(tmp_path):
    return make_checkout(tmp_path / "ios-core")


@pytest.fixture
def sibling(tmp_path):
    return make_checkout(tmp_path / "sibling-worktree")


def test_file_in_the_default_root_is_added_to_both_production_targets(checkout):
    """The invocation contributors already use must behave as it did."""
    write_source(checkout, "Palace/SignInLogic/Local.swift")

    r = run_tool(checkout, "--verbose", "Palace/SignInLogic/Local.swift")

    assert r.returncode == 0, r.stderr
    sources = sources_of(checkout)
    for target in PROD_TARGETS:
        assert "Palace/SignInLogic/Local.swift" in sources[target]
    assert "SignInLogic" in group_paths(checkout)
    assert_groups_are_bare_components(checkout)
    assert_no_machine_paths(checkout)


def test_sibling_checkout_with_repo_root_groups_relative_to_that_root(checkout, sibling):
    """Run from one checkout against another, with the root stated.

    The group chain must come from the sibling's layout. Before `--repo-root`
    there was no way to say this, and the inferred group began `..`.
    """
    write_source(sibling, "Palace/SignInLogic/Remote.swift")

    r = run_tool(
        checkout,
        "--repo-root", sibling,
        "--project", project_of(sibling),
        "--verbose",
        os.path.join(sibling, "Palace", "SignInLogic", "Remote.swift"),
    )

    assert r.returncode == 0, r.stderr
    sources = sources_of(sibling)
    for target in PROD_TARGETS:
        assert "Palace/SignInLogic/Remote.swift" in sources[target]
    assert_groups_are_bare_components(sibling)
    assert_no_machine_paths(sibling)
    # The checkout the script lives in must be untouched.
    assert "Remote.swift" not in str(sources_of(checkout))


def test_project_in_a_sibling_checkout_derives_the_root_from_the_project(checkout, sibling):
    """`--project` alone is enough: a project sits at its checkout's root."""
    write_source(sibling, "Palace/SignInLogic/Derived.swift")

    r = run_tool(
        checkout,
        "--project", project_of(sibling),
        "--verbose",
        os.path.join(sibling, "Palace", "SignInLogic", "Derived.swift"),
    )

    assert r.returncode == 0, r.stderr
    assert f"repo root {sibling}" in r.stdout
    for target in PROD_TARGETS:
        assert "Palace/SignInLogic/Derived.swift" in sources_of(sibling)[target]
    assert_groups_are_bare_components(sibling)
    assert_no_machine_paths(sibling)


def test_explicit_repo_root_overrides_the_project_derived_one(checkout, sibling):
    """The flag stays an override, for a project not at its checkout's root."""
    write_source(checkout, "Palace/SignInLogic/Override.swift")

    r = run_tool(
        checkout,
        "--repo-root", checkout,
        "--project", project_of(sibling),
        "--dry-run", "--verbose",
        "Palace/SignInLogic/Override.swift",
    )

    assert r.returncode == 0, r.stderr
    assert f"repo root {checkout}" in r.stdout
    assert "Palace/SignInLogic/Override.swift" in r.stdout


def test_file_outside_the_root_without_repo_root_is_refused(checkout, sibling):
    """The expensive case: refuse, and name the flag that fixes it."""
    source = write_source(sibling, "Palace/SignInLogic/Escaped.swift")
    before = open(os.path.join(project_of(checkout), "project.pbxproj"),
                  encoding="utf-8").read()

    r = run_tool(checkout, source)

    assert r.returncode == 1, r.stdout
    assert "--repo-root" in r.stderr
    assert "Escaped.swift" in r.stderr
    assert checkout in r.stderr, "the refusal must name the root it used"
    after = open(os.path.join(project_of(checkout), "project.pbxproj"),
                 encoding="utf-8").read()
    assert after == before, "a refused run must not write the project"
    assert_groups_are_bare_components(checkout)


@pytest.mark.parametrize("group", ["../elsewhere/Palace", "/tmp/Palace", "Palace//X"])
def test_group_that_is_not_relative_to_the_root_is_refused(checkout, group):
    """`--group` is caller-supplied and gets the same guarantee."""
    write_source(checkout, "Palace/SignInLogic/Grouped.swift")

    r = run_tool(checkout, "--group", group, "Palace/SignInLogic/Grouped.swift")

    assert r.returncode == 1, r.stdout
    assert "--repo-root" in r.stderr
    assert_groups_are_bare_components(checkout)


def test_no_invocation_produces_a_group_with_a_separator_or_parent_segment(checkout, sibling):
    """Sweep the shapes callers use and assert the property over all of them.

    A property of the OUTPUT, so it holds for invocations no case above names.
    """
    write_source(checkout, "Palace/SignInLogic/Relative.swift")
    write_source(checkout, "Palace/Book/Absolute.swift")
    write_source(checkout, "PalaceTests/ThingTests.swift")
    write_source(checkout, "Palace/Deep/Nested/Chain.swift")
    write_source(sibling, "Palace/SignInLogic/Sibling.swift")

    invocations = [
        (checkout, ["Palace/SignInLogic/Relative.swift"]),
        (checkout, [os.path.join(checkout, "Palace", "Book", "Absolute.swift")]),
        (checkout, ["PalaceTests/ThingTests.swift"]),
        (checkout, ["--group", "Palace/Deep/Nested",
                    "Palace/Deep/Nested/Chain.swift"]),
        (sibling, ["--repo-root", sibling, "--project", project_of(sibling),
                   os.path.join(sibling, "Palace", "SignInLogic", "Sibling.swift")]),
    ]
    for target_checkout, args in invocations:
        r = run_tool(checkout, *args)
        assert r.returncode == 0, (args, r.stdout, r.stderr)
        assert_groups_are_bare_components(target_checkout)
        assert_no_machine_paths(target_checkout)
