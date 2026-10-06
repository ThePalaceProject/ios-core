#!/usr/bin/env bash
#
# check-file-size-ceiling.sh — no app-target Swift file may exceed a CODE-line
# ceiling unless it is explicitly allowlisted at a recorded size.
#
# prior-art-checked: this REPLACES scripts/check-godclass-loc-freeze.sh rather
# than paralleling it. That gate watches six named files. `harness capabilities`
# has no file-size capability. The counting function below is lifted verbatim
# from the freeze script so both gates agree on what a "code line" is.
#
# WHY A GENERIC CEILING AND NOT A NAMED LIST
#
#   The six-file freeze can only see files someone already noticed. Two things
#   went past it:
#
#   1. Decomposition MINTS god-classes, and a named list cannot see them.
#      Palace/Accounts/Library/AccountRegistryLoader.swift was CREATED at 693
#      code lines by the Wave 3a decomposition on 2026-07-31 with no baseline
#      entry, so it was born unwatched. Note what the ceiling does and does not
#      do here: at 693 that file is still 107 lines clear of 800, so this gate
#      does not catch it TODAY. What it catches is the class — any file, named
#      or not, the moment it crosses — which is the property the freeze lacked.
#
#   2. The freeze's own escape hatch became the accretion channel. The
#      3.2.1 / 3.2.2 / 3.2.3 hotfix forward-port (PR #1348) re-baselined four
#      frozen hubs UPWARD, each increase justified in a paragraph appended to
#      the baseline file: AudiobookSessionManager +329, TPPSignInBusinessLogic
#      +83 and a further +54 recorded separately, AccountsManager +52,
#      MyBooksDownloadCenter +10 — +528 across that forward-port. (A wider
#      total over the baseline's whole history is not quotable: the entries mix
#      physical and code-line metrics, so they do not sum to anything true.)
#      The baseline stopped being a
#      ratchet and became a changelog.
#
#      Those figures are the baseline's own PHYSICAL line counts (e.g.
#      AudiobookSessionManager 2764 -> 3093), not the code-line metric this
#      gate uses — the baseline's banner says the two are not comparable, and
#      the same file measures 1206 code lines today. An earlier version of this
#      comment attributed the increases to releases 3.2.4 / 3.3.0 / 3.3.1,
#      which appear nowhere in the baseline, called them code lines, and
#      totalled 474 by omitting the +54 it went on to itemize. The argument for
#      a ceiling is unaffected; the evidence for it was wrong on three axes.
#
#   A ceiling with no upward path fixes both: a new file is caught the moment it
#   crosses, and a forward-port that grows a hub must extract a cluster in the
#   same PR (the PP-5135 pattern, which ended below where it started) rather
#   than raise a number.
#
# THE RULE
#
#   Every .swift file under Palace/ must be <= CEILING code lines, OR appear in
#   ALLOWLIST at a size it may not exceed. That INCLUDES Palace/Packages/*/Sources
#   — package Tests are out of scope, package source is not.
#
#   Excluding packages was the first version of this gate and it was wrong. The
#   package boundaries constrain dependency DIRECTION, which is orthogonal to
#   file size, so "packages have their own boundaries" does not cover this axis.
#   Worse, phases B-F of the modularisation are the motion of app code INTO
#   packages, so the exclusion would have switched the ceiling off exactly where
#   this campaign operates: relocating an allowlisted hub into a package erased
#   both the ceiling and its recorded cap, silently. It was not hypothetical —
#   PalaceTriageBot's ConversationReducer.swift was already 848 lines inside the
#   blind spot, in a package that ships in the app.
#
#   Allowlist entries ratchet DOWN by hand only. There is deliberately no
#   mechanism to raise one; that is the whole point.
#
# Exit: 0 clean · 1 a file over its limit · 2 usage error.

set -uo pipefail

CEILING="${FILE_SIZE_CEILING:-800}"
ROOT="${1:-$(git rev-parse --show-toplevel 2>/dev/null || echo .)}"
SRC="$ROOT/Palace"

