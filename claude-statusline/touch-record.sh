#!/bin/bash
# Claude Code PostToolUse hook (async): records which repos THIS session touches.
# Matched to Edit|Write|MultiEdit|NotebookEdit|Bash. Runs async, so it adds no latency to the
# turn; its output is ignored. One jq to parse the payload; a git branch call only when a repo
# is newly touched or its branch is stale (see tl_record). Always exits 0.

. "${BASH_SOURCE[0]%/*}/touched-lib.sh" || exit 0

INPUT=$(cat)

read -r SID TOOL <<EOF
$(printf '%s' "$INPUT" | jq -r '[.session_id // "", .tool_name // ""] | @tsv' 2>/dev/null)
EOF
[ -n "$SID" ] || exit 0

case "$TOOL" in
  Edit|Write|MultiEdit)
    P=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
    R=$(tl_repo_for_path "$P")
    [ -n "$R" ] && tl_record "$SID" "$R" "$P"
    ;;
  NotebookEdit)
    P=$(printf '%s' "$INPUT" | jq -r '.tool_input.notebook_path // .tool_input.file_path // empty' 2>/dev/null)
    R=$(tl_repo_for_path "$P")
    [ -n "$R" ] && tl_record "$SID" "$R" "$P"
    ;;
  Bash)
    CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
    [ -n "$CMD" ] || exit 0
    tl_repos_in_command "$CMD" | sort -u | while IFS="$TL_US" read -r R PTH; do
      [ -n "$R" ] && [ -d "$TL_SCAN_DIR/$R" ] && tl_record "$SID" "$R" "$PTH"
    done
    ;;
esac
tl_cleanup
exit 0
