## Summary for JIRA
_(paste this into the ticket / release notes; see [.github/COMMIT_AND_PR_FOR_JIRA.md](.github/COMMIT_AND_PR_FOR_JIRA.md))_
- **JIRA:**
- **Root cause:**
- **Solution:**
- **How to verify:**

## What changed
<!-- Short description of the change. -->

## Why
<!-- Business / user reason. Notion link if applicable. -->

## Verification
- [ ] Tests added (TDD — written before the fix/feature)
- [ ] `scripts/verify-pr.sh --quick` passed locally
- [ ] For changed Swift files, mutation testing run via `scripts/palace_mutate.py` (see [TESTING.md](./TESTING.md))
- [ ] Before/after screenshots attached for UI changes
- [ ] Both `Palace` and `Palace-noDRM` targets build (if cross-cutting)
- [ ] Tested on iOS 16 minimum target (if UI/runtime change)

## Internal-only checklist (maintainers)
<!-- Outside contributors: leave this section blank. -->
- [ ] ForgeOS changeset id linked:
- [ ] All ForgeOS gates promoted (`forge_release_check` returns `can_release: true`)

## Target branch
- [ ] PR targets `develop` (not `main`)

## Build for QA
- [ ] Bumped Palace build number? _(only if QA needs a new TestFlight)_
