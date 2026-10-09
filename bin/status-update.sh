#!/bin/bash
# Claude Code の hook から呼ばれ、セッションごとの機械状態を
# ~/claude-status/sessions/<session_id>.json に記録する。
#   - UserPromptSubmit: 直近プロンプトを記録し status=running
#   - Notification    : notification_type で分岐（プロンプト/意図は保持）
#       応答待ち系（許可プロンプト等） → status=waiting
#       idle_prompt（メインスレッドがアイドル）→ サブが飛んでいれば subagent、
#                                                無ければ waiting
#   - Stop            : background_tasks に走行中のサブエージェントが残っていれば
#                       status=subagent、無ければ completed（プロンプト/意図は保持）
# 既存の通知 hook（stop.sh / notification.sh）とは独立して動く。
set -euo pipefail

JQ=/opt/homebrew/bin/jq
BIN="$(cd "$(dirname "$0")" && pwd)"
SDIR="$HOME/.claude/status/sessions"
. "$BIN/lib.sh"
mkdir -p "$SDIR"

# 保険: SessionEnd が発火しなかったセッション（クラッシュ/強制終了）のゴミを掃除。
# 7日以上更新の無い JSON を削除する。
find "$SDIR" -name '*.json' -type f -mtime +7 -delete 2>/dev/null || true

# PID が既に死んでいるセッション（OS再起動・kill 等で SessionEnd が発火しなかったもの）を掃除。
# UserPromptSubmit / Stop の両方で呼ばれるため、cs を起動していなくても
# Claude Code を使うたびに自然と生存監視が効く。
"$BIN/reap-dead-sessions.sh" 2>/dev/null || true

input=$(cat)

event=$(printf '%s' "$input" | "$JQ" -r '.hook_event_name // empty')
session=$(printf '%s' "$input" | "$JQ" -r '.session_id // empty')
cwd=$(printf '%s' "$input" | "$JQ" -r '.cwd // empty')
tpath=$(printf '%s' "$input" | "$JQ" -r '.transcript_path // empty')
[ -z "$cwd" ] && cwd="$PWD"
[ -z "$session" ] && exit 0

# このセッションを動かしている claude プロセスの PID を特定する。
# 失敗した場合は空文字ではなく既存 JSON の pid を引き継ぐ（探索の一時的失敗で
# 生きているセッションの pid を失い、reap に誤って回収されるのを防ぐ）。
sfile="$SDIR/$session.json"
prev_pid=""
if [ -f "$sfile" ]; then
  prev_pid=$("$JQ" -r '.pid // ""' "$sfile" 2>/dev/null || echo "")
fi
pid=$(find_claude_pid || true)
[ -z "$pid" ] && pid="$prev_pid"

# Notification は用途が複数あるため notification_type で振り分ける。
#   応答待ち系（permission_prompt / worker_permission_prompt / agent_needs_input /
#   elicitation_response）: ユーザーの手当てが必要。サブ待ちより優先して waiting。
#   idle_prompt: メインスレッドがアイドルになっただけ。サブエージェントが飛んでいれば
#   「サブの完了だけを待って止まっている」なので subagent。飛んでいなければ waiting。
#   それ以外（auth_success / agent_completed / computer_use_* 等）: 状態を触らない。
# 既に completed のセッションへの通知で完了表示を上書きしないよう、
# 遷移元は running / subagent に限る。
if [ "$event" = "Notification" ]; then
  prev_status=$("$JQ" -r '.status // ""' "$sfile" 2>/dev/null || echo "")
  case "$prev_status" in
    running|subagent) ;;
    *) exit 0 ;;
  esac
  ntype=$(printf '%s' "$input" | "$JQ" -r '.notification_type // ""' 2>/dev/null || echo "")
  case "$ntype" in
    permission_prompt|worker_permission_prompt|agent_needs_input|elicitation_response)
      notify_status="waiting" ;;
    idle_prompt)
      held=$("$JQ" -r '.subagent_count // 0' "$sfile" 2>/dev/null || echo 0)
      case "$held" in ''|*[!0-9]*) held=0 ;; esac
      if [ "$held" -gt 0 ]; then notify_status="subagent"; else notify_status="waiting"; fi ;;
    *) exit 0 ;;
  esac