# <max-code-lines> <repo-relative path>   — ratchet DOWN only.
# Every entry is a decomposition target with a phase that will retire it.
# Every cap below was ratcheted down in Phase B1 when loc_of stopped counting
# `import` declarations — same files, same code, a smaller and stricter number.
read -r -d '' ALLOWLIST <<'EOF'
# Wave 6 (god-class-decomposition-plan.md §4) moved the playback-failure
# recovery decision to AudiobookPlaybackRecoveryReducer.swift and the
# open-time position decision to AudiobookPositionResolver.swift, both
# in-target and both well under the ceiling. 1546 -> 1234, then
# -> 1213 when PP-5242 moved the failure-record builder out, then -> 1206
# when PP-5241 moved its recovery host and two pure error mappers out, then
# -> 1193 when PP-4967 moved the OverDrive re-fulfilment out.
1193 Palace/Audiobooks/AudiobookSessionManager.swift
# 1213 -> 1172 when the mid-download network-loss handler moved to
# DownloadNetworkLossMonitor.swift.
1172 Palace/MyBooks/MyBooksDownloadCenter.swift
1044 Palace/AppInfrastructure/AudiobookMorphingPlayerView.swift
867  Palace/Book/UI/BookDetail/BookDetailViewModel.swift
871  Palace/Utilities/Localization/Strings.swift
# AccountsManager is 367 under this metric, not 366: #1520 landed
# `_ = registryLoader` in init while this branch was in review. Re-measured
# against the current tree with this gate's own import-excluding counter, not
# derived by adding one to the previous number.
#
# Carried over from the retired six-file freeze at their MEASURED sizes, not the
# freeze's stale numbers. Without these three the swap would LOOSEN exactly the
# files that forward-port's accretion landed on: the 800 ceiling would hand AccountsManager
# 429 lines of headroom, TPPSignInBusinessLogic 162 and BorrowOperation 279 —
# 870 in total, on two CLAUDE.md critical paths (sign-in, borrow). The allowlist
# only ratchets down, so pinning them costs nothing and closes the regression.
367  Palace/Accounts/Library/AccountsManager.swift
634  Palace/SignInLogic/TPPSignInBusinessLogic.swift
514  Palace/MyBooks/BorrowOperation.swift
# Package source is in scope (see THE RULE). This one was already over the
# ceiling inside the old blind spot; pinned here at its measured size so the
# scope widening lands green rather than red-on-arrival.
847  Palace/Packages/PalaceTriageBot/Sources/TriageBotCore/Reducer/ConversationReducer.swift
EOF

# Injection seam, matching FILE_SIZE_CEILING. Without it the pytest fixture had
# to PARSE the heredoc above to build its stub tree, which blinded it to two
# whole classes: a typo'd allowlist path left 16 of 17 arms green, and an
# inflated cap was invisible to fixture AND live tree. With the seam a fixture
# supplies its own allowlist and can assert the enforcement itself — in
# particular that a SUB-CEILING pin is enforced at all, which nothing held:
# deleting `371 AccountsManager.swift` left every test green while the file
# grew to 571, because 571 is under the 800 ceiling and no fixture knew the pin
# was meant to exist. Those are the critical-path caps a prior review round
# demanded, so "present but unenforced" was the worst of the three states.
if [ -n "${FILE_SIZE_ALLOWLIST_FILE:-}" ]; then
  [ -f "$FILE_SIZE_ALLOWLIST_FILE" ] || {
    echo "[file-size] ERROR: FILE_SIZE_ALLOWLIST_FILE=$FILE_SIZE_ALLOWLIST_FILE does not exist" >&2
    exit 2
  }
  ALLOWLIST="$(cat "$FILE_SIZE_ALLOWLIST_FILE")"
fi

[ -d "$SRC" ] || { echo "[file-size] ERROR: no $SRC" >&2; exit 2; }

loc_of() {  # live CODE-line count (non-blank, non-comment-only, non-import); -1 if missing
  local p="$1"
  [ -f "$p" ] || { echo "-1"; return; }
  # `import` declarations are excluded, and the exclusion is load-bearing rather
  # than cosmetic. This gate exists to serve the decomposition campaign, and the
  # campaign's mechanism is moving code into SPM packages — which costs every
  # consuming file exactly one `import` line and nothing else. Counting that
  # line meant an extraction could not touch a capped hub at all: Phase B1
  # (PalaceUtilities) added one import each to AudiobookSessionManager,
  # AudiobookMorphingPlayerView, TPPSignInBusinessLogic and BookDetailViewModel
  # and pushed all four exactly 1 over their caps, with no downward path
  # available, since the allowlist ratchets down only.
  #
  # An import carries no logic, so excluding it does not open a channel for the
  # accretion this gate watches for. It does make every measurement smaller, and
  # a smaller measurement under an unchanged cap is slack — so every allowlist
  # cap above was re-measured and re-pinned to its new value in the same change.
  #
  # Measured, because the obvious claim here is wrong: slack is ZERO on all nine
  # files both before and after, so the gate is exactly as tight, not tighter.
  # The caps fell because the metric changed, not because headroom was removed.
  # Re-pinning is what PRESERVES the zero; it does not improve on it.
  awk '
    {
      s = $0
      sub(/^[[:space:]]+/, "", s)
      if (s == "")            next
      if (s ~ "^//")          next
      if (s ~ "^/?[*]")       next
      if (s ~ "^(@[A-Za-z_][A-Za-z0-9_]*[[:space:]]+)*import[[:space:]]") next
      n++
    }
    END { print n + 0 }
  ' "$p"
}

