#!/usr/bin/env bash
set -euo pipefail

input="$(cat)"

session_id="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)"
tool_name="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)"

[[ -n "$session_id" && -n "$tool_name" ]] || exit 0

agent=""
case "$tool_name" in
  *codex-delegate*) agent="codex" ;;
  *gemini-delegate*) agent="gemini" ;;
  *) exit 0 ;;
esac

response="$(printf '%s' "$input" | jq -r '.tool_response | tostring' 2>/dev/null || true)"
chars=${#response}
# token estimate ~= chars/4, rounded to nearest 10
# round(chars/40) * 10 => ((chars + 20) / 40) * 10
estimate=$(( ((chars + 20) / 40) * 10 ))

log_file="/tmp/conductor-tokens-${session_id}.log"
jq -cn --arg agent "$agent" --argjson tokens "$estimate" '{agent:$agent,tokens:$tokens}' >> "$log_file"

# PostToolUse tracker must stay silent to avoid interfering with tool flow.
exit 0
