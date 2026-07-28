# Attested-done — local pre-CI self-check (maintainer-only, self-disabling)

Heka is a **local maintainer tool**. Contributors on this repo don't have it (and it's
private), so attested-done is **NOT** in shared CI — cloning/building heka2 in every PR
would force private tooling on everyone and break the governance-split contract in
CLAUDE.md ("maintainer tooling is opt-in and self-disabling; contributors can ignore it").

Instead it is a **local pre-CI** gate: before you push, you run — locally — the same
checks CI will run, and record a signed proof the pre-push hook reads.

## Two layers (don't confuse them)

- **Shared CI (existing, heka-free):** `unit-testing.yml` & friends run the suite on every
  PR, for everyone. This is the real merge gate. **Unchanged — no heka in it.**
- **Local attested-done (heka, maintainer-only):** a pre-CI self-check that mirrors CI on
  your machine so you catch failures *before* spending CI minutes, and records a
  tamper-evident, tip-bound proof-of-done in the local `.heka` ledger.

## Mimic CI locally

`harness verify --tier T2` runs the **CI-identical** parity tier (T2 delegates to the same
`scripts/xcode-test-optimized.sh` CI runs) and, on green, signs a `verify:T2` bound to HEAD.
`--tier T1` is the faster subset for quick pre-push confidence (build + MetaTests + detectors
+ pytest — proven green end-to-end 2026-07-28).

## Self-disabling (the load-bearing property)

`pre-push-test-gate.sh` reads the local `.heka/telemetry.jsonl`. No heka installed / no ledger
→ it prints *"not heka-governed … Allowing push"* and exits 0. A contributor without heka
pushes normally; shared CI validates them. Nothing to install, nothing to configure.

## Enforcement (`HEKA_ATTESTED_DONE`)

- `warn` (default) — missing/stale/dirty proof prints the remedy, **allows** the push.
- `block` — a `.swift` push with no green tip-bound proof is **refused**.
- `off` — disabled.

The fleet runs many agents on the maintainer machine and they don't all run `harness verify`
before pushing, so **`block` set globally would deadlock their pushes.** Keep it `warn`
fleet-wide; use `block` only in a context that always verifies first (a solo maintainer, or a
per-agent opt-in). CI remains the universal gate regardless.

## Trust

The proof is signed with the maintainer's allowlisted key (`gates.review.signing_key` +
`.heka/allowed_signers`, both per-machine/gitignored). **Tip-binding** (not the signature) is
the anti-false-green property — a proof names the exact SHA it passed at, so a later commit
invalidates it (the #1333 property). The signature adds tamper-evidence. No CI key, no GitHub
secrets, no heka in shared CI.

## What each dev experiences

| | has heka (maintainer) | no heka (contributor) |
|---|---|---|
| `harness verify --tier T2` | runs CI-parity locally, signs proof | n/a (command absent) |
| `git push` (pre-push hook) | checks proof (warn/block per env) | "not heka-governed → allowed" |
| PR merge gate | shared CI (unit-testing.yml) | shared CI (unit-testing.yml) |
