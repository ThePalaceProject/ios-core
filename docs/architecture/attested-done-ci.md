# CI-gated attested-done — the self-validating proof-of-done

**Status:** scaffolded 2026-07-28, NOT yet a required check (needs the human trust-root
setup + one dry-run — see "Activation" below). Owner: Maurice.

## Why this exists

The local pre-push gate (`scripts/pre-push-test-gate.sh`) can enforce an attested `verify:T*`
on push, but the proof must be produced *locally* — which either puts a human in the loop
(run `harness verify` before every push) or lets an agent mint its own proof. Neither is what
we want. The stated model is: **the system validates itself; humans spot-check PRs; no human
proof-gate.**

That is **CI-gated attestation**: CI runs the authoritative suite on every PR and, on green,
mints a signed `verify:T*` bound to the PR head — signed by **CI's own identity** (`ci-runner`),
not a human and not the local agent. The merge is gated on that check. Humans review the diff.

The load-bearing property is **tip-binding + a trusted signer**: the proof names the exact SHA
the suite passed at, and it is signed by a key only CI holds. A later commit invalidates it
(the #1333 property); an agent cannot forge it (it never has the CI key).

## Trust model

| Identity | Key location | Role |
|---|---|---|
| `architect-review`, `blast-review` | `~/.ssh/id_ed25519` (Maurice's) | SoD reviewers (local) |
| **`ci-runner`** (new) | **GitHub Actions secret `HEKA_CI_SIGNING_KEY`** | mints CI proofs-of-done |

`ci-runner`'s **public** key goes in the committed `.heka/allowed_signers` (public, auditable).
Its **private** key lives ONLY in GitHub Actions secrets — never on a dev machine, never in the
repo. That is what makes a CI proof unforgeable by any local actor (human or agent): only the
CI environment can sign as `ci-runner`.

Domain separation: verify attestations are signed under `heka-verify@v1`, so a CI proof can
never cross-validate as a review.

## Flow

```
PR opened / updated
  └─ "Unit Tests" workflow runs the authoritative suite (existing unit-testing.yml)
        └─ on success →  workflow_run trigger  →  attested-done.yml
              1. confirm the Unit Tests conclusion == success AND head_sha == this SHA
              2. write HEKA_CI_SIGNING_KEY (secret) to a 0600 temp file
              3. heka2 gate verify-attest --tier T2 --runner ci-runner   (signs, tip-bound)
              4. upload the signed attestation as an evidence artifact + push it to
                 refs/heka/evidence/<sha>/ (so a merge recheck can read it without the ledger)
              5. job success == the required check
```

The attestation is minted by a job that **observed** the green suite at that SHA — it does not
re-run the suite (no duplicated 40 min). If Unit Tests fails, `workflow_run` still fires but
step 1 refuses (conclusion != success) → no proof → the required check is red → merge blocked.

## Files

- `.github/workflows/attested-done.yml` — the `workflow_run` job.
- `scripts/ci-attest.sh` — writes the key from env, runs verify-attest, exports evidence, and
  ALWAYS shreds the temp key (trap). Kept out of the YAML so it is unit-testable and readable.
- `.heka/allowed_signers` — add the `ci-runner` line (human step).

## heka2 in CI

`ci-attest.sh` needs the `heka2` binary. Two supported ways (pick one at activation):
- **Build from pinned source** (recommended for trust): checkout `SyncTek-LLC/heka2` at the SHA
  in `.heka/heka2-ci-ref` and `go build`. Requires the CI token to have read access to that repo.
- **Pinned release binary**: `gh release download` a signed heka2 release. Simpler; requires a
  release pipeline. The workflow supports both via the `HEKA2_SOURCE` env (`build` | `release`).

## Activation (human trust-root steps — an agent cannot do these)

1. **Generate the CI signer** (offline, on your machine):
   ```bash
   ssh-keygen -t ed25519 -N '' -C ci-runner -f /tmp/ci-runner
   # public line for the allowlist:
   echo "ci-runner $(cut -d' ' -f1,2 /tmp/ci-runner.pub)"
   ```
2. **Commit the public half** — append that `ci-runner …` line to `.heka/allowed_signers`.
3. **Store the private half** as GitHub Actions secret `HEKA_CI_SIGNING_KEY` (repo → Settings →
   Secrets → Actions). Then `shred -u /tmp/ci-runner*` — it must exist ONLY in the secret.
4. **Dry-run**: open a throwaway PR; confirm `attested-done` runs, mints a `verify:T2 [tier: signed]`
   bound to the head SHA, and that flipping a test red makes it withhold the proof. (Per the
   green-board contract: do NOT make it a *required* check until this dry-run is clean.)
5. **Make it required**: branch protection on `develop`/`main` → require the `attested-done` check.
6. **Local gate stays `warn`** (`HEKA_ATTESTED_DONE` unset/`warn`) — CI is the enforcement, so no
   fleet agent's push is blocked on a proof it doesn't produce. Optionally, agents may still run
   `harness verify` locally for fast pre-push feedback.

## Verified property vs local attested

A CI proof can be elevated to the `verified` tier by `heka2 gate review-recheck`/`verify-recheck`
run against a **CI-held** allowlist (trust from *where* it runs). That is a follow-up; v1 records
the `signed` tier, which the tip-bound merge gate already trusts.
