#!/bin/bash
# Claude Code statusline
# Line 1: model (context, effort) | context% (gradient) | cost | what can stop you | cache   ...   session title
# Line 2: kube context + AWS profile (only when a kube context is set)
# Line 3+: repos this session touched:  ⎇ repo(branch)   (capped at MAX_REPOS)
#
# The render path is ONE exec (jq) plus bash builtins. The touched list is built by the
# PostToolUse hook, so line 3 is just a file read: no git, no network, so the script always
# finishes well inside the refresh interval and never gets cancelled.
#
# bash 3.2 compatible (the macOS /bin/bash).

HERE="${BASH_SOURCE[0]%/*}"; [ "$HERE" = "${BASH_SOURCE[0]}" ] && HERE=.
. "$HERE/touched-lib.sh" 2>/dev/null

MAX_REPOS=8
# Fields are joined with the ASCII unit separator, not tabs: bash `read` treats tab as
# whitespace and collapses runs of it, so an empty field would shift every later field.
US=$'\x1f'

IFS= read -r -d '' INPUT

SESSION_ID=""
if [[ $INPUT =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
  SESSION_ID="${BASH_REMATCH[1]}"
fi

[ -n "${TL_STATE_DIR:-}" ] && [ ! -d "$TL_STATE_DIR" ] && mkdir -p "$TL_STATE_DIR" 2>/dev/null

# CLAUDE_STATUSLINE_DEBUG=1 keeps one sample payload per session, for discovering fields. Written
# once, not every tick: every write is a filesystem event fanned out to Spotlight, endpoint security
# and every file watcher on the box, and this script runs in every open session.
[ "${CLAUDE_STATUSLINE_DEBUG:-}" = "1" ] && [ -n "$SESSION_ID" ] && [ -d "$TL_STATE_DIR" ] \
  && [ ! -s "$TL_STATE_DIR/payload-$SESSION_ID.json" ] \
  && printf '%s' "$INPUT" > "$TL_STATE_DIR/payload-$SESSION_ID.json" 2>/dev/null

KUBEF=/dev/null; KCFG="${KUBECONFIG%%:*}"; KCFG="${KCFG:-$HOME/.kube/config}"; [ -f "$KCFG" ] && KUBEF="$KCFG"
AWSF=/dev/null;  [ -f "$HOME/.aws/config" ] && AWSF="$HOME/.aws/config"
SETF=/dev/null;  [ -f "$HOME/.claude/settings.json" ] && SETF="$HOME/.claude/settings.json"

# Touched-repo lists: mine, plus every other session's lines prefixed "sid<US>alive_epoch<US>…" so jq
# can spot two live sessions in the same checkout. alive-<sid>.txt is rewritten by each tick below.
MINEF=/dev/null; OTHERS=""
if [ -n "$SESSION_ID" ] && [ -d "$TL_STATE_DIR" ]; then
  [ -s "$TL_STATE_DIR/touched-$SESSION_ID.txt" ] && MINEF="$TL_STATE_DIR/touched-$SESSION_ID.txt"
  for OF in "$TL_STATE_DIR"/touched-*.txt; do
    [ -f "$OF" ] || continue
    OSID="${OF##*/touched-}"; OSID="${OSID%.txt}"
    [ "$OSID" = "$SESSION_ID" ] && continue
    AL=0; [ -f "$TL_STATE_DIR/alive-$OSID.txt" ] && IFS= read -r AL < "$TL_STATE_DIR/alive-$OSID.txt"
    while IFS= read -r L || [ -n "$L" ]; do [ -n "$L" ] && OTHERS="$OTHERS$OSID$US$AL$US$L"$'\n'; done < "$OF"
  done
fi

# AWS SSO token cache for the active profile's sso_session: ~/.aws/sso/cache/<sha1(session)>.json.
# jq reads only its expiresAt. The sha1 costs an exec, so it is computed once per session name and cached.
SSOF=/dev/null
if [ -n "${AWS_PROFILE:-}" ] && [ "$AWSF" != /dev/null ]; then
  SSO_SESSION=""
  while IFS= read -r L; do
    case "$L" in
      "[profile ${AWS_PROFILE}]"*) IN=1 ;;
      "["*) IN="" ;;
      *sso_session*) [ -n "${IN:-}" ] && { SSO_SESSION="${L#*=}"; SSO_SESSION="${SSO_SESSION// /}"; } ;;
    esac
  done < "$AWSF"
  if [ -n "$SSO_SESSION" ] && [ -d "${TL_STATE_DIR:-}" ]; then
    KEYF="$TL_STATE_DIR/sso-key-$SSO_SESSION.txt"; KEY=""
    [ -f "$KEYF" ] && IFS= read -r KEY < "$KEYF"
    if [ -z "$KEY" ]; then KEY=$(printf '%s' "$SSO_SESSION" | shasum 2>/dev/null | cut -d' ' -f1); [ -n "$KEY" ] && printf '%s\n' "$KEY" > "$KEYF" 2>/dev/null; fi
    [ -n "$KEY" ] && [ -f "$HOME/.aws/sso/cache/$KEY.json" ] && SSOF="$HOME/.aws/sso/cache/$KEY.json"
  fi
