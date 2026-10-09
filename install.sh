#!/bin/bash
# claude-status のセットアップ。
#   ./install.sh                              ~/.claude（または $CLAUDE_CONFIG_DIR）に入れる
#   ./install.sh --config-dir ~/.claude-work  プロファイルを指定（複数回指定できる）
#   ./install.sh --uninstall                  取り除く（uninstall.sh と同じ）
#   ./install.sh --dry-run                    書き込まず、hooks の差分だけ見せる
#
# やること
#   1. jq と python3 があるか確かめる
#   2. settings.json の hooks にこの repo の bin/ を登録する
#      既存の hooks には触れない。以前に入れた分（置き場所が違うものも含む）は
#      取り除いてから入れ直すので、何回実行しても重複しない。
#   3. zshrc に shell/cs.zsh を読み込む1行を足す（cs / ci が使えるようになる）
#
#   4. 既にある状態データ（~/.claude/status）を自分以外から読めない権限にする
#
# 状態データは作りも消しもしない。hook が初回に作る。
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
BIN="$REPO/bin"
ZSHRC="${ZDOTDIR:-$HOME}/.zshrc"
MARK_BEGIN="# >>> claude-status >>>"
MARK_END="# <<< claude-status <<<"

mode=install
dry_run=0
touch_zshrc=1
config_dirs=()

usage() {
  sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --config-dir)   [ $# -ge 2 ] || usage 1; config_dirs+=("$2"); shift 2 ;;
    --config-dir=*) config_dirs+=("${1#*=}"); shift ;;
    --uninstall)    mode=uninstall; shift ;;
    --dry-run)      dry_run=1; shift ;;
    --no-zshrc)     touch_zshrc=0; shift ;;
    -h|--help)      usage 0 ;;
    *)              echo "不明なオプション: $1" >&2; usage 1 ;;
  esac
