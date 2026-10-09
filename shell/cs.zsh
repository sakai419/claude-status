# Claude Code ステータス・ハンドオフ（.zshrc から source する）
# この repo の bin/ を指す。source されたファイル自身の位置から求める。
CLAUDE_STATUS_BIN="${${(%):-%x}:A:h:h}/bin"

# ci: 意図1行を現在のセッションに記録  例) ci "race を疑ってる。戻ったら logs/ を見る"
#     ci -l で今の状況を1回表示 / 引数なしで意図クリア
alias ci="$CLAUDE_STATUS_BIN/claude-intent.sh"

# cs: 全セッションのステータスを常時表示（q / Esc で終了）
# 死活監視は各セッションの hook（UserPromptSubmit/Stop/SessionStart）から
# reap-dead-sessions.sh が呼ばれることで常時効いているため、cs 側では
# 起動時に一度だけ同期で回収する（launchd 不在でも Claude Code を使えば
# 自然に掃除される設計。cs 表示中限定の定期ループは持たない）。
cs() {
  local f="$HOME/.claude/status/status.md"
  local viewer="$CLAUDE_STATUS_BIN/status-view.py"
  local py
  "$CLAUDE_STATUS_BIN/reap-dead-sessions.sh" 2>/dev/null
  for py in /usr/bin/python3 python3; do
    if [ -x "$viewer" ] && command -v "$py" >/dev/null 2>&1; then
      "$py" "$viewer"
      return
    fi
  done
  if command -v watch >/dev/null 2>&1; then
    watch -c -n 2 -t cat "$f"
  else
    while true; do clear; cat "$f"; sleep 2; done
  fi
}
