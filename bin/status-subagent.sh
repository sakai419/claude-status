#!/bin/bash
# Claude Code の SubagentStart / SubagentStop hook から呼ばれ、
# 走行中のサブエージェント数を subagent_count / subagent_types に記録する。
#
# status は原則ここでは変えない。サブエージェントは非同期に走り、親スレッドは
# その間も並行してツールを実行するため、サブを投げた時点ではまだ「待ち」ではない。
# 「サブの完了だけを待って止まっている」と確定するのはターンが終わる Stop の時点で、
# その判定は status-update.sh が background_tasks を見て行う。
#
# 例外として、最後のサブエージェントが終わったときだけ subagent → running に戻す。
# 親がその通知で起きて処理を続けるため、以降は Stop hook が正しい値に収束させる。
#
# hook 入力の session_id はサブエージェント側でも親セッションの ID なので、
# そのまま親の JSON を更新してよい。
set -uo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/lib.sh"
SDIR="$HOME/.claude/status/sessions"
[ -d "$SDIR" ] || exit 0

input=$(cat)
event=$(printf '%s' "$input" | "$JQ" -r '.hook_event_name // empty' 2>/dev/null || echo "")
session=$(printf '%s' "$input" | "$JQ" -r '.session_id // empty' 2>/dev/null || echo "")
valid_session_id "$session" || exit 0

sfile="$SDIR/$session.json"
# セッション JSON が無い＝まだ UserPromptSubmit を経ていない。ここで作ると
# cwd / pid の無い半端なレコードになるため何もしない。
[ -f "$sfile" ] || exit 0

prev_status=$("$JQ" -r '.status // ""' "$sfile" 2>/dev/null || echo "")
status="$prev_status"

if [ "$event" = "SubagentStart" ]; then
  # SubagentStart に background_tasks は付かないため、加算で数える。
  count=$("$JQ" -r '(.subagent_count // 0) + 1' "$sfile" 2>/dev/null || echo 1)
  prev_types=$("$JQ" -r '.subagent_types // ""' "$sfile" 2>/dev/null || echo "")
  types=$(printf '%s' "$input" | "$JQ" -r --arg prev "$prev_types" '
    [ ($prev | split(", ")[]? | select(. != "")), (.agent_type // empty) ] | unique | join(", ")' 2>/dev/null || echo "")
else
  # SubagentStop の background_tasks には、いま終わったサブエージェント自身が
  # status:"running" のまま残る（id が agent_id と一致する）。実測で確認済みのため
  # 自分自身を除いて残数を数える。
  agent_id=$(printf '%s' "$input" | "$JQ" -r '.agent_id // ""' 2>/dev/null || echo "")
  count=$(printf '%s' "$input" | "$JQ" -r --arg me "$agent_id" '
    [ .background_tasks[]? | select(.type == "subagent" and .id != $me) ] | length' 2>/dev/null || echo 0)
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  if [ "$count" -gt 0 ]; then
    types=$(printf '%s' "$input" | "$JQ" -r --arg me "$agent_id" '
      [ .background_tasks[]? | select(.type == "subagent" and .id != $me) | .agent_type // empty ] | unique | join(", ")' 2>/dev/null || echo "")
  else
    types=""
    # 全サブエージェントが終わった＝親が起きて処理を続ける。
    # サブ待ちから抜けるときだけ触り、waiting / completed は上書きしない。
    [ "$prev_status" = "subagent" ] && status="running"
  fi
fi

ts=$(date +"%Y-%m-%d %H:%M:%S")
epoch=$(date +%s)

"$JQ" \
  --arg status "$status" \
  --arg ts "$ts" \
  --arg types "$types" \
  --argjson count "$count" \
  --argjson epoch "$epoch" \
  '.status = $status | .updated_at = $ts | .updated_epoch = $epoch | .subagent_count = $count | .subagent_types = $types' \
  "$sfile" > "$sfile.tmp.$$" && mv "$sfile.tmp.$$" "$sfile"

"$BIN/claude-status-render.sh" 2>/dev/null || true
exit 0
