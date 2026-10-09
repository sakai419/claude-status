#!/bin/bash
# Claude Code の SessionEnd hook から呼ばれ、終了したセッションを
# ステータスから取り除く（該当 JSON を削除して status.md を再生成）。
set -euo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/lib.sh"
SDIR="$HOME/.claude/status/sessions"

input=$(cat)
session=$(printf '%s' "$input" | "$JQ" -r '.session_id // empty')
valid_session_id "$session" && rm -f "$SDIR/$session.json"

"$BIN/claude-status-render.sh" 2>/dev/null || true
exit 0
