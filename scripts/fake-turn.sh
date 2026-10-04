#!/usr/bin/env bash
# Pretends to be Claude Code (or Codex) so you can watch the island without a real agent.
#   ./scripts/fake-turn.sh            # Claude turn, ~8s
#   ./scripts/fake-turn.sh codex 20   # Codex turn, ~20s
set -euo pipefail
AGENT="${1:-claude}"
SECONDS_TOTAL="${2:-8}"
URL="http://127.0.0.1:47823/hook"
SID="fake-$RANDOM"
CWD="$PWD"

claude() { curl -s -m 1 --noproxy '*' -X POST --data-binary "$1" "$URL/claude?term=${TERM_PROGRAM:-}" >/dev/null; }

if [[ "$AGENT" == "claude" ]]; then
  claude "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"$SID\",\"cwd\":\"$CWD\"}"
  for ((i = 0; i < SECONDS_TOTAL * 2; i++)); do
    sleep 0.5
    claude "{\"hook_event_name\":\"PreToolUse\",\"session_id\":\"$SID\",\"cwd\":\"$CWD\",\"tool_name\":\"Bash\"}"
  done
  claude "{\"hook_event_name\":\"Stop\",\"session_id\":\"$SID\",\"cwd\":\"$CWD\",\"last_assistant_message\":\"All done: the fake turn finished.\"}"
else
  # Codex has no start hook (Turbo watches its session files for that), so this only shows the finish.
  sleep "$SECONDS_TOTAL"
  curl -s -m 1 --noproxy '*' -X POST --data-binary "{\"type\":\"agent-turn-complete\",\"thread-id\":\"$SID\",\"cwd\":\"$CWD\",\"last-assistant-message\":\"Fake Codex turn complete.\"}" "$URL/codex" >/dev/null
fi
echo "sent"
