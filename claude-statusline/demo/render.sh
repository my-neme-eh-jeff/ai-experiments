#!/bin/bash
# Renders the statusline against made-up sessions, so screenshots never show a real cluster,
# account or repo. Everything lives in a throwaway HOME; nothing under your real HOME is read or written.
#
#   bash demo/render.sh                  calm, heating, wall
#   bash demo/render.sh <scenario>...    any name from the case statement at the bottom
#
# Each scenario prints exactly what the statusline prints, ANSI colours included.

set -eu
ROOT="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
FAKE="$(mktemp -d)"; trap 'rm -rf "$FAKE"' EXIT
NOW=$(date +%s)
US=$'\x1f'
S="$FAKE/.cache/claude-statusline"
C="$FAKE/code"

mkdir -p "$FAKE/.kube" "$FAKE/.aws/sso/cache" "$S" "$C"
for r in api web infra; do mkdir -p "$C/$r"; done
mkdir -p "$C/api/.claude/worktrees/fix-retries"
printf 'current-context: arn:aws:eks:us-east-1:000000000000:cluster/staging\n' > "$FAKE/.kube/config"
printf '[profile demo]\nsso_session = demo\nsso_account_id = 000000000000\nsso_role_name = ReadOnly\n' > "$FAKE/.aws/config"

sso_expires_in() { # seconds from now; negative means it already expired
  local key t
  key=$(printf 'demo' | { shasum 2>/dev/null || sha1sum; } | cut -d' ' -f1)
  t=$((NOW + $1))
  t=$(date -u -r "$t" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$t" +%Y-%m-%dT%H:%M:%SZ)   # BSD, then GNU date
  printf '{"expiresAt":"%s"}\n' "$t" > "$FAKE/.aws/sso/cache/$key.json"
}

row() { printf '%s%s%s%s%s%s%s%s%s\n' "$1" "$US" "$2" "$US" "$3" "$US" "$4" "$US" "$5"; }

payload() { # sid title ctx% cost five_pct five_left wk_pct wk_left cache_warm   (+1s so a tick of drift can't round 38m down to 37m)
  cat <<EOF
{"session_id":"$1","session_name":"$2","model":{"id":"claude-opus-5-5[1m]","display_name":"Opus 5.5"},
 "effort":{"level":"high"},"context_window":{"context_window_size":1000000,"used_percentage":$3},
 "cost":{"total_cost_usd":$4},
 "rate_limits":{"five_hour":{"used_percentage":$5,"resets_at":$((NOW + $6 + 1))},
                "seven_day":{"used_percentage":$7,"resets_at":$((NOW + $8 + 1))}},
 "prompt_cache":{"caching_observed":true,"warm":$9}}
EOF
}

run() { # payload_args...   KUBE=0 hides line 2. Pre-seeds the tab-title cache so a demo never retitles your tab.
  local p kc="$FAKE/.kube/config"
  [ "${KUBE:-1}" = "0" ] && kc="$FAKE/.kube/none"
  p=$(payload "$@")
  printf '%s\n' "$2" > "$S/title-$1.last"
  printf '%s' "$p" | env -i HOME="$FAKE" PATH="$PATH" LANG="${LANG:-en_US.UTF-8}" COLUMNS="${COLUMNS:-100}" \
    KUBECONFIG="$kc" AWS_PROFILE=demo CLAUDE_STATUSLINE_CODE_DIR="$C" \
    bash "$ROOT/statusline.sh" 2>/dev/null
}

# Two live sessions: A works in api's main checkout and in infra; B works in infra (the SAME
# checkout as A, so both see a collision) and in a separate worktree of api (no conflict).
two_sessions() {
  { row api main $((NOW - 60)) "$C/api" "$C/api/.git"
    row infra main $((NOW - 300)) "$C/infra" "$C/infra/.git"; } > "$S/touched-a.txt"
  { row infra main $((NOW - 30)) "$C/infra" "$C/infra/.git"
    row api fix-retries $((NOW - 200)) "$C/api/.claude/worktrees/fix-retries" "$C/api/.git"; } > "$S/touched-b.txt"
  echo "$NOW" > "$S/alive-a.txt"; echo "$NOW" > "$S/alive-b.txt"
}

scenario() {
  rm -f "$S"/touched-*.txt "$S"/alive-*.txt
  sso_expires_in 3600
  case "$1" in
    # The three states of one session, used for the hero image.
    calm)
      row web main $((NOW - 60)) "$C/web" "$C/web/.git" > "$S/touched-me.txt"
      run me 'tidy the login form' 18 0.84 31 9000 22 400000 true ;;
    heating)
      { row api fix-retries $((NOW - 30)) "$C/api/.claude/worktrees/fix-retries" "$C/api/.git"
        row infra main $((NOW - 400)) "$C/infra" "$C/infra/.git"
        row web main $((NOW - 900)) "$C/web" "$C/web/.git"; } > "$S/touched-me.txt"
      row api main $((NOW - 120)) "$C/api" "$C/api/.git" > "$S/touched-other.txt"
      row infra main $((NOW - 200)) "$C/infra" "$C/infra/.git" >> "$S/touched-other.txt"
      echo "$NOW" > "$S/alive-other.txt"
      run me 'api retry budget' 64 6.42 72 7800 55 259200 true ;;
    wall)
      row api fix-retries $((NOW - 30)) "$C/api/.claude/worktrees/fix-retries" "$C/api/.git" > "$S/touched-me.txt"
      run me 'api retry budget' 91 11.07 100 2280 58 180000 false ;;

    # Limits, one rule at a time (line 1 only).
    limit-under)    KUBE=0 run me '' 40 3.10 45 9000 20 400000 true ;;    # 5h 45%: under 60%, nothing
    limit-quiet)    KUBE=0 run me '' 40 3.10 68 1800 20 400000 true ;;    # 5h 68%, resets in 30m: no forecast
    limit-forecast) KUBE=0 run me '' 40 3.10 72 7800 20 400000 true ;;    # 5h 72%, resets in 2h10m: forecast
    limit-wall)     KUBE=0 run me '' 40 3.10 100 2280 20 400000 true ;;   # 5h spent: "!" and time until it lifts
    limit-ranked)   KUBE=0 run me '' 40 3.10 100 2280 83 200000 true ;;   # two chips, the blocking one first

    # Context gradient (line 1 only).
    ctx-*)          KUBE=0 run me '' "${1#ctx-}" 2.40 20 9000 10 400000 true ;;

    # Two sessions sharing one machine.
    session-a)      two_sessions; KUBE=0 run a 'api retry budget' 41 3.80 20 9000 10 400000 true ;;
    session-b)      two_sessions; KUBE=0 run b 'bump providers' 23 1.15 20 9000 10 400000 true ;;

    # Credentials: the AWS part disappears once the SSO token expires.
    sso-valid)      run me '' 40 3.10 20 9000 10 400000 true ;;
    sso-expired)    sso_expires_in -600; run me '' 40 3.10 20 9000 10 400000 true ;;

    *) echo "unknown scenario: $1" >&2; exit 2 ;;
  esac
}

if [ $# -eq 0 ]; then
  for s in calm heating wall; do printf '\n\033[2m# %s\033[0m\n' "$s"; scenario "$s"; done
else
  for s in "$@"; do scenario "$s"; done
fi
