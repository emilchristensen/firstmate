#!/usr/bin/env bash
# fm-bridge.sh - "The Bridge": a live, captain-facing fleet dashboard.
#
# A read-only, auto-refreshing terminal view of firstmate's fleet, triage-ordered
# so the captain's own to-dos surface first. It does not parse fleet state itself:
# it shells out to fm-fleet-snapshot.sh --json (schema fm-fleet-snapshot.v1) and
# renders that stable contract, exactly like fm-fleet-view.sh. The keyed
# open/resolved decision contract (fm-classify-lib.sh) is honoured through the
# snapshot's hints.pending_decision / hints.blocked_event, so a resolved decision
# or block is never shown as still-open.
#
# Four triage bands, in this fixed order:
#   1. NEEDS YOU  - captain-actionable only: open needs-decision, open blocked, and
#                   a finished task whose PR is checks-green and awaiting a merge
#                   (crew-state "done" with a PR and no merged/closed detail).
#   2. RUNNING    - live crewmates (endpoint present, crew-state working) not already
#                   in NEEDS YOU and not on hold. Shows id, project, current step,
#                   elapsed since start, and target PR if any.
#   3. WAITING / HELD - backlog holds (hold-kind + reason), paused statuses, and
#                   queued items blocked-by another task. Visible, not attention-grabbing.
#   4. LANDED     - the most recent Done entries (default last 5) with PR # or report path.
#
# Options:
#   --interval <seconds>  refresh cadence for the live loop (default 5)
#   --once                render a single frame to stdout and exit (scriptable/testable path)
#   --landed <n>          number of LANDED rows to show (default 5)
#   --no-color            force plain output
#   -h, --help            show usage
#
# Color degrades to plain automatically when stdout is not a TTY or NO_COLOR is set.
# The home is selected by FM_HOME / the standard FM_*_OVERRIDE env vars, inherited
# straight through to fm-fleet-snapshot.sh.
#
# v2 (not implemented): interactive keystrokes. The footer advertises [m]erge /
# [p]eek / [d]etail, but v1 is deliberately read-only and does NOT handle keys.
# A v2 would layer a read -rsn1 dispatch loop over the same snapshot, mapping keys
# to bin/fm-pr-merge.sh, bin/fm-peek.sh, and bin/fm-crew-state.sh for a selected row,
# and would surface true PR draft/open state (a network read this read-only view omits).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
usage: fm-bridge.sh [--interval <seconds>] [--once] [--landed <n>] [--no-color]

The Bridge: a live, read-only, triage-ordered fleet dashboard.
  --interval <seconds>  refresh cadence (default 5); ignored with --once
  --once                render one frame to stdout and exit
  --landed <n>          number of LANDED rows (default 5)
  --no-color            force plain output
EOF
}

INTERVAL=5
LANDED_N=5
ONCE=0
FORCE_NOCOLOR=0

while [ $# -gt 0 ]; do
  case "$1" in
    --interval) INTERVAL=${2:-}; shift 2 || { usage >&2; exit 2; } ;;
    --interval=*) INTERVAL=${1#*=}; shift ;;
    --landed) LANDED_N=${2:-}; shift 2 || { usage >&2; exit 2; } ;;
    --landed=*) LANDED_N=${1#*=}; shift ;;
    --once) ONCE=1; shift ;;
    --no-color) FORCE_NOCOLOR=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

case "$INTERVAL" in ''|*[!0-9]*) INTERVAL=5 ;; esac
[ "$INTERVAL" -gt 0 ] 2>/dev/null || INTERVAL=5
case "$LANDED_N" in ''|*[!0-9]*) LANDED_N=5 ;; esac

command -v jq >/dev/null 2>&1 || { echo "fm-bridge: jq not found" >&2; exit 1; }

