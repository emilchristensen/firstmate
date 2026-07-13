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
#                   real elapsed since the task started, and target PR if any.
#   3. WAITING / HELD - backlog holds (hold-kind + reason), paused statuses, and
#                   queued items blocked-by another task. Visible, not attention-grabbing.
#   4. LANDED     - the most recent Done entries (default last 5) with PR # or a
#                   compact report artifact.
#
# Layout is fitted to the terminal width in jq (columns passed per frame): every
# line is clipped with a clean "…" and never hard-cut mid-word, and RUNNING /
# LANDED budget their columns so the trailing field (elapsed + PR, or PR # + date)
# is ALWAYS shown in full and only the step / title column truncates. Terminal
# width comes from $COLUMNS, else `tput cols`, else 100, re-read each frame so a
# resize reflows on the next tick.
#
# Elapsed is measured from the task's real start time - the birth time of its
# state/<id>.meta - so it reads like "4m" or "1h3m", not a calendar-day word. It
# falls back to the backlog "since" date only when a birth time is unavailable.
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

# jq emits each frame line as "<code>\t<text>", already width-fitted; bash only
# adds colour by band code. No truncation happens in bash, so an ANSI escape or a
# multibyte "…" is never cut.
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

# stat(1) is BSD on macOS and GNU on Linux; probe once so birth/mtime reads use
# the right flags. Birth time (spawn time) is preferred; mtime is the fallback.
if stat -f %m . >/dev/null 2>&1; then STAT_FLAVOR=bsd; else STAT_FLAVOR=gnu; fi

file_start_epoch() {  # <file> -> epoch seconds, or 0 if unknown
  local f=$1 e=''
  [ -n "$f" ] && [ -e "$f" ] || { printf '0'; return; }
  if [ "$STAT_FLAVOR" = bsd ]; then
    e=$(stat -f %B "$f" 2>/dev/null)
    { [ -z "$e" ] || [ "$e" = 0 ]; } && e=$(stat -f %m "$f" 2>/dev/null)
  else
    e=$(stat -c %W "$f" 2>/dev/null)
    { [ -z "$e" ] || [ "$e" = 0 ]; } && e=$(stat -c %Y "$f" 2>/dev/null)
  fi
  case "$e" in ''|*[!0-9]*) e=0 ;; esac
  printf '%s' "$e"
}

