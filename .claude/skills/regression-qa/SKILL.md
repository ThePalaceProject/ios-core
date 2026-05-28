---
name: regression-qa
description: Guide a QA tester through a manual release regression — setup, side-by-side testing, codebase-aware triage, report, and Jira tickets. No simdrive or maintainer-only tooling required. Use this when running a manual regression pass against a release candidate.
argument-hint: <ticket> [--baseline-version X.Y.Z] [--candidate-version X.Y.Z]
allowed-tools: Bash(*), Read, Write, Edit, Glob, Grep, Agent
# doc-lifecycle metadata (added by Module B sweep)
type: evolving
status: active
created: 2026-05-11
last_refresh: 2026-05-11
freshness_window: 365d
owners: [general]
---

# Palace iOS — QA Regression (manual)

You are guiding a QA tester through a release regression. **This skill is manual-first.** It does NOT require simdrive, MCP automation tools, Firebase service accounts, or any maintainer-only setup. Every command in this skill works from a fresh ios-core clone with Xcode + Jira access.

If the tester has simdrive set up and wants automated journey replay, redirect them to `/regression` instead.

## Tone

You're working with a tester, not a developer. Be explicit, ask one question at a time, and confirm before moving on. When you find something interesting in the code, explain it in plain language ("the borrow button waits for X, so this hang means Y didn't happen yet"). Don't dump file paths and line numbers without context.

## Arguments

Parse from `$ARGUMENTS`:
- `<ticket>` — parent Jira ticket (e.g., `PP-4200`). If missing, ask.
- `--baseline-version X.Y.Z` — version being compared against (e.g., `3.0.0`). Default: ask.
- `--candidate-version X.Y.Z` — version being tested (e.g., `3.1.0`). Default: ask.

## Phase 0 — Pre-flight (fail fast, don't waste her time)

Before any setup, verify her environment can complete the workflow. Run these checks **in parallel** and report a single status table:

```bash
# Xcode + iOS simulator runtime
xcodebuild -version 2>&1 | head -1

# Booted simulator (needed for the auto-sweep build step)
xcrun simctl list devices iPhone | awk '/Booted/ {print; exit}'

# Repo state
git -C "$(pwd)" rev-parse --abbrev-ref HEAD
git -C "$(pwd)" status --short

# Jira API access (optional — affects Phase 6)
test -n "$JIRA_EMAIL" -a -n "$JIRA_API_TOKEN" && echo "JIRA: configured" || \
  test -f .jira-config && echo "JIRA: .jira-config present" || echo "JIRA: not configured (Phase 6 will use --dry-run only)"
```

Tell her clearly:
- ✅ what's ready
- ⚠️ what's missing but optional (e.g., Jira creds → see "Jira API setup" appendix; can still finish with `--dry-run` markdown export)
- ❌ what blocks the workflow (no Xcode, no booted sim, dirty branch on the wrong commit)

For each ❌, give her the exact fix command. **Do not proceed to Phase 1 until she confirms ❌ items are resolved.**

If Jira shows ⚠️ "not configured", offer: *"Want me to walk you through setting up the Jira API token now? It takes ~2 minutes and means tickets get created automatically at the end. Or we can skip and you'll paste tickets into Jira manually."* If yes → jump to the "Jira API setup" appendix at the end of this skill, walk her through it, then come back. If no → continue to Phase 1.

