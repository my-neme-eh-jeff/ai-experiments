#!/bin/bash
# Shared helpers for "repos this session touched".
#
# The touched set is built from what THIS session actually does, recorded by the
# PostToolUse hook (touch-record.sh), not by diffing git state, which cannot tell
# "I changed this repo" from "another of my sessions changed it".
#
# Sourced by: touch-record.sh (record), statusline.sh (read).
# State:      $TL_STATE_DIR/touched-<sid>.txt   one line per touch:  repo<US>branch<US>epoch<US>toplevel<US>commondir
#
# bash 3.2 compatible (the macOS /bin/bash).

# The folder your repos live in, one level deep: ~/code/<repo>. Only repos directly under it are tracked.
TL_SCAN_DIR="${CLAUDE_STATUSLINE_CODE_DIR:-$HOME/code}"
TL_SCAN_DIR="${TL_SCAN_DIR%/}"
TL_STATE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline"
TL_US=$'\x1f'            # field separator (bash read collapses runs of whitespace, so not tab)
TL_BRANCH_TTL=90         # re-resolve a repo's branch at most this often (seconds)
# Path suffix below $HOME, so the absolute, "$HOME/..." and "~/..." spellings of a repo
# path all share it (e.g. "/code"). Falls back to the full dir if not under $HOME.
case "$TL_SCAN_DIR" in
  "$HOME"/*) TL_SUFFIX="${TL_SCAN_DIR#"$HOME"}" ;;
  *) TL_SUFFIX="$TL_SCAN_DIR" ;;
esac

tl_touched_file() { printf '%s/touched-%s.txt' "$TL_STATE_DIR" "$1"; }

# Map an absolute path to the repo under TL_SCAN_DIR that contains it (else nothing).
tl_repo_for_path() {
  local p="$1" rest name
  case "$p" in
    "$TL_SCAN_DIR"/*)
      rest="${p#"$TL_SCAN_DIR"/}"; name="${rest%%/*}"
      case "$name" in ""|.*) return 0 ;; esac          # ".", "..", ".claude" and other dot-dirs are not repos
      [ -d "$TL_SCAN_DIR/$name" ] && printf '%s\n' "$name" ;;
  esac
}

# Resolve a shell token (a cd / git -C target) to "repo<US>abs_path": absolute, ~/… , $HOME/… , or a
# bare repo name relative to TL_SCAN_DIR. Anything that isn't inside a real repo dir is dropped.
tl_resolve_token() {
  local t="$1" r
  t="${t%\"}"; t="${t#\"}"; t="${t%\'}"; t="${t#\'}"
  # shellcheck disable=SC2088,SC2016  # matching the literal "~/" and "$HOME/" spellings is the point
  case "$t" in
    "~/"*)      t="$HOME/${t#\~/}" ;;
    '$HOME/'*)  t="$HOME/${t#\$HOME/}" ;;
  esac
  case "$t" in
    /*)   r=$(tl_repo_for_path "$t"); [ -n "$r" ] && printf '%s%s%s\n' "$r" "$TL_US" "$t" ;;
    */*)  : ;;                                                        # relative path outside our tree
    "")   : ;;
    .*)   : ;;                                                        # dot-entry, not a repo
    *)    [ -d "$TL_SCAN_DIR/$t" ] && printf '%s%s%s\n' "$t" "$TL_US" "$TL_SCAN_DIR/$t" ;;   # bare repo name
  esac
}