# {id: start-epoch} for every task, built from each meta file's birth time.
starts_json() {  # <snapshot-json>
  local out
  out=$(printf '%s\n' "$1" | jq -r '.tasks[]? | [.id, (.paths.meta.path // "")] | @tsv' \
    | while IFS=$'\t' read -r id mp; do
        [ -n "$id" ] || continue
        printf '%s\t%s\n' "$id" "$(file_start_epoch "$mp")"
      done \
    | jq -R -s 'split("\n") | map(select(length > 0)) | map(split("\t"))
                | map({key: .[0], value: (.[1] | tonumber)}) | from_entries')
  [ -n "$out" ] && printf '%s' "$out" || printf '{}'
}

build_frame() {  # <clock> <cols>
  local clock=$1 cols=$2 snapshot rc starts
  snapshot=$("$SCRIPT_DIR/fm-fleet-snapshot.sh" --json 2>/dev/null)
  rc=$?
  if [ $rc -ne 0 ] || [ -z "$snapshot" ]; then
    printf 'H\t%s\n' "⚓ THE BRIDGE"
    printf 'N\tfleet snapshot unavailable (fm-fleet-snapshot.sh exited %s)\n' "$rc"
    return 0
  fi
  starts=$(starts_json "$snapshot")
  printf '%s\n' "$snapshot" | jq -r \
    --arg clock "$clock" \
    --argjson now "$(date +%s)" \
    --argjson cols "$cols" \
    --argjson landed_n "$LANDED_N" \
    --argjson interval "$INTERVAL" \
    --argjson starts "$starts" '
    def fit($s; $w):
      ($s // "") | if $w <= 0 then "" elif (length <= $w) then . else (.[0:([$w-1, 0] | max)] + "…") end;
    def proj($t):
      ($t.project // "") | sub(".*/"; "") | if . == "" then ($t.backlog.repo // "-") else . end;
    def prnum($url):
      if ($url // "") == "" then null
      else ($url | (capture("/pull/(?<n>[0-9]+)")? // {n:null}) | .n) end;
    # Real duration from seconds: 47s, 4m, 1h3m, 2d4h. Explicit arithmetic (no %).
    def fmt_dur($sec):
      (if $sec < 0 then 0 else $sec end) as $s
      | if $s < 60 then "\($s)s"
        elif $s < 3600 then "\(($s / 60) | floor)m"
        elif $s < 86400 then (($s / 3600) | floor) as $h | ((($s - $h * 3600) / 60) | floor) as $m | "\($h)h\($m)m"
        else (($s / 86400) | floor) as $d | ((($s - $d * 86400) / 3600) | floor) as $h | "\($d)d\($h)h" end;
    def since_days($since):
      if ($since // "") == "" then "-"
      else ((try ($since | strptime("%Y-%m-%d") | mktime) catch null) as $e
        | if $e == null then $since
          else (($now - $e) / 86400 | floor) as $d | (if $d <= 0 then "<1d" else "\($d)d" end)
          end)
      end;
    def elapsed($id; $since):
      ($starts[$id] // 0) as $e | if $e > 0 then fmt_dur($now - $e) else since_days($since) end;
    # Compact landed artifact: PR #, else the report basename (no data/<id>/ path), else a local note.
    def artifact_compact($r):
      if (prnum($r.pr_url)) != null then "PR #\(prnum($r.pr_url))"
      elif (($r.report_path // "") != "") then ($r.report_path | sub(".*/"; ""))
      elif (($r.local_note // "") != "") then $r.local_note
      else "-" end;

    # --- classify tasks -----------------------------------------------------
    ([.tasks[]
      | (.pr.url) as $pr
      | (.current_state.state) as $st
      | ((.current_state.detail // "") | test("merged|closed")) as $merged
      | (.hints.pending_decision) as $pending
      | (.hints.blocked_event) as $blocked
      | (($pr != null) and ($st == "done") and ($merged | not)) as $mergeready
      | (($pending or $blocked or $mergeready)) as $needs
      | . + {
          _needs: $needs,
          _running: ((.endpoint.exists == true)
                     and ($st | IN("working","running","fixing","ci"))
                     and ($needs | not)
                     and ((.backlog.held // false) | not)),
          _paused: (($st == "paused") and ($needs | not))
        }
    ]) as $tasks |
    ([$tasks[] | select(._needs) | .id]) as $needs_ids |

    # --- band lines (RUNNING and LANDED budget their trailing field) ---------
    ([$tasks[] | select(._needs)
      | (if .hints.pending_decision then "decision needed"
         elif .hints.blocked_event then "blocked - needs help"
         else "PR checks green - ready to merge" end) as $why
      | (prnum(.pr.url)) as $n
      | "N\t  \(.id)  [\(proj(.))]  \($why)" + (if $n then "  PR #\($n)" else "" end)
    ]) as $needs_lines |

    ([$tasks[] | select(._running)
      | (prnum(.pr.url)) as $n
      | "  \(.id)  [\(proj(.))]  " as $left
      | ("  \(elapsed(.id; .backlog.since))" + (if $n then "  PR #\($n)" else "" end)) as $right
      | ($cols - ($left | length) - ($right | length)) as $mid
      | "R\t" + $left + fit(.current_state.detail; $mid) + $right
    ]) as $running_lines |

    # WAITING / HELD draws from backlog holds, paused tasks, and blocked-by queued
    # items. Held rows come from the backlog regardless of live task state, so an
    # id already surfaced in NEEDS YOU is excluded to avoid a double listing.
    ([.backlog.records[]? | select(.structured and (.held // false) and (.id as $i | $needs_ids | index($i) | not))
      | "W\t  \(.id)  held (\(.hold_kind // "hold")): \(.hold_reason // "-")"
        + (if (.hold_until // "") != "" then "  until \(.hold_until)" else "" end)
    ]) as $hold_lines |
    ([$tasks[] | select(._paused and (._running | not))
      | "W\t  \(.id)  [\(proj(.))]  paused: \(.current_state.detail // "")"
    ]) as $paused_lines |
    ([.backlog.records[]? | select(.structured and .state == "queued" and (.blocked_by // "") != "" and ((.held // false) | not))
      | "W\t  \(.id)  blocked-by \(.blocked_by)"
        + (if (.blocked_reason // "") != "" then " - \(.blocked_reason)" else "" end)
    ]) as $blocked_lines |
    ($hold_lines + $paused_lines + $blocked_lines) as $waiting_lines |

    ([.backlog.records[]? | select(.structured and .state == "done")]
      | sort_by(.completion.date // "") | reverse | .[0:$landed_n]
      | [ .[]
        | artifact_compact(.) as $art
        | (if (.completion.date // "") != "" then "  (\(.completion.date))" else "" end) as $datestr
        | ("  " + $art + $datestr) as $right
        | ($cols - 2 - ($right | length)) as $tw
        | "L\t  " + fit(.title; ([$tw, 1] | max)) + $right
      ]) as $landed_lines |

    # --- assemble frame, then fit every line to the terminal width -----------
    ([ "H\t⚓ THE BRIDGE    running \($running_lines | length) · held \($hold_lines | length) · needs-you \($needs_lines | length)    \($clock)    ⟳ \($interval)s",
       "P\t",
       "N\tNEEDS YOU" ]
     + (if ($needs_lines | length) == 0 then ["D\t  (nothing waiting on you)"] else $needs_lines end)
     + [ "P\t", "R\tRUNNING" ]
     + (if ($running_lines | length) == 0 then ["D\t  (no live crew)"] else $running_lines end)
     + [ "P\t", "W\tWAITING / HELD" ]
     + (if ($waiting_lines | length) == 0 then ["D\t  (nothing waiting)"] else $waiting_lines end)
     + [ "P\t", "L\tLANDED" ]
     + (if ($landed_lines | length) == 0 then ["D\t  (nothing landed yet)"] else $landed_lines end)
     + [ "P\t", "D\t  [m]erge  [p]eek  [d]etail  (read-only in v1; keys are a v2 follow-up)" ])
    | .[]
    | (capture("^(?<c>[^\t]*)\t(?<t>.*)$") // {c: "P", t: ""}) as $m
    | "\($m.c)\t\(fit($m.t; $cols))"
  '
}

render_frame() {
  local code text
  while IFS=$'\t' read -r code text; do
    if [ "$USE_COLOR" = 1 ]; then
      printf '%s%s%s\n' "$(color_for "$code")" "$text" "$C_RESET"
    else
      printf '%s\n' "$text"
    fi
  done
}

term_cols() {
  local c=${COLUMNS:-}
  case "$c" in ''|*[!0-9]*) c=$(tput cols 2>/dev/null || true) ;; esac
  case "$c" in ''|*[!0-9]*) c=100 ;; esac
  [ "$c" -gt 0 ] 2>/dev/null || c=100
  printf '%s' "$c"
}

if [ "$ONCE" = 1 ]; then
  build_frame "$(date +%H:%M:%S)" "$(term_cols)" | render_frame
  exit 0
fi

cleanup() { printf '\033[?25h'; }  # restore cursor on exit
trap 'cleanup; exit 0' INT TERM
[ "$USE_COLOR" = 1 ] && printf '\033[?25l'  # hide cursor during the loop
while :; do
  frame=$(build_frame "$(date +%H:%M:%S)" "$(term_cols)")
  printf '\033[H\033[2J'          # home + clear
  printf '%s\n' "$frame" | render_frame
  sleep "$INTERVAL"
done