fi

# shellcheck disable=SC2016  # jq variables, not shell ones
JQ_PROG='
def lines(s): (s // "") | split("\n") | map(select(length > 0));
def rows(s): [ lines(s)[] | split($us) | select(length >= 3) ];
def aws_field(text; prof; key):
  ((text // "") | split("\n") | map(gsub("^\\s+|\\s+$"; ""))) as $L
  | ($L | index("[profile " + prof + "]")) as $i
  | if $i == null then ""
    else ($L[$i+1:]) as $rest
      | ($rest | map(startswith("[")) | index(true)) as $j
      | (if $j == null then $rest else $rest[:$j] end)
      | [ .[] | select(startswith(key)) | split("=") | .[1:] | join("=") | gsub("^\\s+|\\s+$"; "") ] | (first // "")
    end;
# seconds -> "3h05m" / "40m" / "2d4h"
def dur: floor | if . >= 86400 then "\(. / 86400 | floor)d\((. % 86400) / 3600 | floor)h"
                 elif . >= 3600 then "\(. / 3600 | floor)h\((. % 3600) / 60 | floor | tostring | if length < 2 then "0" + . else . end)m"
                 else "\(. / 60 | floor)m" end;
# Shorten well-known kube context names; anything unrecognised is shown as-is. Add your own here.
def kube_alias:
  if test("^arn:aws:eks:") then ((split("/") | last) + " (eks)")
  elif test("^gke_") then ((split("_") | last) + " (gke)")
  else . end;

(now | floor) as $now
| ((.model.display_name // "Claude") | sub(" *\\(.*$"; "")) as $model
| (if ((.model.id // "") | test("1m"; "i")) or ((.context_window.context_window_size // 0) >= 900000) then "1M" else "" end) as $ctx
| (.effort.level // (($settings | fromjson?) // {} | .effortLevel) // "") as $effort
| ((.context_window.used_percentage // 0) | round) as $pct
| (((.cost.total_cost_usd // 0) * 100) | round) as $cents
| ((lines($kube) | map(select(startswith("current-context:"))) | first // "")
     | ltrimstr("current-context:") | gsub("^\\s+|\\s+$"; "") | ltrimstr("\"") | rtrimstr("\"") | kube_alias) as $kctx
| (if $ssof == "" then "" else
     (($ssof | fromjson?) // {} | .expiresAt // "") as $exp
     | (if $exp == "" then "0" else (if (($exp | sub("\\.[0-9]+"; "") | fromdateiso8601? // 0) > $now) then "1" else "0" end) end)
   end) as $sso_ok
| (if $aws_profile == "" then ["", ""]
   else [aws_field($aws; $aws_profile; "sso_account_id"), aws_field($aws; $aws_profile; "sso_role_name")] end) as $awsf
# What can stop you: the plan windows Claude Code reports in .rate_limits. Nothing under 60% earns
# space. Pace is stateless: the average burn since the window opened, extrapolated, and kept only
# when it reaches 100% BEFORE the window resets (if the reset comes first there is nothing to say).
# Ranked: blocking first, then whatever runs out soonest, then the fullest. At most two.
| (.rate_limits // {}) as $rl
| ([ [ {k: "five_hour", name: "5h", len: 18000}, {k: "seven_day", name: "wk", len: 604800} ][]
     | . as $w | ($rl[$w.k] // {}) as $r
     | select($r.used_percentage != null)
     | ($r.used_percentage | round) as $p
     | select($p >= 60)
     | (if ($r.resets_at // 0) > 0 then (($r.resets_at - $now) | floor) else 0 end) as $left
     | ($w.len - $left) as $spent
     | (if $p >= 100 or $left <= 0 or $spent <= 0 then 0 else ((100 - $p) * $spent / $p | floor) end) as $eta
     | { pct: $p, inn: (if $left > 0 then $left else 0 end), act: ($p >= 100),
         eta: (if $eta > 0 and $eta < $left then $eta else 0 end),
         txt: ($w.name + " " + ($p | tostring) + "%") }
     | .etal = (if .eta > 0 then "→ 100% in " + (.eta | dur) else "" end) ]
   | sort_by([(if .act then 0 else 1 end), (if .eta > 0 then .eta else 1e12 end), -.pct]) | .[0:2]) as $chips
| ((($chips[0] // {}) | [ (.txt // ""), ((.pct // 0) | tostring), ((.inn // 0) | tostring), (if .act then "1" else "0" end), (.etal // "") ])
   + (($chips[1] // {}) | [ (.txt // ""), ((.pct // 0) | tostring), ((.inn // 0) | tostring), (if .act then "1" else "0" end), (.etal // "") ])) as $ch
| (if (.prompt_cache.caching_observed == true) and (.prompt_cache.warm == false) then "1" else "0" end) as $cold
# My touched repos, newest first, one entry per checkout (a worktree is its own entry).
| (rows($mine) | map({repo: .[0], br: .[1], ep: ((.[2] | tonumber?) // 0), top: (.[3] // ""), common: (.[4] // "")})
   | sort_by(-.ep) | unique_by(if .top != "" then .top else .repo end) | sort_by(-.ep)) as $M
# Other sessions: only ones whose statusline ticked in the last 2 min, lines touched in the last 4 h.
| (rows($others) | map(select(length >= 5)
     | {sid: .[0], alive: ((.[1] | tonumber?) // 0), repo: .[2], br: .[3], ep: ((.[4] | tonumber?) // 0),
        top: (.[5] // ""), common: (.[6] // "")})
   | map(select(($now - .alive) <= 120 and ($now - .ep) <= 14400))) as $O
| ( [ (.session_name // ""), $model, $ctx, ($effort | tostring), ($pct | tostring), ($cents | tostring),
      $kctx, $awsf[0], $awsf[1], $cold, $sso_ok, ($now | tostring),
      $ch[0], $ch[1], $ch[2], $ch[3], $ch[4], $ch[5], $ch[6], $ch[7], $ch[8], $ch[9] ]
    | map(gsub("[\\n\\t]"; " ")) | join($us) ),
  ( $M[] | . as $m
    | ([ $O[] | select($m.top != "" and .top == $m.top) | .sid ] | unique) as $coll
    | ([ $O[] | select($m.common != "" and .common == $m.common and .top != $m.top) ]) as $wt
    | (if ($coll | length) > 0 then "collide" elif ($wt | length) > 0 then "worktree" else "" end) as $flag
    | (if $flag == "collide" then ($coll | length | tostring) elif $flag == "worktree" then ($wt[0].br // "") else "" end) as $detail
    | (if ($m.top != "" and $m.top != ($scan + "/" + $m.repo)) then "1" else "0" end) as $ownwt
    | ["T", $m.repo, $m.br, $flag, $detail, $ownwt] | join($us) )
'

OUT=$(jq -r --rawfile kube "$KUBEF" --rawfile aws "$AWSF" --rawfile settings "$SETF" --rawfile ssof "$SSOF" \
         --rawfile mine "$MINEF" --arg others "$OTHERS" --arg scan "${TL_SCAN_DIR:-}" \
         --arg aws_profile "${AWS_PROFILE:-}" --arg us "$US" "$JQ_PROG" <<< "$INPUT" 2>/dev/null)

SESSION_NAME=""; BASE_MODEL="Claude"; CTX_TAG=""; EFFORT=""; PCT=0; CENTS=0
KUBE_CTX=""; AWS_ACCT=""; AWS_ROLE=""; COLD=0; SSO_OK=""; NOW=0
C1=""; C1P=""; C1I=""; C1A=""; C1E=""; C2=""; C2P=""; C2I=""; C2A=""; C2E=""
T_REPO=(); T_BR=(); T_FLAG=(); T_DETAIL=(); T_OWNWT=()
{
  IFS="$US" read -r SESSION_NAME BASE_MODEL CTX_TAG EFFORT PCT CENTS KUBE_CTX AWS_ACCT AWS_ROLE COLD SSO_OK NOW C1 C1P C1I C1A C1E C2 C2P C2I C2A C2E
  while IFS="$US" read -r TAG TR TB TF TD TW; do
    [ "$TAG" = "T" ] && { T_REPO+=("$TR"); T_BR+=("$TB"); T_FLAG+=("$TF"); T_DETAIL+=("$TD"); T_OWNWT+=("$TW"); }
  done
} <<< "$OUT"
# Liveness marker other sessions use to decide whether this one is still open. Rewritten only
# when it is over 60s old (readers allow 120s), so most ticks cause no filesystem write at all.
if [ -n "$SESSION_ID" ] && [[ $NOW =~ ^[0-9]+$ ]] && [ -d "$TL_STATE_DIR" ]; then
  ALIVE_F="$TL_STATE_DIR/alive-$SESSION_ID.txt"; LAST_ALIVE=0
  [ -f "$ALIVE_F" ] && IFS= read -r LAST_ALIVE < "$ALIVE_F"; [[ $LAST_ALIVE =~ ^[0-9]+$ ]] || LAST_ALIVE=0
  [ $(( NOW - LAST_ALIVE )) -ge 60 ] && printf '%s\n' "$NOW" > "$ALIVE_F" 2>/dev/null
fi
[ -n "$BASE_MODEL" ] || BASE_MODEL="Claude"

BOLD="\033[1;37m"; NORMAL="\033[0;37m"; DIM="\033[0;90m"; GREY="\033[0;90m"
CYAN="\033[0;36m"; YELLOW="\033[0;33m"; RESET="\033[0m"

TITLE="${SESSION_NAME:0:50}"

# Tab title, written to the tty only when it changed (a raw write every tick can garble the TUI).
if [ -n "$SESSION_ID" ] && [ -d "${TL_STATE_DIR:-}" ]; then
  LAST_FILE="$TL_STATE_DIR/title-$SESSION_ID.last"
  LAST=""; [ -f "$LAST_FILE" ] && IFS= read -r LAST < "$LAST_FILE"
  if [ "$TITLE" != "$LAST" ]; then
    if [ -n "$TITLE" ]; then printf '\033]0;cc: %s\007' "$TITLE" 2>/dev/null > /dev/tty
    else printf '\033]0;claude code\007' 2>/dev/null > /dev/tty; fi
    printf '%s\n' "$TITLE" > "$LAST_FILE" 2>/dev/null
  fi
fi

# --- Line 1: model | context% | cost   ...   title ------------------------------------------
PARTS=""
[ -n "$CTX_TAG" ] && PARTS="$CTX_TAG"
[ -n "$CTX_TAG" ] && [ -n "$EFFORT" ] && PARTS="$PARTS, "
[ -n "$EFFORT" ] && PARTS="$PARTS$EFFORT"
MODEL_STR="$BASE_MODEL"; [ -n "$PARTS" ] && MODEL_STR="$BASE_MODEL ($PARTS)"

[[ $PCT =~ ^-?[0-9]+$ ]] || PCT=0
[[ $CENTS =~ ^-?[0-9]+$ ]] || CENTS=0
printf -v COST '%d.%02d' $((CENTS / 100)) $((CENTS % 100))

# Smooth gradient green(0%) -> yellow(50%) -> red(100%); sets GRAD to the escape for $1 percent.
grad_color() {
  local p=$1 R G; [[ $p =~ ^-?[0-9]+$ ]] || p=0
  if [ "$p" -le 50 ]; then R=$(( p * 255 / 50 )); G=255; else R=255; G=$(( (100 - p) * 255 / 50 )); fi
  [ "$R" -gt 255 ] && R=255; [ "$R" -lt 0 ] && R=0
  [ "$G" -gt 255 ] && G=255; [ "$G" -lt 0 ] && G=0
  GRAD="\033[38;2;${R};${G};0m"
}
# Seconds -> "3h58m" / "12m" into the variable named by $1 (empty when <= 0).
fmt_dur() {
  local __v=$1 s=$2; [[ $s =~ ^-?[0-9]+$ ]] || s=0
  if [ "$s" -le 0 ]; then printf -v "$__v" ''
  elif [ "$s" -ge 86400 ]; then printf -v "$__v" '%dd%dh' $((s / 86400)) $(((s % 86400) / 3600))
  elif [ "$s" -ge 3600 ]; then printf -v "$__v" '%dh%02dm' $((s / 3600)) $(((s % 3600) / 60))
  else printf -v "$__v" '%dm' $((s / 60)); fi
}

grad_color "$PCT"; PCT_COLOR="$GRAD"

LINE1="${NORMAL}${MODEL_STR}${RESET} ${DIM}|${RESET} ${PCT_COLOR}🧠 ${PCT}%${RESET} ${DIM}|${RESET} ${NORMAL}\$${COST}${RESET}"
# Plain twin of LINE1 for measuring width: each emoji is two columns, so it is stood in for by "oo".
PLAIN1="$MODEL_STR | oo $PCT% | \$$COST"

# --- What can stop you --------------------------------------------------------------------------
# At most two chips, worst first. A chip at its limit is marked "!".
# A chip heading for the wall before its reset says so: "5h 72% → 100% in 40m ↻2h10m".
RL=""; RLP=""
add_chip() {
  local txt=$1 pct=$2 inn=$3 act=$4 etal=$5 part partp
  [ -n "$txt" ] || return 0
  [[ $pct =~ ^[0-9]+$ ]] || pct=0
  grad_color "$pct"
  part="${GRAD}${txt}${RESET}"; partp="$txt"
  if [ "$act" = "1" ]; then part="${GRAD}${txt} !${RESET}"; partp="$txt !"; fi
  if [ -n "$etal" ]; then part="$part ${GRAD}${etal}${RESET}"; partp="$partp ${etal//→/>}"; fi
  if [[ $inn =~ ^[0-9]+$ ]] && [ "$inn" -gt 0 ]; then
    fmt_dur DC "$inn"; [ -n "$DC" ] && { part="$part ${DIM}↻${DC}${RESET}"; partp="$partp ~$DC"; }
  fi
  [ -n "$RL" ] && { RL="$RL ${DIM}·${RESET} "; RLP="$RLP . "; }
  RL="$RL$part"; RLP="$RLP$partp"
}
add_chip "$C1" "$C1P" "$C1I" "$C1A" "$C1E"
add_chip "$C2" "$C2P" "$C2I" "$C2A" "$C2E"
if [ -n "$RL" ]; then LINE1="$LINE1 ${DIM}|${RESET} 🔋 $RL"; PLAIN1="$PLAIN1 | oo $RLP"; fi
# Prompt cache went cold (idle past its TTL): the next turn pays to rebuild it.
if [ "$COLD" = "1" ]; then LINE1="$LINE1 ${DIM}|${RESET} ${YELLOW}cache cold${RESET}"; PLAIN1="$PLAIN1 | cache cold"; fi

if [ -n "$TITLE" ]; then
  COLS="${COLUMNS:-}"
  [ -n "$COLS" ] || COLS=$(stty size </dev/tty 2>/dev/null | { read -r _ c; printf '%s' "$c"; })
  COLS=${COLS:-80}
  PAD=$(( COLS - ${#PLAIN1} - ${#TITLE} - 5 ))
  if [ "$PAD" -gt 1 ]; then printf '%b%*s%b%s%b\n' "$LINE1" "$PAD" "" "$BOLD" "$TITLE" "$RESET"
  else printf '%b  %b%s%b\n' "$LINE1" "$BOLD" "$TITLE" "$RESET"; fi
else
  printf '%b\n' "$LINE1"
fi

# --- Line 2: kube context + AWS profile -----------------------------------------------------
if [ -n "$KUBE_CTX" ]; then
  LINE2="${CYAN}☸ ${KUBE_CTX}${RESET}"
  # AWS shown only while the profile's SSO token is valid (SSO_OK="" = no token file found: show it anyway).
  if [ -n "${AWS_PROFILE:-}" ] && [ "$SSO_OK" != "0" ]; then
    if [ -n "$AWS_ACCT" ] && [ -n "$AWS_ROLE" ]; then
      LINE2="$LINE2 ${DIM}|${RESET} ${YELLOW}☁ ${AWS_PROFILE} (${AWS_ACCT} · ${AWS_ROLE})${RESET}"
    else
      LINE2="$LINE2 ${DIM}|${RESET} ${YELLOW}☁ ${AWS_PROFILE}${RESET}"
    fi
  fi
  printf '%b\n' "$LINE2"
fi

# --- Line 3+: repos touched this session ----------------------------------------------------
#   ⎇ repo(branch)            touched by this session (newest first)
#   ⎇ repo(branch)·wt         this entry is a linked worktree, not the main checkout
#   … ⚠×N                     N other live sessions are working in the SAME checkout (real collision)
#   … ⑃ other-branch          another live session has this repo in a SEPARATE worktree (no conflict)
TOTAL=${#T_REPO[@]}
if [ "$TOTAL" -gt 0 ]; then
  i=0
  while [ "$i" -lt "$TOTAL" ] && [ "$i" -lt "$MAX_REPOS" ]; do
    L="${GREY}⎇ ${T_REPO[$i]}(${T_BR[$i]})"
    [ "${T_OWNWT[$i]}" = "1" ] && L="${L}·wt"
    case "${T_FLAG[$i]}" in
      collide)  L="$L${RESET} ${YELLOW}⚠×${T_DETAIL[$i]}${RESET}" ;;
      worktree) L="$L ${DIM}⑃ ${T_DETAIL[$i]}${RESET}" ;;
      *)        L="$L${RESET}" ;;
    esac
    printf '%b\n' "$L"
    i=$((i + 1))
  done
  [ "$TOTAL" -gt "$MAX_REPOS" ] && printf '%b  +%d more%b\n' "$GREY" $((TOTAL - MAX_REPOS)) "$RESET"
fi

exit 0