done
if [ ${#config_dirs[@]} -eq 0 ]; then
  config_dirs=("${CLAUDE_CONFIG_DIR:-$HOME/.claude}")
fi

say()  { printf '%s\n' "$*"; }
# シェルにそのまま渡せる形（単一引用符）にする。パスに空白や $ や ` があっても安全。
shell_quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
warn() { printf '注意: %s\n' "$*" >&2; }
die()  { printf 'エラー: %s\n' "$*" >&2; exit 1; }

# ---- 1. 前提 ---------------------------------------------------------------

# hook と同じ探し方で jq を見つける
. "$BIN/lib.sh"
[ -n "$JQ" ] || die "jq が見つかりません。brew install jq などで入れてから再実行してください。"

if [ "$mode" = install ]; then
  # macOS の /usr/bin/python3 は Command Line Tools が無いと実行時にダイアログを出すので、
  # 実行せずに有無だけ確かめる
  if [ "$(uname)" = Darwin ] && ! xcode-select -p >/dev/null 2>&1; then
    warn "Command Line Tools が無いため cs のビューアが動きません（xcode-select --install で入ります）。"
  elif ! command -v python3 >/dev/null 2>&1; then
    warn "python3 が見つからないため cs は簡易表示になります。"
  fi
fi

# ---- 2. hooks --------------------------------------------------------------

# イベント → スクリプト。matcher が空ならすべてに反応する。
HOOKS_SPEC='[
  {"event": "UserPromptSubmit", "script": "status-update.sh"},
  {"event": "Notification",     "script": "status-update.sh"},
  {"event": "Stop",             "script": "status-update.sh"},
  {"event": "PostToolUse",      "script": "status-resume.sh"},
  {"event": "SubagentStart",    "script": "status-subagent.sh"},
  {"event": "SubagentStop",     "script": "status-subagent.sh"},
  {"event": "SessionStart",     "script": "status-session-start.sh"},
  {"event": "SessionEnd",       "script": "status-cleanup.sh",
   "matcher": "logout|prompt_input_exit|clear|other"}
]'

# 登録するコマンドの末尾には目印のコメントを付け、それで自分の hook を見分ける。
# repo を移した後に入れ直しても、前の場所で入れた分が置き換わる。
# 目印が無い頃の登録（claude-status/bin/ と ~/.claude/bin/ の status-*.sh）も対象にする。
# グループ内の他の hook は残し、自分の分を抜いて空になったグループ・イベントだけ消す。
MARKER="# claude-status"
JQ_STRIP='
  def ours: (.command? // "")
    | test("# claude-status$")
      or test("(claude-status|\\.claude)/bin/status-(update|resume|cleanup|session-start|subagent)\\.sh[\"\u0027]?$");
  def strip_group:
    if ((.hooks // []) | any(ours))
    then (.hooks |= map(select(ours | not))) | select((.hooks | length) > 0)
    else . end;
  if (.hooks | type) == "object" then
    .hooks |= with_entries(
      if (.value | type) == "array" and (.value | length) > 0
      then (.value |= map(strip_group)) | select((.value | length) > 0)
      else . end)
    | if .hooks == {} then del(.hooks) else . end
  else . end
'

JQ_ADD='
  .hooks = (.hooks // {})
  | reduce $spec[] as $s (.;
      .hooks[$s.event] = ((.hooks[$s.event] // []) + [
        (if $s.matcher then {matcher: $s.matcher} else {} end)
        + {hooks: [{type: "command", command: (($bin + "/" + $s.script | @sh) + " " + $marker), async: true}]}
      ]))
'

# 変更前後の settings.json を比べ、増える hook を +、減る hook を - で出す。
# 他の hook には触れないので、並び順以外の違いはこれで全部になる。
hook_changes() {
  local before="$1" after="$2"
  [ -f "$before" ] || before=/dev/null
  "$JQ" -rn --slurpfile a "$before" --slurpfile b "$after" '
    def rows: [(.[0].hooks // {}) | to_entries[] | .key as $e | .value[]
               | (.matcher // "") as $m | .hooks[]?
               | "\($e)\(if $m != "" then " [\($m)]" else "" end)  \(.command)"];
    ($a | rows) as $old | ($b | rows) as $new
    | ([$old[] | select(. as $r | $new | index($r) | not) | "    - " + .]
       + [$new[] | select(. as $r | $old | index($r) | not) | "    + " + .])
    | if length == 0 then "    （並び順のみ）" else .[] end'
}

apply_settings() {
  local dir="$1" file="$1/settings.json" tmp filter
  if [ "$mode" = install ]; then
    filter="$JQ_STRIP | $JQ_ADD"
  else
    filter="$JQ_STRIP"
  fi

  if [ ! -d "$dir" ]; then
    [ "$mode" = install ] || { say "  $dir がありません。スキップします。"; return; }
    [ "$dry_run" -eq 1 ] || mkdir -p "$dir"
  fi

  tmp="$(mktemp "${TMPDIR:-/tmp}/claude-status.XXXXXX")"
  if [ -f "$file" ]; then
    "$JQ" -e 'type == "object"' "$file" >/dev/null 2>&1 \
      || { rm -f "$tmp"; die "$file が JSON オブジェクトとして読めません。手で直してから再実行してください。"; }
    "$JQ" --arg bin "$BIN" --arg marker "$MARKER" --argjson spec "$HOOKS_SPEC" "$filter" "$file" > "$tmp"
  else
    [ "$mode" = install ] || { rm -f "$tmp"; say "  $file がありません。スキップします。"; return; }
    printf '{}' | "$JQ" --arg bin "$BIN" --arg marker "$MARKER" --argjson spec "$HOOKS_SPEC" "$filter" > "$tmp"
  fi

  if [ -f "$file" ] && "$JQ" -e --slurpfile a "$file" --slurpfile b "$tmp" -n '$a == $b' >/dev/null; then
    say "  $file は変更なし"
    rm -f "$tmp"
    return
  fi

  if [ "$dry_run" -eq 1 ]; then
    say "  $file の変更予定（書き込みはしない）:"
    hook_changes "$file" "$tmp"
    rm -f "$tmp"
    return
  fi

  if [ -f "$file" ]; then
    local backup
    backup="$file.bak.claude-status.$(date +%Y%m%d-%H%M%S)"
    # 同じ秒に続けて実行しても前のバックアップを潰さない
    [ -e "$backup" ] && backup="$backup.$$"
    cp -p "$file" "$backup"
    say "  $file を更新（バックアップ: $(basename "$backup")）"
    hook_changes "$backup" "$tmp"
    # 上書きは cat で行う（シンボリックリンクや権限をそのまま保つため）
    cat "$tmp" > "$file"
  else
    say "  $file を作成"
    hook_changes /dev/null "$tmp"
    cat "$tmp" > "$file"
  fi
  rm -f "$tmp"
}

say "hooks（settings.json）"
for dir in "${config_dirs[@]}"; do
  apply_settings "$dir"
done

# 以前の版は umask 任せで状態データを作っていた（共有マシンだと他のユーザーから
# プロンプトが読める）。今の hook は自分専用で作るので、既存の分も揃える。
STATUS_DIR="$HOME/.claude/status"
if [ "$mode" = install ] && [ -d "$STATUS_DIR" ] && [ -n "$(find "$STATUS_DIR" -perm -g=r -o -perm -o=r | head -1)" ]; then
  say "状態データ"
  if [ "$dry_run" -eq 1 ]; then
    say "  $STATUS_DIR を自分だけが読める権限にする予定"
  else
    chmod -R go-rwx "$STATUS_DIR"
    say "  $STATUS_DIR を自分だけが読める権限にしました"
  fi
fi

# ---- 3. zshrc --------------------------------------------------------------

apply_zshrc() {
  local line
  line="source $(shell_quote "$REPO/shell/cs.zsh")"
  if [ "$mode" = install ]; then
    if [ -f "$ZSHRC" ] && grep -qF "shell/cs.zsh" "$ZSHRC"; then
      say "  $ZSHRC は既に cs.zsh を読み込んでいます（変更なし）"
      return
    fi
    if [ "$dry_run" -eq 1 ]; then
      say "  $ZSHRC に追記する予定: $line"
      return
    fi
    printf '\n%s\n%s\n%s\n' "$MARK_BEGIN" "$line" "$MARK_END" >> "$ZSHRC"
    say "  $ZSHRC に追記しました"
  else
    [ -f "$ZSHRC" ] || return 0
    local tmp
    tmp="$(mktemp "${TMPDIR:-/tmp}/claude-status.XXXXXX")"
    # install.sh が書いたブロック（直前の空行ごと）を除いた内容
    awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
      $0 == b { if (blank > 0) blank--; skip = 1; next }
      $0 == e && skip { skip = 0; next }
      skip { next }
      $0 == "" { blank++; next }
      { while (blank > 0) { print ""; blank-- } print }
      END { while (blank > 0) { print ""; blank-- } }' "$ZSHRC" > "$tmp"
    if cmp -s "$tmp" "$ZSHRC"; then
      :
    elif [ "$dry_run" -eq 1 ]; then
      say "  $ZSHRC から claude-status のブロックを消す予定"
    else
      cat "$tmp" > "$ZSHRC"
      say "  $ZSHRC から claude-status のブロックを消しました"
    fi
    # install.sh 以外の方法で書かれた読み込み行は、勝手に消さずに知らせるだけにする
    if grep -qF "shell/cs.zsh" "$tmp"; then
      warn "$ZSHRC に cs.zsh を読み込む行が残っています。手で消してください:"
      grep -F "shell/cs.zsh" "$tmp" | sed 's/^/    /' >&2
    fi
    rm -f "$tmp"
  fi
}

if [ "$touch_zshrc" -eq 1 ]; then
  say "zshrc"
  apply_zshrc
fi

# ---- 後始末の案内 -------------------------------------------------------------

[ "$dry_run" -eq 1 ] && exit 0
say ""
if [ "$mode" = install ]; then
  say "完了。新しく起動した Claude Code のセッションから表示されます。"
  say "新しいターミナルで（または source $ZSHRC の後に）cs で一覧を開けます。"
else
  say "取り除きました。状態データ（~/.claude/status）は残しています。不要なら手で消してください。"
fi