# Color is on only for an interactive TTY without NO_COLOR and without --no-color.
USE_COLOR=1
if [ "$FORCE_NOCOLOR" = 1 ] || [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; then
  USE_COLOR=0
fi

if [ "$USE_COLOR" = 1 ]; then
  C_RESET=$'\033[0m'; C_HDR=$'\033[1;36m'; C_NEEDS=$'\033[1;31m'
  C_RUN=$'\033[0;32m'; C_HELD=$'\033[0;33m'; C_LAND=$'\033[2;32m'; C_DIM=$'\033[2m'
else
  C_RESET=''; C_HDR=''; C_NEEDS=''; C_RUN=''; C_HELD=''; C_LAND=''; C_DIM=''
fi

# jq emits each frame line as "<code>\t<text>"; bash truncates to the terminal
# width, then colours by band code. Keeping layout in jq and width+colour in bash
# avoids ever cutting through an ANSI escape.
color_for() {  # <code>
  case "$1" in
    H) printf '%s' "$C_HDR" ;;
    N) printf '%s' "$C_NEEDS" ;;
    R) printf '%s' "$C_RUN" ;;
    W) printf '%s' "$C_HELD" ;;
    L) printf '%s' "$C_LAND" ;;
    D) printf '%s' "$C_DIM" ;;
    *) printf '' ;;
  esac
}