Also confirm she has:
- The **baseline build** installed (on a device or sim) — version matches `--baseline-version`
- The **candidate build** installed somewhere she can compare side-by-side
- Test library credentials (ask her where she keeps them — don't assume a path)

## Phase 1 — Setup workspace

```bash
scripts/regression-report.sh setup \
  --ticket <TICKET> \
  --output-dir ~/Desktop/regression-<TICKET>
```

Confirm what was created and read `ENVIRONMENT.md` back to her. Ask her to fill in:
- The two builds (version, source — TestFlight build #, branch SHA, etc.)
- Devices/simulators she's testing on
- Which test libraries she'll use

After she edits, re-read `ENVIRONMENT.md` and confirm it's complete.

## Phase 2 — Side-by-side manual testing

This is the bulk of the work. Read `~/Desktop/regression-<TICKET>/TEST_MATRIX.md` and walk through it priority-by-priority.

### Read the matrix once, then walk it

The matrix has three tiers:
- **P0** (Authentication, Circulation) — mandatory every release.
- **P1** (Reading, Catalog) — mandatory every release.
- **P2** (UI, Downloads, Notifications, Performance, Platform) — sample based on what changed.

For P2, ask her: *"Which areas are relevant to the changes in this release?"* Only test the ones she selects. If she doesn't know, ask if you should look at the git log between baseline and candidate and suggest areas. Use:

```bash
git log --oneline <baseline-tag>..<candidate-branch> -- Palace/ | head -40
```

Map commits to matrix areas (e.g., commits touching `Palace/SignInLogic/` → A1–A8; `Palace/Reader2/` → E1–E1-Adobe; `Palace/Audiobooks/` → E3-* / E4).

### Per-area workflow

For each area you're testing:

1. **Tell her the test.** Read the row from the matrix verbatim — *"Area B1: Borrow a book from catalog. We need to test this against each distributor — Palace Bookshelf, A1QA Overdrive audiobook, A1QA LCP EPUB. Let's start with Palace Bookshelf."*

2. **Walk her through baseline first, then candidate.** *"On the baseline build, open Palace Bookshelf, find any title, tap Borrow. Tell me what you see — what does the button look like before, during, and after? Any sheets appear? Any errors?"*

3. **Listen for differences.** After she describes baseline, ask the same on candidate. Watch for:
   - Visual differences (button labels, layout, colors, missing nav titles)
   - Functional differences (different sheet, different errors, hangs)
   - Performance differences (slower, lag, freezes)
   - Anything she calls out as "weird"

4. **If she finds something:** go to Phase 3 (triage) before logging.

5. **If clean:** mark it tested in your running notes. Tell her *"Clean on B1 / Palace Bookshelf. Moving to B1 / A1QA Overdrive audiobook."*

6. **Track progress.** Every 5 areas, summarize: *"P0 progress: 6/9 auth done, 4/9 circulation done. About 30 minutes of P0 left."*

### Test-fixture matrix axes — don't skip variants

The matrix has rows like *"All 7 auth types"* or *"All 7 distributors"*. **Each variant is a separate test run.** A row that says "All 7" needs 7 distinct runs (one per auth type or distributor). The row in the test fixtures section maps each axis to a specific test library. Use those mappings — don't just test `basic` and call the auth row done.

If a variant can't be tested (e.g., Adobe activation not available, SAML library unreachable), **mark it explicitly in the report as a known gap with rationale**. Silent skipping = "we tested everything" turning into "why didn't we catch X?"

## Phase 3 — Triage helper (when she finds something)

This is where you earn your keep. When she reports a difference, **don't immediately tell her to log it as a finding.** First, help her understand what she's seeing.

### Step 1 — Confirm it's reproducible

*"Can you reproduce that on the candidate? Try once more, fresh. If it happens again, screenshot it. If it doesn't, let's note it as 'intermittent — investigating' and move on."*

### Step 2 — Search the codebase

Pick the right starting point based on what she's describing:

| What she sees | Start here |
|---|---|
| Sign-in form / auth error | `Palace/SignInLogic/` |
| Borrow / return / hold flow | `Palace/MyBooks/`, `Palace/Book/` |
| Catalog browsing / search / lanes | `Palace/Catalog/`, `Palace/CatalogUI/`, `Palace/CatalogDomain/` |
| Reader (EPUB) — pages, settings, nav bar | `Palace/Reader2/` |
| Reader (PDF) | `Palace/Reader3/` |
| Audiobook playback | `Palace/Audiobooks/` |
| Library list / settings | `Palace/Accounts/`, `Palace/AppInfrastructure/` |
| Hold / reservation | `Palace/Holds/` |
| Network error / 401 / sync | `Palace/Network/`, `TPPNetworkExecutor`, `TPPLastReadPositionSynchronizer` |
| Push / deep-link | `Palace/AppInfrastructure/`, `Palace/Notifications/` |
| Migration / fresh-install issue | `Palace/Migrations/` |

Use Grep/Glob to find the relevant code:

```bash
# Symbol search
git grep -n "BorrowButton" Palace/

# Recent changes in a file
git log --oneline -20 -- Palace/MyBooks/BookCellModel.swift

# Who touched this line / when (for the suspect line)
git blame -L <line>,+1 Palace/.../File.swift

# Look for a known bug ID (PP-XXXX) or finding ID (F-NNN) in commit history
git log --all --grep="PP-4081" --oneline
```

### Step 3 — Check whether the change is intentional

A "regression" in QA's eyes might be a deliberate UX change. Look for:

```bash
# What changed in this file between baseline and candidate?
git diff <baseline-tag>..<candidate-branch> -- Palace/.../File.swift

# What PRs landed in the relevant area?
git log <baseline-tag>..<candidate-branch> --oneline -- Palace/MyBooks/ | head -20
```

If a recent PR explicitly modified this behavior, classify the finding as `behavior-change` rather than `regression`. Tell her what the PR was for and ask: *"Was this intentional? Should we file it as a regression or note it as an intentional change?"*

### Step 4 — Find related Jira tickets / past findings

The matrix references findings by ID (F-001, F-012, etc.). If her observation matches the description of a known finding (e.g., "nav title missing from Account screen" matches F-001), tell her *"This looks like F-001 from PP-4020 — was previously fixed in PR #834. Worth verifying it's a fresh regression and not a revert."*

```bash
git log --all --grep="F-012" --oneline
git log --all --grep="F-081" --oneline
```

### Step 5 — Suggest reproduction steps

Based on the code path, write minimum repro steps for the CSV:

> **Steps:** Settings > Libraries > Add Library > A1QA Test Library > sign in with `01230000000237 / Lyrtest123` > tap Catalog > tap any title > tap Borrow > observe button state.

Specific is better than general. *"Borrow a book"* is useless; *"Borrow Cyber Risk on Palace Marketplace as A1QA basic-auth user"* tells the next person exactly what to do.

### Step 6 — Now log the finding

Help her write a CSV row. Use Read to confirm the next ID, then write the row. Required fields:

| Column | What to put |
|---|---|
| `ID` | F-NNN (next number) |
| `Title` | One sentence — what's wrong |
| `Area` | Matrix area (e.g., `B1`, `A1`, `E3-OD`) |
| `Test ID` | Sub-ID if applicable |
| `Classification` | `regression` / `pre-existing` / `behavior-change` (see quick reference) |
| `Severity` | `blocker` / `major` / `minor` / `cosmetic` |
| `Verified` | `false` initially. Ask: *"Can you verify this on a different device right now?"* If yes, set to `true`. |
| `Baseline Behavior` | What baseline does |
| `Candidate Behavior` | What candidate does |
| `Steps` | Repro from Step 5 |
| `Screenshot Baseline` | `F-NNN-baseline-<short>.png` |
| `Screenshot Candidate` | `F-NNN-candidate-<short>.png` |
| `Notes` | Code area, related PRs, anything else from triage |

Remind her to drop the screenshot pair into `~/Desktop/regression-<TICKET>/screenshots/` with the filenames you wrote into the CSV.

## Phase 4 — Finding review

After all areas are tested, summarize the findings:

```bash
# Read the CSV and produce a count by classification + severity
```

Show her:
- Total findings
- Count by `Classification` (regression, pre-existing, behavior-change, fixed, new-feature)
- Count by `Severity` (blocker, major, minor, cosmetic)
- How many are `Verified=true`
- Any `Verified=false` that need follow-up

Ask:
1. *"Any unverified findings to verify now or remove?"*
2. *"Any findings to reclassify?"* (e.g., she initially flagged a regression that triage showed is intentional)
3. *"Anything you noticed that didn't make it into the CSV?"*

## Phase 5 — Generate report

```bash
scripts/regression-report.sh report \
  --output-dir ~/Desktop/regression-<TICKET> \
  --baseline-version <BASELINE> \
  --candidate-version <CANDIDATE> \
  --strict
```

If `--strict` complains about unverified findings, list them and ask: verify now, remove, or run without `--strict` (warning badges)?

```bash
open ~/Desktop/regression-<TICKET>/report/index.html
```

Ask her to skim and confirm.

## Phase 6 — Jira tickets

**Always dry-run first.**

```bash
scripts/regression-report.sh tickets \
  --output-dir ~/Desktop/regression-<TICKET> \
  --ticket <TICKET> \
  --dry-run
```

The dry-run prints what tickets would be created. Show her the output and ask: *"Should I create these for real, or do you want to copy them into Jira manually?"*

**If she has `JIRA_EMAIL` + `JIRA_API_TOKEN` configured:**
```bash
scripts/regression-report.sh tickets \
  --output-dir ~/Desktop/regression-<TICKET> \
  --ticket <TICKET>
```

**If she does NOT have Jira API access:** offer two paths.

1. *"Want me to set up the Jira API token now? Takes ~2 minutes and we can create tickets automatically."* → Walk through the "Jira API setup" appendix below, then re-run the real (non-dry-run) command above.

2. *"Or, if you'd rather paste them manually, I'll save the dry-run output as a markdown file and you can copy each ticket into Jira."* →

```bash
scripts/regression-report.sh tickets \
  --output-dir ~/Desktop/regression-<TICKET> \
  --ticket <TICKET> \
  --dry-run > ~/Desktop/regression-<TICKET>/tickets-to-create.md
```

Either way, link the tickets back to the parent (or note in the parent that tickets need to be created from `tickets-to-create.md`).

## Phase 7 — Done

Tell her where everything lives:

- **Workspace:** `~/Desktop/regression-<TICKET>/`
- **Report (HTML):** `~/Desktop/regression-<TICKET>/report/index.html`
- **Findings (CSV):** `~/Desktop/regression-<TICKET>/findings.csv`
- **Screenshots:** `~/Desktop/regression-<TICKET>/screenshots/`
- **Tickets to create:** `~/Desktop/regression-<TICKET>/tickets-to-create.md` (if Jira API not used)

Ask if she wants to share the report — explain that the simplest path is to attach `report/index.html` (and the screenshots/ folder) directly in Slack/Email/the Jira parent ticket. If her team has a regression-reports repo or Confluence space, she should follow her team's convention; this skill doesn't push to any repo on her behalf.

---

# Adding / modifying / removing scenarios

**Per-session changes** (only affects this regression run): edit `~/Desktop/regression-<TICKET>/TEST_MATRIX.md`. Add a row, remove one, annotate it. The HTML report regenerates from this file.

**Permanent changes** (affects every future regression): edit `docs/Testing/REGRESSION_TEST_MATRIX.md` in the repo and open a PR. Owners review additions to the canonical matrix.

**Adding a new test fixture** (a new test library, a new distributor): edit the *Test Fixtures* section at the top of `REGRESSION_TEST_MATRIX.md`. Include credentials env-var name (not the actual creds), OPDS URL, and which auth types it covers.

**CSV column changes:** `scripts/templates/regression-findings.csv` is the template. Adding columns there means every new workspace gets them.

When QA asks to add a scenario:
1. Ask: *"Is this for this release only, or should it stick around?"*
2. If permanent, help her draft the row in the matrix format. Open the file with Edit, insert the row in the right tier (P0/P1/P2) and section (auth/circulation/reading/etc.).
3. If she wants you to PR it, that's a separate user task — confirm before opening a PR.

---

# Codebase reference (for triage)

Use this map when she reports a finding and you need to find the code. Pair with `git grep` / `git log` to confirm.

## Top-level layout

```
Palace/
  AppInfrastructure/   # App launch, DI root (AppContainer.swift), navigation
  Accounts/            # Library account management + AccountsManager
  Book/                # TPPBook model, book detail views
  MyBooks/             # Downloaded books, BookRegistry, borrow/return UI
  Catalog/             # Catalog UI/data (legacy)
  CatalogDomain/       # Catalog API/parsing (newer)
  CatalogUI/           # Catalog SwiftUI views
  Audiobooks/          # Audiobook playback (Findaway, Overdrive, LCP, open-access)
  Reader2/             # EPUB reader (Readium 3.x, SwiftUI)
  Reader3/             # PDF reader
  OPDS/                # OPDS 1.x parsing (Objective-C)
  OPDS2/               # OPDS 2.0 parsing
  SignInLogic/         # Auth flows: basic, token, SAML, OIDC, OAuth, anonymous
  Network/             # HTTP networking (TPPNetworkExecutor, TPPNetworkResponder)
  Keychain/            # Secure credential storage
  Holds/               # Reservations + HoldsReducer
  Utilities/           # Extensions, helpers
  Migrations/          # App upgrade migrations
```

## Key types — when finding a bug, start here

| Symptom | Likely culprit class |
|---|---|
| Wrong button state on borrow / return | `BookCellModel`, `BookButtonsState`, `MyBooksDownloadCenter` |
| Sign-in modal appears on anonymous library | `TPPSignInBusinessLogic` (check anonymous-library guard) |
| Credential bleed across libraries | `TPPUserAccount` (must be per-account, not singleton) |
| Stale UI after sign-out | `TPPSignOutBusinessLogic`, `AccountsManager` |
| Hang after sign-out | `TPPSignOutBusinessLogic.signOut()` (F-080 territory) |
| 401 not retried | `TPPReauthenticator`, `TokenRefreshInterceptor` |
| OD audiobook borrow loops | `OverdriveDeferredFulfillment`, `deferOverdriveFulfillment` flag |
| LCP license error / re-download | `LCPLicenseService`, `CPMService` (PP-3704) |
| Adobe DRM crash | `TPPAdobeDRMContainer`, look for `AdobeCertificate` in Crashlytics |
| Position sync wrong on 2nd device | `TPPLastReadPositionSynchronizer`, `TPPAnnotations` (F-079: deviceID source) |
| Push notification routing | `TPPPushNotificationsManager`, `URLNotificationRouter` |
| Cover image 404 | OPDS link parsing — known bad images at `storage.googleapis.com/rua-uplo/` |

## Common false-positives (don't waste a finding on these)

- **Cryptonomicon on A1QA** — stuck license-pool state; never use for regression.
- **Overdrive on Lyrasis Reads** — fails with "Not a valid HPLD card", expected per Lyrasis ops.
- **`storage.googleapis.com/rua-uplo/` covers** — publisher deleted; 404 is expected.

## Legacy vs current modules

If the issue is in catalog, both `Catalog/` (legacy) and `CatalogDomain/` + `CatalogUI/` (current) exist. The active code path is *usually* the new one — confirm with `git log -1` on the suspect file. Old `Catalog/` code is mostly dormant but can still be live for some screens.

OPDS parsing is split: `OPDS/` (Objective-C, OPDS 1.x) is still active. `OPDS2/` (Swift, OPDS 2.0) handles auth-doc and most newer feeds.

---

# Quick reference

## Classification

| Classification | When to use | Jira type |
|---|---|---|
| `regression` | Worked in baseline, broken in candidate | Bug |
| `pre-existing` | Broken in both versions | Bug |
| `fixed` | Broken in baseline, fixed in candidate | (document only) |
| `behavior-change` | Intentional UX/functional change | (document only) |
| `new-feature` | Only in candidate, expected | (document only) |
| `superseded` | Initially logged, found incorrect | (exclude) |

## Severity

| Severity | Criteria | Jira priority |
|---|---|---|
| `blocker` | Data loss, credential leak, unrecoverable | Blocker |
| `major` | Core flow broken, painful workaround | High |
| `minor` | Noticeable but low impact | Normal |
| `cosmetic` | Visual only, no functional impact | Low |

## Test library credentials

Credentials are not in the repo. Get them from your team's QA credential store (1Password vault, internal wiki, team lead). The `ENVIRONMENT.md` template lists which libraries the matrix expects — fill in the env-var names there, never paste actual credentials into the CSV or report.

## Rules

- **CSV is the contract.** Findings only count if they're in `findings.csv`. The HTML report and Jira tickets generate from it.
- **Verified=true required for the report.** Unverified findings are flagged with warning badges unless removed.
- **One screenshot pair per finding.** Baseline + candidate. PNG, ≤800px wide. Filename matches CSV.
- **Always dry-run Jira tickets first.** Never create real tickets without showing her the dry-run.
- **No simdrive in this skill.** If the workflow would benefit from automation, suggest she ask the dev team to extend `/regression` (which is simdrive-aware) — don't try to run it yourself here.
- **Be encouraging.** Regression testing is tedious. Celebrate caught bugs — that's the point.

---

# Appendix — Jira API setup (one-time, ~2 minutes)

Follow this when Phase 0 reports `JIRA: not configured` and she wants ticket creation to work end-to-end. Walk her through it step by step. Don't paste her email or token into the conversation — she stays in control of her own credentials.

## Step 1 — Confirm she has Jira access

Ask: *"What's the URL of your team's Jira? (Something like `https://yourcompany.atlassian.net`.)"* If she can log into it in a browser and see PP-XXXX tickets, she has access.

She also needs to know the **email address** she logs into Jira with. Usually her work email. Ask her to confirm.

## Step 2 — Generate an API token

Tell her:

> Open this URL in your browser and sign in if asked:
> **https://id.atlassian.com/manage-profile/security/api-tokens**
>
> Click **Create API token**. Name it something like "Palace iOS regression — `<her-laptop-name>`" so it's easy to revoke later if needed. Copy the token to your clipboard. (You can't see it again after closing the dialog — if you lose it, just create a new one.)

Wait for her to confirm she has the token copied.

## Step 3 — Decide where to store it

There are two reasonable spots. Ask her which she prefers, then walk her through it.

### Option A — Environment variables (recommended; survives across projects)

Add the credentials to her shell profile so they're available in every terminal session.

Detect her shell:
```bash
echo "$SHELL"
```

If `zsh` (default on modern macOS) → file is `~/.zshrc`. If `bash` → file is `~/.bash_profile` or `~/.bashrc`.

Tell her to open the right file in her editor. **Don't echo into it from this session — she controls her own dotfiles.** Have her add these two lines at the bottom (with her real values):

```bash
export JIRA_EMAIL="her.email@example.com"
export JIRA_API_TOKEN="paste-the-token-here"
```

Save, then in the terminal she's running Claude Code from:

```bash
source ~/.zshrc   # or ~/.bash_profile if bash
```

(Or just close and reopen the terminal — same effect.)

### Option B — Project `.jira-config` file (only available in this repo)

If she'd rather scope the token to ios-core only:

```bash
cat > .jira-config <<'EOF'
JIRA_EMAIL="her.email@example.com"
JIRA_API_TOKEN="paste-the-token-here"
EOF
chmod 600 .jira-config
```

Confirm `.jira-config` is gitignored (it is — `.gitignore` covers `.jira*`-style names; double-check with `git check-ignore .jira-config`). **If `git check-ignore` shows the file is NOT ignored, stop and add `.jira-config` to `.gitignore` before continuing — we don't want a token in git.**

## Step 4 — Verify it works

Run a read-only sanity check. This proves auth works without creating anything:

```bash
curl -s -o /dev/null -w "%{http_code}\n" \
  -u "$JIRA_EMAIL:$JIRA_API_TOKEN" \
  "https://YOUR-TEAM.atlassian.net/rest/api/3/myself"
```

Replace `YOUR-TEAM.atlassian.net` with the URL from Step 1. Expected output: `200`.

- `200` → ✅ working. Continue to Step 5.
- `401` → wrong email or wrong token. Most often a copy-paste truncation. Generate a fresh token and re-export.
- `403` → her account doesn't have API access (rare on Atlassian Cloud, common on self-hosted). Ask her admin.
- `404` → wrong base URL. Confirm Step 1.

## Step 5 — Confirm the regression script picks it up

```bash
scripts/regression-report.sh tickets \
  --output-dir ~/Desktop/regression-<TICKET> \
  --ticket <TICKET> \
  --dry-run
```

If this prints "Generating Jira tickets" without complaining about missing creds, she's set up. The dry-run still doesn't write anything to Jira — that's the point. Real creation happens only when `--dry-run` is dropped.

## Step 6 — Token hygiene (mention this once and move on)

- API tokens are full-account credentials. Treat them like passwords.
- Revoke from the same page you created them at (id.atlassian.com → API tokens) if her laptop is lost or the credential leaks.
- If she ever pastes one into a chat, ticket, or commit by accident: revoke immediately, then create a fresh one.

---

When the appendix is done, return to the phase she was in (usually Phase 0 or Phase 6) and continue.
