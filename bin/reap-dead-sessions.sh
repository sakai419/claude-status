#!/bin/bash
# ~/.claude/status/sessions/*.json を舐め、記録された pid が既に死んでいる
# セッション JSON を削除する。status-update.sh / status-session-start.sh から
# 呼ばれる共通処理（元は launchd 経由の session-monitor.sh 専用ロジック）。
# 呼び出し元で set -e が有効な場合に備え、この関数自体は失敗させない。
set -uo pipefail

JQ=/opt/homebrew/bin/jq
BIN="$(cd "$(dirname "$0")" && pwd)"
SDIR="$HOME/.claude/status/sessions"
LOG="$HOME/.claude/status/reap.log"
. "$BIN/lib.sh"
[ -d "$SDIR" ] || exit 0

# 誤削除防止のためのグレース秒数。直近更新から grace 未満のセッションは触らない。
GRACE=60
# pid が空（旧フォーマット / PID推定失敗）で status=completed のセッションは、
# プロセスの生死を直接確認できないため、この秒数を過ぎたら「もう動いていない」
# とみなして削除する（mtime+7 の粗い掃除より早く反映するための保険）。
NO_PID_COMPLETED_GRACE=600

log_reap() {
  printf '%s reap sid=%s pid=%s reason=%s\n' "$(date +%FT%T)" "$1" "$2" "$3" >> "$LOG" 2>/dev/null || true
}

now=$(date +%s)
changed=0

for f in "$SDIR"/*.json; do
  [ -e "$f" ] || continue

  line=$("$JQ" -r '[(.pid // ""), (.updated_epoch // 0), (.status // "")] | @tsv' "$f" 2>/dev/null || echo "")
  [ -z "$line" ] && continue

  pid=$(printf '%s' "$line" | awk -F '\t' '{print $1}')
  updated=$(printf '%s' "$line" | awk -F '\t' '{print $2}')
  status=$(printf '%s' "$line" | awk -F '\t' '{print $3}')

  sid=$(basename "$f" .json)

  if [ -z "$pid" ]; then
    # pid 未記録の旧フォーマット。completed で十分に古いものだけ掃除し、
    # running（生死を判定できない）は mtime+7 の粗い掃除に任せる。
    if [ "$status" = "completed" ] && [ $((now - updated)) -ge "$NO_PID_COMPLETED_GRACE" ]; then
      rm -f "$f"
      changed=1
      log_reap "$sid" "" "no-pid-completed-timeout"
    fi
    continue
  fi

  # 直近更新から GRACE 秒以内はスキップ（プロセス起動途中のレース回避）
  [ $((now - updated)) -lt "$GRACE" ] && continue

  # プロセスが生きており、かつ claude 本体である場合のみ残す
  # （PID 再利用で無関係プロセスに割り当たっていた場合を検出するため comm を確認）
  if is_claude_process "$pid"; then
    continue
  fi

  rm -f "$f"
  changed=1
  log_reap "$sid" "$pid" "dead"
done

# reap.log の肥大化防止（直近500行のみ保持）
if [ -f "$LOG" ]; then
  tail -n 500 "$LOG" > "$LOG.tmp.$$" 2>/dev/null && mv "$LOG.tmp.$$" "$LOG" || rm -f "$LOG.tmp.$$"
fi

if [ "$changed" = "1" ]; then
  "$BIN/claude-status-render.sh" 2>/dev/null || true
fi

exit 0