# Emit "repo<US>abs_path" for every repo reference in a bash command (dupes ok; caller filters).
tl_repos_in_command() {
  local cmd="$1" m full r
  # Any path under the scan tree (…<suffix>/<repo>[/deeper]), catching /Users/…, $HOME/… and ~/… forms.
  printf '%s\n' "$cmd" | grep -oE "${TL_SUFFIX}/[A-Za-z0-9._-]+(/[^[:space:]'\"\\\`;&|<>()]*)?" 2>/dev/null \
    | while IFS= read -r m; do
        case "$TL_SUFFIX" in "$TL_SCAN_DIR") full="$m" ;; *) full="$HOME$m" ;; esac
        r=$(tl_repo_for_path "$full"); [ -n "$r" ] && printf '%s%s%s\n' "$r" "$TL_US" "$full"
      done
  # cd / pushd / git -C targets: the only place a bare repo name (api, web, infra) is counted.
  printf '%s\n' "$cmd" \
    | grep -oE "(cd|pushd|git +-C) +('[^']*'|\"[^\"]*\"|[^ ;&|<>]+)" 2>/dev/null \
    | sed -E 's/^(cd|pushd|git +-C) +//' \
    | while IFS= read -r tok; do tl_resolve_token "$tok"; done
}

# Record that session $1 touched repo $2 at path $3 (file or dir; defaults to the repo root).
# toplevel identifies the checkout (main repo or a linked worktree); commondir is shared by all
# worktrees of one repository, which is what lets the statusline tell "same checkout" (collision)
# from "separate worktree" (fine).
# Append-only: parallel tool calls can fire two recorders at once; readers dedup, newest wins.
# One git call, and only when the repo is new, its last line is older than TL_BRANCH_TTL, or the
# path is in a different checkout than the last line recorded.
tl_record() {
  local sid="$1" repo="$2" path="${3:-}" dir f now br top common last ep ltop rp
  [ -n "$sid" ] && [ -n "$repo" ] || return 0
  [ -d "$TL_STATE_DIR" ] || mkdir -p "$TL_STATE_DIR" 2>/dev/null
  dir="$path"
  [ -n "$dir" ] && [ ! -d "$dir" ] && dir="${dir%/*}"
  [ -n "$dir" ] && [ -d "$dir" ] || dir="$TL_SCAN_DIR/$repo"
  f=$(tl_touched_file "$sid"); now=$(date +%s)
  if [ -f "$f" ]; then
    last=$(awk -F"$TL_US" -v r="$repo" '$1==r{l=$0} END{print l}' "$f" 2>/dev/null)
    if [ -n "$last" ]; then
      IFS="$TL_US" read -r _ _ ep ltop _ <<EOF
$last
EOF
      [[ $ep =~ ^[0-9]+$ ]] || ep=0
      if [ $(( now - ep )) -lt "$TL_BRANCH_TTL" ] && [ -n "$ltop" ]; then
        case "$dir/" in
          "$ltop"/*) case "$dir" in *"/.claude/worktrees/"*) : ;; *) return 0 ;; esac ;;
        esac
      fi
    fi
  fi
  if rp=$(git -C "$dir" --no-optional-locks rev-parse --abbrev-ref HEAD --show-toplevel --git-common-dir 2>/dev/null); then
    br="${rp%%$'\n'*}"; rp="${rp#*$'\n'}"; top="${rp%%$'\n'*}"; common="${rp#*$'\n'}"
    [ "$br" = "HEAD" ] && br="detached"
    case "$common" in /*) ;; *) common="$top/$common" ;; esac
    common="${common%/}"
  else
    return 0                      # not a git checkout at all: don't record it as a touched repo
  fi
  [ -n "$br" ] || br="detached"
  printf '%s%s%s%s%s%s%s%s%s\n' "$repo" "$TL_US" "$br" "$TL_US" "$now" "$TL_US" "$top" "$TL_US" "$common" >> "$f"
}

# Drop per-session state older than 14 days. At most once a day, from the async hook, never the render path.
tl_cleanup() {
  [ -d "$TL_STATE_DIR" ] || return 0
  local stamp="$TL_STATE_DIR/.last-cleanup"
  [ -n "$(find "$stamp" -mtime -1 2>/dev/null)" ] && return 0
  : > "$stamp" 2>/dev/null
  find "$TL_STATE_DIR" -type f \( -name 'touched-*.txt' -o -name 'alive-*.txt' -o -name 'title-*.last' \) \
    -mtime +14 -delete 2>/dev/null
}
