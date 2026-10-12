#!/bin/bash
# Renders the statusline against made-up sessions, so screenshots never show a real cluster,
# account or repo. Everything lives in a throwaway HOME; nothing under your real HOME is read or written.
#
#   bash demo/render.sh [calm|heating|wall]     (default: all three)

set -eu
ROOT="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
FAKE="$(mktemp -d)"; trap 'rm -rf "$FAKE"' EXIT
NOW=$(date +%s)
US=$'\x1f'

mkdir -p "$FAKE/.kube" "$FAKE/.aws/sso/cache" "$FAKE/.cache/claude-statusline" "$FAKE/code"
for r in api web infra; do mkdir -p "$FAKE/code/$r"; done
mkdir -p "$FAKE/code/api/.claude/worktrees/fix-retries"
printf 'current-context: arn:aws:eks:us-east-1:000000000000:cluster/staging\n' > "$FAKE/.kube/config"
printf '[profile demo]\nsso_session = demo\nsso_account_id = 000000000000\nsso_role_name = ReadOnly\n' > "$FAKE/.aws/config"
KEY=$(printf 'demo' | shasum | cut -d' ' -f1)
printf '{"expiresAt":"%s"}\n' "$(date -u -r $((NOW + 3600)) +%Y-%m-%dT%H:%M:%SZ)" > "$FAKE/.aws/sso/cache/$KEY.json"

S="$FAKE/.cache/claude-statusline"
C="$FAKE/code"
row() { printf '%s%s%s%s%s%s%s%s%s\n' "$1" "$US" "$2" "$US" "$3" "$US" "$4" "$US" "$5"; }

payload() { # sid name ctx% cost five_pct five_left wk_pct wk_left cold
  cat <<EOF
{"session_id":"$1","session_name":"$2","model":{"id":"claude-opus-5-5[1m]","display_name":"Opus 5.5"},
 "effort":{"level":"high"},"context_window":{"context_window_size":1000000,"used_percentage":$3},
 "cost":{"total_cost_usd":$4},
 "rate_limits":{"five_hour":{"used_percentage":$5,"resets_at":$((NOW + $6))},
                "seven_day":{"used_percentage":$7,"resets_at":$((NOW + $8))}},
 "prompt_cache":{"caching_observed":true,"warm":$9}}
EOF
}

run() { # sid payload   (pre-seeds the tab-title cache so a demo never retitles your terminal tab)
  printf '%s\n' "$(printf '%s' "$2" | jq -r '.session_name')" > "$S/title-$1.last"
  printf '%s' "$2" | env -i HOME="$FAKE" PATH="$PATH" LANG="${LANG:-en_US.UTF-8}" COLUMNS="${COLUMNS:-104}" \
    KUBECONFIG="$FAKE/.kube/config" AWS_PROFILE=demo CLAUDE_STATUSLINE_CODE_DIR="$C" \
    bash "$ROOT/statusline.sh" 2>/dev/null
}

scenario() {
  rm -f "$S"/touched-*.txt "$S"/alive-*.txt
  case "$1" in
    calm)
      row web main $((NOW - 60)) "$C/web" "$C/web/.git" > "$S/touched-me.txt"
      run me "$(payload me 'tidy the login form' 18 0.84 31 9000 22 400000 true)" ;;
    heating)
      { row api fix-retries $((NOW - 30)) "$C/api/.claude/worktrees/fix-retries" "$C/api/.git"
        row infra main $((NOW - 400)) "$C/infra" "$C/infra/.git"
        row web main $((NOW - 900)) "$C/web" "$C/web/.git"; } > "$S/touched-me.txt"
      row api main $((NOW - 120)) "$C/api" "$C/api/.git" > "$S/touched-other.txt"
      row infra main $((NOW - 200)) "$C/infra" "$C/infra/.git" >> "$S/touched-other.txt"
      echo "$NOW" > "$S/alive-other.txt"
      run me "$(payload me 'api retry budget' 64 6.42 72 7800 55 259200 true)" ;;
    wall)
      row api fix-retries $((NOW - 30)) "$C/api/.claude/worktrees/fix-retries" "$C/api/.git" > "$S/touched-me.txt"
      run me "$(payload me 'api retry budget' 91 11.07 100 2280 58 180000 false)" ;;
  esac
}

for s in ${1:-calm heating wall}; do
  [ $# -eq 0 ] && printf '\n\033[2m# %s\033[0m\n' "$s"
  scenario "$s"
done
