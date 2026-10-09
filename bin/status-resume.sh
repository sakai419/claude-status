#!/bin/bash
# Claude Code の PostToolUse hook から呼ばれ、status=waiting / subagent の
# セッションを running に戻す。
#   - waiting : 許可プロンプトや AskUserQuestion にユーザーが応答して
#               ツールが実行された = もう待っていない、という判定。
#
# subagent（サブエージェント完了待ち）はここでは扱わない。サブエージェントは
# 非同期に走り、親スレッドはその間も並行してツールを実行するため、
# 「親がツールを叩いた = サブ待ちが解消した」とは言えない。
# subagent への出入りは Stop hook と status-subagent.sh が担当する。
#
# 全ツール呼び出しごとに走るため、まず sessions/*.json を grep して
# waiting が1件も無ければ jq を起動せずに抜ける（通常はここで終わる）。
set -uo pipefail

JQ=/opt/homebrew/bin/jq
BIN="$(cd "$(dirname "$0")" && pwd)"
SDIR="$HOME/.claude/status/sessions"
[ -d "$SDIR" ] || exit 0

grep -lq '"status": "waiting"' "$SDIR"/*.json 2>/dev/null || exit 0

input=$(cat)

# サブエージェント内部からのツール実行では agent_id が入る。session_id は親と
# 同じなので、これを除外しないとサブが1回ツールを叩くたびに親の待ち状態が
# running に戻ってしまう。親スレッドからの呼び出しだけを扱う。
agent_id=$(printf '%s' "$input" | "$JQ" -r '.agent_id // ""' 2>/dev/null || echo "")
[ -n "$agent_id" ] && exit 0

session=$(printf '%s' "$input" | "$JQ" -r '.session_id // empty' 2>/dev/null || echo "")
[ -z "$session" ] && exit 0

sfile="$SDIR/$session.json"
[ -f "$sfile" ] || exit 0
[ "$("$JQ" -r '.status // ""' "$sfile" 2>/dev/null || echo "")" = "waiting" ] || exit 0

ts=$(date +"%Y-%m-%d %H:%M:%S")
epoch=$(date +%s)

"$JQ" \
  --arg ts "$ts" \
  --argjson epoch "$epoch" \
  '.status = "running" | .updated_at = $ts | .updated_epoch = $epoch' \
  "$sfile" > "$sfile.tmp.$$" && mv "$sfile.tmp.$$" "$sfile"

"$BIN/claude-status-render.sh" 2>/dev/null || true
exit 0