fi

subagents=0
sub_types=""
if [ "$event" = "UserPromptSubmit" ]; then
  status="running"
  prompt=$(printf '%s' "$input" | "$JQ" -r '.prompt // ""')
elif [ "$event" = "Notification" ]; then
  # waiting からの復帰は PostToolUse hook（status-resume.sh）が担当する。
  status="$notify_status"
  prompt=""
else
  # Stop など。last_prompt/intent は既存値を維持するため jq 側の update 式に触らせない。
  # background_tasks に走行中のサブエージェントが残っている場合、セッションは
  # 終わったのではなく「サブエージェントの完了待ちで一時停止している」状態。
  # 完了と同じ緑で並ぶと手当て済みに見えてしまうため別状態として記録する。
  subagents=$(printf '%s' "$input" | "$JQ" -r '[.background_tasks[]? | select(.type == "subagent")] | length' 2>/dev/null || echo 0)
  case "$subagents" in ''|*[!0-9]*) subagents=0 ;; esac
  if [ "$subagents" -gt 0 ]; then
    status="subagent"
    sub_types=$(printf '%s' "$input" | "$JQ" -r '[.background_tasks[]? | select(.type == "subagent") | .agent_type // empty] | unique | join(", ")' 2>/dev/null || echo "")
  else
    status="completed"
    sub_types=""
  fi
  prompt=""
  if [ ! -f "$sfile" ] && [ -n "$tpath" ] && [ -f "$tpath" ]; then
    # UserPromptSubmit を経ていない旧セッション向けフォールバック: transcript から直近ユーザー発話を抽出
    prompt=$("$JQ" -rs '
      [ .[]
        | select(.type=="user")
        | .message.content
        | if type=="string" then .
          elif type=="array" then ([ .[] | select(.type=="text") | .text ] | join(""))
          else empty end
        | select(. != null and . != "")
      ] | last // ""' "$tpath" 2>/dev/null || echo "")
  fi
fi

ts=$(date +"%Y-%m-%d %H:%M:%S")
epoch=$(date +%s)

# 既存 JSON に対する部分更新（jq のフィールド代入）で書き込む。
# intent や、Stop 時の last_prompt のように「このイベントが関知しない
# フィールド」を丸ごと再構築しないことで、他の hook（UserPromptSubmit と
# Stop の交錯、claude-intent.sh との交錯）による read-modify-write の
# 上書き競合（lost update）を避ける。
base='{}'
[ -f "$sfile" ] && base=$(cat "$sfile")

filter='.session_id = $sid | .cwd = $cwd | .status = $status | .updated_at = $ts | .updated_epoch = $epoch | .pid = $pid | .intent = (.intent // "") | .transcript_path = (if $tpath != "" then $tpath else (.transcript_path // "") end)'
# サブエージェントの本数を知っているのは background_tasks を持つ Stop だけ。
# 他イベントで代入すると、飛んでいるサブを 0 件に潰してしまうため既存値を保持する。
if [ "$event" = "UserPromptSubmit" ] || [ "$event" = "Notification" ]; then
  filter="$filter"' | .subagent_count = (.subagent_count // 0) | .subagent_types = (.subagent_types // "")'
else
  filter="$filter"' | .subagent_count = $subagents | .subagent_types = $subtypes'
fi
if [ "$event" = "UserPromptSubmit" ]; then
  filter="$filter"' | .last_prompt = $prompt'
elif [ -z "$prompt" ]; then
  filter="$filter"' | .last_prompt = (.last_prompt // "")'
else
  filter="$filter"' | .last_prompt = (.last_prompt // $prompt)'
fi

printf '%s' "$base" | "$JQ" \
  --arg sid "$session" \
  --arg cwd "$cwd" \
  --arg prompt "$prompt" \
  --arg status "$status" \
  --arg ts "$ts" \
  --arg pid "$pid" \
  --arg tpath "$tpath" \
  --arg subtypes "$sub_types" \
  --argjson subagents "$subagents" \
  --argjson epoch "$epoch" \
  "$filter" \
  > "$sfile.tmp.$$" && mv "$sfile.tmp.$$" "$sfile"

"$BIN/claude-status-render.sh" 2>/dev/null || true
exit 0
