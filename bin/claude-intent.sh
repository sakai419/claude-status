#!/bin/bash
# 手動で「意図1行」をセッションのステータスに書き込む。
#   ci "race を疑ってる。戻ったら logs/ を見る"   現在のディレクトリのセッションに記録
#   ci                                          意図をクリア
#   ci -l                                       現在のステータスを表示
#   ci -s <指定> "意図"                           対象セッションを明示指定して記録
#        <指定> は プロジェクト名(ディレクトリ末尾) または session_id の先頭数文字
#
# 対象セッションが一意に決まらない場合（PWD一致が無い/複数ある等）は、
# 誤って別セッションへ書き込まないよう「書き込まずに候補を表示して終了」する。
set -euo pipefail

BIN="$(cd "$(dirname "$0")" && pwd)"
. "$BIN/lib.sh"
SDIR="$HOME/.claude/status/sessions"
OUT="$HOME/.claude/status/status.md"

if [ "${1:-}" = "-l" ] || [ "${1:-}" = "--list" ]; then
  [ -f "$OUT" ] && cat "$OUT" || echo "ステータスはまだありません"
  exit 0
fi

# -s <指定> で対象を明示指定
sel=""
if [ "${1:-}" = "-s" ]; then
  sel="${2:-}"
  if [ -z "$sel" ]; then
    echo "使い方: ci -s <プロジェクト名 または session_id先頭> \"意図\"" >&2
    exit 1
  fi
  shift 2
fi

intent="$*"

shopt -s nullglob
files=("$SDIR"/*.json)
if [ ${#files[@]} -eq 0 ]; then
  echo "記録されたセッションがありません" >&2
  exit 1
fi

# 候補セッションを新しい順に一覧表示（session_id短縮・状態・時刻付き）
print_candidates() {
  local now
  now=$(date +%s)
  "$JQ" -rs --argjson now "$now" '
    def rel($d):
      if   $d < 60    then "\($d)秒前"
      elif $d < 3600  then "\(($d/60)|floor)分前"
      elif $d < 86400 then "\(($d/3600)|floor)時間前"
      else                 "\(($d/86400)|floor)日前" end;
    sort_by(.updated_epoch) | reverse | .[]
    | "    \(.session_id[0:8])  \(if .status=="running" then "🔵実行中" elif .status=="waiting" then "⚠️質問中" else "✅完了" end)  [\(.cwd|split("/")|last)]  \(.cwd|sub("^"+env.HOME;"~"))  (\($now-(.updated_epoch//0)|rel(.)))"
  ' "${files[@]}"
}

# 一致するセッションのidを新しい順に返す（改行区切り）
if [ -n "$sel" ]; then
  # session_id 先頭一致を優先し、無ければ プロジェクト名(cwd末尾) 一致
  ids=$("$JQ" -rs --arg s "$sel" '
    ([ .[] | select(.session_id | startswith($s)) ]) as $byid
    | (if ($byid|length) > 0 then $byid
       else [ .[] | select((.cwd|split("/")|last) == $s) ] end)
    | sort_by(.updated_epoch) | reverse | .[].session_id' "${files[@]}")
  nomatch_msg="⚠ 指定 '$sel' に一致するセッションがありません。"
else
  # 既定: 現在のディレクトリ一致
  ids=$("$JQ" -rs --arg pwd "$PWD" '
    [ .[] | select(.cwd == $pwd) ]
    | sort_by(.updated_epoch) | reverse | .[].session_id' "${files[@]}")
  nomatch_msg="⚠ このディレクトリ ($PWD) に一致するセッションがありません。"
fi

count=$(printf '%s' "$ids" | grep -c . || true)

if [ "$count" -eq 0 ]; then
  echo "$nomatch_msg" >&2
  echo "  対象を明示してください: ci -s <プロジェクト名 または session_id先頭> \"意図\"" >&2
  echo "  候補:" >&2
  print_candidates >&2
  exit 1
elif [ "$count" -gt 1 ]; then
  echo "⚠ 対象セッションが複数あります。session_id の先頭で指定してください:" >&2
  echo "    例) ci -s $(printf '%s' "$ids" | head -1 | cut -c1-8) \"$intent\"" >&2
  echo "  候補:" >&2
  print_candidates >&2
  exit 1
fi

target=$(printf '%s' "$ids" | head -1)
sfile="$SDIR/$target.json"
"$JQ" --arg intent "$intent" '.intent = $intent' "$sfile" > "$sfile.tmp.$$" && mv "$sfile.tmp.$$" "$sfile"

"$BIN/claude-status-render.sh" 2>/dev/null || true

proj=$("$JQ" -r '.cwd | split("/") | last' "$sfile")
if [ -n "$intent" ]; then
  echo "意図を記録しました [$proj] (${target:0:8}): $intent"
else
  echo "意図をクリアしました [$proj] (${target:0:8})"
fi
