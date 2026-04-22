#!/usr/bin/env bash
set -euo pipefail

input="$(cat)"
session_id="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)"
[[ -n "$session_id" ]] || exit 0

log_file="/tmp/conductor-tokens-${session_id}.log"
[[ -s "$log_file" ]] || exit 0

codex="$(jq -s '[.[] | select(.agent=="codex") | (.tokens // 0)] | add // 0' "$log_file" 2>/dev/null || echo 0)"
gemini="$(jq -s '[.[] | select(.agent=="gemini") | (.tokens // 0)] | add // 0' "$log_file" 2>/dev/null || echo 0)"
total=$((codex + gemini))

fmt_num() {
  local n="$1"
  local s="$n"
  while [[ "$s" =~ ^([0-9]+)([0-9]{3})$ ]]; do
    s="${BASH_REMATCH[1]},${BASH_REMATCH[2]}"
  done
  printf '%s' "$s"
}

msg="📊 tokens — Codex: ~$(fmt_num "$codex") | Gemini: ~$(fmt_num "$gemini") | total: ~$(fmt_num "$total")"

rm -f "$log_file"

# Stop hook: non-blocking JSON output. suppressOutput:false keeps it visible.
jq -cn --arg msg "$msg" '{continue:true,suppressOutput:false,systemMessage:$msg}'
