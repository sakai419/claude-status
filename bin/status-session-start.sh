#!/bin/bash
# Claude Code の SessionStart hook から呼ばれ、同じ claude プロセス（同 PID）配下に
# 残っている別 session_id の JSON を掃除する。
# /clear や /resume、SessionEnd 発火漏れ・クラッシュ後の再起動などで、
# 同一プロセスに紐づく古いセッションが残り続けるのを防ぐのが目的。
set -euo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/lib.sh"
SDIR="$HOME/.claude/status/sessions"
[ -d "$SDIR" ] || exit 0

input=$(cat)
session=$(printf '%s' "$input" | "$JQ" -r '.session_id // empty')
[ -z "$session" ] && exit 0

# PID が既に死んでいるセッション（OS再起動後の初回起動など）を掃除。
"$BIN/reap-dead-sessions.sh" 2>/dev/null || true

# このセッションを動かしている claude プロセスの PID を特定する（status-update.sh と共通）
pid=$(find_claude_pid || true)

# PID が特定できなければ何もしない（誤削除防止）
[ -z "$pid" ] && exit 0

changed=0
for f in "$SDIR"/*.json; do
  [ -e "$f" ] || continue

  line=$("$JQ" -r '[(.session_id // ""), (.pid // "")] | @tsv' "$f" 2>/dev/null || echo "")
  [ -z "$line" ] && continue

  sid=$(printf '%s' "$line" | awk -F '\t' '{print $1}')
  spid=$(printf '%s' "$line" | awk -F '\t' '{print $2}')

  # 自セッションはスキップ
  [ "$sid" = "$session" ] && continue
  # PID 未記録の旧フォーマットは触らない
  [ -z "$spid" ] && continue
  # 同 PID のものだけを掃除対象にする
  [ "$spid" = "$pid" ] || continue

  rm -f "$f"
  changed=1
done

if [ "$changed" = "1" ]; then
  "$BIN/claude-status-render.sh" 2>/dev/null || true
fi

# /resume（claude --resume / -c 含む）で復帰したセッションは、次のプロンプト送信を
# 待たずにこの時点で登録する。status-update.sh は SessionStart を Stop と同じ扱いで
# 処理するため、status=completed・直近の発話は transcript から復元される。
# startup / clear / compact は対象外（compact は実行中に発火するため状態を潰してしまう）。
source=$(printf '%s' "$input" | "$JQ" -r '.source // empty')
if [ "$source" = "resume" ]; then
  printf '%s' "$input" | "$BIN/status-update.sh" 2>/dev/null || true
fi

exit 0