allowed_max() {  # echoes the cap for a path, or nothing
  local want="$1" cap p
  while read -r cap p; do
    [ -z "${cap:-}" ] && continue
    case "$cap" in '#'*) continue ;; esac
    [ -z "${p:-}" ] && continue
    [ "$p" = "$want" ] && { printf '%s' "$cap"; return 0; }
  done <<< "$ALLOWLIST"
  return 1
}

# B2: the scan is driven by `find`, so an allowlist entry whose file has moved
# or been deleted is simply never consulted — the cap evaporates with no signal.
# Combined with a relocation into a package that was the whole silent-laundering
# path. Absence must not render as success (.forgeos/wall-failures/
# 2026-08-24-exemption-spanning-absence-categories.md).
# A DUPLICATE path is a silent weakening, and it defeated the live-allowlist
# test: `allowed_max()` is first-match-wins while the test's parser is
# last-match-wins, so an entry with a raised cap placed ABOVE the real one gave
# AccountsManager 371 -> 621 with the gate at exit 0 and every test green.
# Rejecting duplicates makes the two readings agree by construction.
# Validate the allowlist ONCE here rather than per file: allowed_max() runs for
# every Swift file in the tree, so a check inside it printed the same complaint
# 723 times.
bad_caps="$(printf '%s\n' "$ALLOWLIST" \
            | awk '!/^[[:space:]]*#/ && NF >= 1 && $1 !~ /^[0-9]+$/ { print }')"
if [ -n "$bad_caps" ]; then
  echo "  MALFORMED-ALLOWLIST — every entry is '<max-code-lines> <path>':" >&2
  printf '    %s\n' "$bad_caps" >&2
  exit 1
fi

missing_paths="$(printf '%s\n' "$ALLOWLIST" \
                 | awk '!/^[[:space:]]*#/ && NF == 1 { print }')"
if [ -n "$missing_paths" ]; then
  echo "  MALFORMED-ALLOWLIST — a cap with no path:" >&2
  printf '    %s\n' "$missing_paths" >&2
  exit 1
fi

dupes="$(printf '%s\n' "$ALLOWLIST" | awk '!/^[[:space:]]*#/ && NF >= 2 { print $2 }' | sort | uniq -d)"
if [ -n "$dupes" ]; then
  echo "  DUPLICATE-ALLOWLIST entries — first match wins, so a raised cap above" >&2
  echo "  the real one silently replaces it. Keep exactly one line per path:" >&2
  printf '    %s\n' $dupes >&2
  exit 1
fi

missing=0
while read -r cap p; do
  [ -z "${cap:-}" ] && continue
  case "$cap" in '#'*) continue ;; esac
  [ -z "${p:-}" ] && continue
  [ -f "$ROOT/$p" ] && continue
  echo "  STALE-ALLOWLIST $p — capped at $cap but no such file" >&2
  missing=$((missing + 1))
done <<< "$ALLOWLIST"

fails=0
over_allow=0
shrunk=""

while IFS= read -r f; do
  rel="${f#"$ROOT"/}"
  n="$(loc_of "$f")"
  [ "$n" -lt 0 ] && continue

  if cap="$(allowed_max "$rel")"; then
    if [ "$n" -gt "$cap" ]; then
      echo "  OVER-ALLOWLIST  $rel — $n code lines, capped at $cap" >&2
      over_allow=$((over_allow + 1))
    elif [ "$n" -lt "$cap" ]; then
      shrunk="${shrunk}    $rel: $cap -> $n (ratchet this down)"$'\n'
    fi
    continue
  fi

  if [ "$n" -gt "$CEILING" ]; then
    echo "  OVER-CEILING    $rel — $n code lines, ceiling is $CEILING" >&2
    fails=$((fails + 1))
  fi
done < <(find "$SRC" -name '*.swift' \
             ! \( -path "$SRC/Packages/*" ! -path "$SRC/Packages/*/Sources/*" \) \
             2>/dev/null)

if [ -n "$shrunk" ]; then
  echo "[file-size] these allowlisted files SHRANK — tighten the cap:"
  printf '%s' "$shrunk"
  echo
fi

total=$((fails + over_allow + missing))
if [ "$total" -gt 0 ]; then
  cat >&2 <<EOF

[file-size] FAILED: $total problem(s) — $fails over ceiling, $over_allow allowlisted-and-growing, $missing allowlisted-but-absent.

There is no upward re-baseline. If a forward-port grows a hub, extract a cluster
in the SAME PR — the PP-5135 pattern, which ended below where it started. Raising
a number is how +528 physical lines landed on four frozen hubs in a single
hotfix forward-port (PR #1348).

A genuinely new permanent file (a generated table, a composition root) may be
added to ALLOWLIST at its current size, with the phase that will retire it.

An allowlisted-but-absent entry means the file moved, was renamed, or was split.
DELETE the entry if the hub is genuinely gone; RE-POINT it if the code just
relocated. Leaving it is how a cap silently stops applying.
EOF
  exit 1
fi

echo "[file-size] OK — no app-target file over $CEILING code lines outside the allowlist."
exit 0