build_frame() {  # <clock> <cols>
  local clock=$1 snapshot rc
  snapshot=$("$SCRIPT_DIR/fm-fleet-snapshot.sh" --json 2>/dev/null)
  rc=$?
  if [ $rc -ne 0 ] || [ -z "$snapshot" ]; then
    printf 'H\t%s\n' "⚓ THE BRIDGE"
    printf 'N\tfleet snapshot unavailable (fm-fleet-snapshot.sh exited %s)\n' "$rc"
    return 0
  fi
  printf '%s\n' "$snapshot" | jq -r \
    --arg clock "$clock" \
    --arg today "$(date +%Y-%m-%d)" \
    --argjson now "$(date +%s)" \
    --argjson landed_n "$LANDED_N" \
    --argjson interval "$INTERVAL" '
    def proj($t):
      ($t.project // "") | sub(".*/"; "")
      | if . == "" then ($t.backlog.repo // "-") else . end;
    def prnum($url):
      if ($url // "") == "" then null
      else ($url | (capture("/pull/(?<n>[0-9]+)")? // {n:null}) | .n) end;
    def clip($s; $n): ($s // "") | if length > $n then .[0:$n-1] + "…" else . end;
    def elapsed($since):
      if ($since // "") == "" then "-"
      else ((try ($since | strptime("%Y-%m-%d") | mktime) catch null) as $e
        | if $e == null then $since
          else (($now - $e) / 86400 | floor) as $d
            | if $d <= 0 then "today" else "\($d)d" end
          end)
      end;

    # --- classify tasks -----------------------------------------------------
    ([.tasks[]
      | . as $t
      | (.pr.url) as $pr
      | (.current_state.state) as $st
      | ((.current_state.detail // "") | test("merged|closed")) as $merged
      | (.hints.pending_decision) as $pending
      | (.hints.blocked_event) as $blocked
      | (($pr != null) and ($st == "done") and ($merged | not)) as $mergeready
      | (($pending or $blocked or $mergeready)) as $needs
      | . + {
          _needs: $needs,
          _mergeready: $mergeready,
          _running: ((.endpoint.exists == true)
                     and ($st | IN("working","running","fixing","ci"))
                     and ($needs | not)
                     and ((.backlog.held // false) | not)),
          _paused: (($st == "paused") and ($needs | not))
        }
    ]) as $tasks |
    ([$tasks[] | select(._needs) | .id]) as $needs_ids |

    # --- band lines ---------------------------------------------------------
    ([$tasks[] | select(._needs)
      | (if .hints.pending_decision then "decision needed"
         elif .hints.blocked_event then "blocked - needs help"
         else "PR checks green - ready to merge" end) as $why
      | (prnum(.pr.url)) as $n
      | "N\t  \(.id)  [\(proj(.))]  \($why)" + (if $n then "  PR #\($n)" else "" end)
    ]) as $needs_lines |

    ([$tasks[] | select(._running)
      | (prnum(.pr.url)) as $n
      | "R\t  \(.id)  [\(proj(.))]  \(clip(.current_state.detail; 46))  \(elapsed(.backlog.since))"
        + (if $n then "  PR #\($n)" else "" end)
    ]) as $running_lines |

    # WAITING / HELD draws from backlog holds, paused tasks, and blocked-by queued
    # items. Held rows come from the backlog regardless of live task state, so an
    # id already surfaced in NEEDS YOU is excluded to avoid a double listing.
    ([.backlog.records[]? | select(.structured and (.held // false) and (.id as $i | $needs_ids | index($i) | not))
      | "W\t  \(.id)  held (\(.hold_kind // "hold")): \(.hold_reason // "-")"
        + (if (.hold_until // "") != "" then "  until \(.hold_until)" else "" end)
    ]) as $hold_lines |
    ([$tasks[] | select(._paused and (._running | not))
      | "W\t  \(.id)  [\(proj(.))]  paused: \(clip(.current_state.detail; 46))"
    ]) as $paused_lines |
    ([.backlog.records[]? | select(.structured and .state == "queued" and (.blocked_by // "") != "" and ((.held // false) | not))
      | "W\t  \(.id)  blocked-by \(.blocked_by)"
        + (if (.blocked_reason // "") != "" then " - \(.blocked_reason)" else "" end)
    ]) as $blocked_lines |
    ($hold_lines + $paused_lines + $blocked_lines) as $waiting_lines |

    ([.backlog.records[]? | select(.structured and .state == "done")]
      | sort_by(.completion.date // "") | reverse | .[0:$landed_n]
      | [ .[]
        | (prnum(.pr_url)) as $n
        | "L\t  \(clip(.title; 40))  "
          + (if $n then "PR #\($n)"
             elif (.report_path // "") != "" then .report_path
             elif (.local_note // "") != "" then .local_note
             else "-" end)
          + (if (.completion.date // "") != "" then "  (\(.completion.date))" else "" end)
      ]) as $landed_lines |

    # --- assemble frame -----------------------------------------------------
    "H\t⚓ THE BRIDGE    running \($running_lines | length) · held \($hold_lines | length) · needs-you \($needs_lines | length)    \($clock)    ⟳ \($interval)s",
    "P\t",
    "N\tNEEDS YOU",
    (if ($needs_lines | length) == 0 then "D\t  (nothing waiting on you)" else $needs_lines[] end),
    "P\t",
    "R\tRUNNING",
    (if ($running_lines | length) == 0 then "D\t  (no live crew)" else $running_lines[] end),
    "P\t",
    "W\tWAITING / HELD",
    (if ($waiting_lines | length) == 0 then "D\t  (nothing waiting)" else $waiting_lines[] end),
    "P\t",
    "L\tLANDED",
    (if ($landed_lines | length) == 0 then "D\t  (nothing landed yet)" else $landed_lines[] end),
    "P\t",
    "D\t  [m]erge  [p]eek  [d]etail  (read-only in v1; keys are a v2 follow-up)"
  '
}

render_frame() {  # <cols>
  local cols=$1 code text line
  while IFS=$'\t' read -r code text; do
    # Truncate the plain text to the terminal width before adding colour so an
    # ANSI escape is never cut mid-sequence; survives resize via per-frame cols.
    if [ "${#text}" -gt "$cols" ]; then
      text=${text:0:cols}
    fi
    if [ "$USE_COLOR" = 1 ]; then
      line="$(color_for "$code")${text}${C_RESET}"
    else
      line="$text"
    fi
    printf '%s\n' "$line"
  done
}

term_cols() {
  local c
  c=$(tput cols 2>/dev/null || true)
  case "$c" in ''|*[!0-9]*) c=100 ;; esac
  [ "$c" -gt 0 ] 2>/dev/null || c=100
  printf '%s' "$c"
}

if [ "$ONCE" = 1 ]; then
  build_frame "$(date +%H:%M:%S)" "$(term_cols)" | render_frame "$(term_cols)"
  exit 0
fi

cleanup() { printf '\033[?25h'; }  # restore cursor on exit
trap 'cleanup; exit 0' INT TERM
[ "$USE_COLOR" = 1 ] && printf '\033[?25l'  # hide cursor during the loop
while :; do
  cols=$(term_cols)
  frame=$(build_frame "$(date +%H:%M:%S)" "$cols")
  printf '\033[H\033[2J'          # home + clear
  printf '%s\n' "$frame" | render_frame "$cols"
  sleep "$INTERVAL"
done
