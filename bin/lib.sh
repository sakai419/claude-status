# shellcheck shell=bash
# bin/*.sh から source される共通関数。単体では実行しない。
#
# find_claude_pid: このプロセスを起動している claude 本体の PID を特定する。
#   まず CLAUDE_PID 環境変数（claude 本体が自身で設定する）を使い、
#   無ければ $PPID から祖先を辿って comm を確認するフォールバックに切り替える。
# is_claude_process <pid>: 指定 PID が claude 本体（生きている）かどうかを判定する。
#   cmux 等のデーモン経由起動では実行ファイルパスが
#   .../claude/versions/2.1.246 のようにバージョン番号で終わるため、
#   末尾一致だけでなく claude/versions/ を含むパスも本体とみなす。

# 状態ファイルにはプロンプトが入るので、自分以外から読めないように作る。
umask 077

# valid_session_id <id>: ファイル名に使ってよい session_id か。
#   Claude Code が渡すのは UUID だが、入力をそのままパスに使うと ../ で
#   sessions/ の外を書き換え・削除できてしまうので、使える文字を絞る。
valid_session_id() {
  case "$1" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

find_claude_pid() {
  if [ -n "${CLAUDE_PID:-}" ] && kill -0 "$CLAUDE_PID" 2>/dev/null; then
    printf '%s\n' "$CLAUDE_PID"
    return 0
  fi

  local cur
  cur=$PPID
  for _ in 1 2 3 4 5 6 7 8; do
    [ -z "$cur" ] && break
    [ "$cur" = "1" ] && break
    if is_claude_process "$cur"; then
      printf '%s\n' "$cur"
      return 0
    fi
    cur=$(ps -o ppid= -p "$cur" 2>/dev/null | tr -d ' ')
  done
  return 1
}

is_claude_process() {
  local pid="$1" comm base
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null)
  base=$(printf '%s' "$comm" | awk -F/ '{print $NF}')
  [ "$base" = "claude" ] && return 0
  case "$comm" in */claude/versions/*) return 0 ;; esac
  return 1
}

# jq は PATH から探す。hook は PATH が絞られた環境で走ることがあるので、
# よくある置き場所も見る。見つからなければ空のまま（呼び出し側で失敗する）。
JQ=$(command -v jq 2>/dev/null || true)
if [ -z "$JQ" ]; then
  for c in /opt/homebrew/bin/jq /usr/local/bin/jq /usr/bin/jq; do
    if [ -x "$c" ]; then JQ=$c; break; fi
  done
fi
