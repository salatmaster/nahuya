#!/bin/sh
# nahuya pre-push gate (PreToolUse on Bash).
# Exit 0 lets the command run; exit 2 blocks it and stderr goes to Claude.
# Any unexpected failure lets the command run: the gate must never break a session.

NH_ROOT=$(cd "$(dirname "$0")/.." && pwd) || exit 0
. "$NH_ROOT/lib/nahuya.sh" || exit 0

input=$(cat)
case $input in *git*|*gh*) ;; *) exit 0 ;; esac
cmd=$(printf '%s' "$input" | nh_json_str command)
case $cmd in *git*|*gh*) ;; *) exit 0 ;; esac
cwd=$(printf '%s' "$input" | nh_json_str cwd)
[ -n "$cwd" ] || cwd=$PWD

aliases=$(cd "$cwd" 2>/dev/null && git config --get-regexp '^alias\.' 2>/dev/null |
  awk '/push/ { sub(/^alias\./, "", $1); printf "%s ", $1 }')
pushes=$(nh_detect_pushes "$cmd" "$aliases")
[ -n "$pushes" ] || exit 0

# One push target: returns 2 to block (message on stderr), 0 to allow.
gate() (
  nh_enter_repo "$1" || exit 0
  [ "$(nh_cfg gate)" = on ] || exit 0
  nh_resolve_tip "$2" || exit 0
  if [ -f "$NH_STATE/skip" ] && [ "$(cat "$NH_STATE/skip")" = "$NH_TIP" ]; then
    rm -f "$NH_STATE/skip"; exit 0
  fi
  anchor=$(nh_anchor "$NH_TIP" "$NH_BRANCH") || exit 0
  added=$(nh_count_added "$anchor" "$NH_TIP" "$NH_BRANCH")
  threshold=$(nh_cfg threshold)
  [ "${added:-0}" -ge "$threshold" ] 2>/dev/null || exit 0

  # Loop guard: never block the same commit more than 3 times.
  count=0
  if [ -f "$NH_STATE/blocks" ]; then
    read -r sha n < "$NH_STATE/blocks"
    [ "$sha" = "$NH_TIP" ] && count=${n:-0}
  fi
  if [ "$count" -ge 3 ]; then
    rm -f "$NH_STATE/blocks"
    msg="nahuya: letting this push through unreviewed: it was blocked 3 times at $(nh_short "$NH_TIP") without a completed review."
    printf '{"systemMessage":"%s","hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"%s"}}\n' "$msg" "$msg"
    exit 0
  fi
  printf '%s %s\n' "$NH_TIP" "$((count + 1))" > "$NH_STATE/blocks"

  cat >&2 <<EOF
nahuya: push blocked, nothing in this command ran. $added unreviewed added lines of non-test code since $(nh_short "$anchor") (threshold $threshold).
Commit anything the blocked command was going to commit, then run the nahuya:polish skill with no arguments. It re-runs the push when it finishes.
Skipping review is the user's call (/nahuya:skip), so don't work around the gate. If you are a subagent, stop and report this to your caller.
EOF
  exit 2
)

status=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  dir=${line%%"$NH_TAB"*}; tip=${line#*"$NH_TAB"}
  case $dir in
    '') target=$cwd ;;
    /*|[A-Za-z]:*) target=$dir ;;
    *) target=$cwd/$dir ;;
  esac
  gate "$target" "$tip"
  [ $? -eq 2 ] && { status=2; break; }
done <<EOF
$pushes
EOF
exit $status
