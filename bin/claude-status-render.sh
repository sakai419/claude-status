#!/bin/bash
# 全セッションのJSONを集約して ~/.claude/status/status.md を再生成する。
# status-update.sh / status-resume.sh / claude-intent.sh から呼ばれる共通レンダラ。
#
# 並び順は「⚠️ 質問中 → 💤 アイドル → ✅ 完了 → 🟣 サブ待ち → 🔵 実行中」の5セクション。
# 手当てが必要なものを上に、放っておいてよいものを下に置く。
# サブ待ちは Stop 後もサブエージェントの完了を待って止まっている状態。放置すれば
# 進むので下寄りだが、完全に自走している実行中よりは気に掛ける必要があるため間に置く。
# 各セクション内は更新の新しい順。
#
# アイドルは「更新が CS_IDLE_SECS 秒以上止まっているセッション」。Desktop から起動した
# セッションには CLI の exit に相当する操作がなく、閉じるまでプロセスが生き続けるため
# PID ベースの reap（reap-dead-sessions.sh）では消えない。放置されたまま完了・実行中に
# 居座るのを避けるため、状態を問わずここへ降格させる（質問中だけは手当て対象なので除く）。
# 降格は表示上の扱いだけで JSON は消さない。一覧から消したい場合は status-view.py の x キー。
#
# 出力には ANSI エスケープ（色・太字）を埋め込む。status-view.py がエスケープを
# 幅0として扱い、非TTY出力時には除去する。
#
# CS_STATUS_ROOT を設定すると入出力先ディレクトリを差し替えられる（テスト用）。
set -euo pipefail

JQ=/opt/homebrew/bin/jq
ROOT="${CS_STATUS_ROOT:-$HOME/.claude/status}"
SDIR="$ROOT/sessions"
OUT="$ROOT/status.md"
IDX="$ROOT/status.index.json"   # status-view.py が詳細ペインで使う表示順の索引
IDLE="${CS_IDLE_SECS:-1800}"    # アイドル降格のしきい値（秒）

now=$(date +%s)
now_h=$(date +"%H:%M:%S")

# 書き込みは tmp→mv の原子的置換だが、途中で kill された場合に tmp が残る。
# 5分以上前の取り残しだけ掃除する（実行中の他プロセスの tmp は触らない）。
find "$ROOT" -maxdepth 1 -name 'status.*.tmp.*' -mmin +5 -delete 2>/dev/null || true

shopt -s nullglob
files=("$SDIR"/*.json)

# render 実行中に別 hook が対象ファイルを削除・書き換え中の可能性があるため、
# 1ファイルの読み取り失敗（削除競合・書き込み途中）が全体を止めないよう、
# 各ファイルを個別に cat して読める分だけ jq に渡す（壊れた1件はスキップ）。
valid_json=""
for f in "${files[@]}"; do
  content=$(cat "$f" 2>/dev/null) || continue
  [ -z "$content" ] && continue
  printf '%s' "$content" | "$JQ" -e . >/dev/null 2>&1 || continue
  valid_json="$valid_json$content"$'\n'
done

{
  if [ -z "$valid_json" ]; then
    printf '\033[1m CLAUDE CODE STATUS\033[0m  \033[2m· 更新 %s\033[0m\n' "$now_h"
    printf '\033[2m ─────────\033[0m\n'
    printf '\n\033[2m  アクティブなセッションはありません\033[0m\n'
  else
    printf '%s' "$valid_json" | "$JQ" -rs --argjson now "$now" --argjson idle "$IDLE" --arg nowh "$now_h" '
      def r:    "\u001b[0m";
      def bold: "\u001b[1m";
      def dim:  "\u001b[2m";
      def c($x):   "\u001b[1;" + $x + "m";
      def bar($x): "\u001b[" + $x + "m" + "▌" + r;

      def rel($d):
        if   $d < 0     then "未来"
        elif $d < 60    then "\($d)秒前"
        elif $d < 3600  then "\(($d/60)|floor)分前"
        elif $d < 86400 then "\(($d/3600)|floor)時間前"
        else                 "\(($d/86400)|floor)日前" end;

      def short($t; $n):
        ($t // "") | gsub("[\n\r]+"; " ")
        | if (length > $n) then (.[0:$n] + "…") else . end;

      # アイドル行で「元の状態」を添えるためのラベル。
      def slabel($s):
        if   $s == "waiting"   then "質問中"
        elif $s == "completed" then "完了"
        elif $s == "subagent"  then "サブ待ち"
        elif $s == "running"   then "実行中"
        else "不明" end;

      # 更新が $idle 秒以上止まっているセッション。質問中は手当て対象なので降格しない。
      def is_idle($now): (($now - (.updated_epoch // 0)) >= $idle) and ((.status // "") != "waiting");

      # 1セッション分のブロック。左端に状態色の縦バーを引いて視覚的にまとめる。
      # $showstate=true のときはプロジェクト名の後ろに元の状態を添える（アイドル用）。
      def entry($col; $now; $showstate):
        ( .cwd // "" ) as $cwd
        | ( $cwd | sub("^" + env.HOME; "~") ) as $dir
        | ( $dir | split("/") ) as $p
        | ( $p | last ) as $proj
        | ( if ($p | length) > 1 then (($p | .[0:-1] | join("/")) + "/") else "" end ) as $pfx
        | ( if $showstate then "  \(dim)· \(slabel(.status // ""))\(r)" else "" end ) as $sfx
        | ($now - (.updated_epoch // 0)) as $d
        | "  \(bar($col)) \(dim)\($pfx)\(r)\(bold)\($proj)\(r)\($sfx)",
          "  \(bar($col)) \(dim)直近\(r) \(short(.last_prompt; 30))",
          ( if (.intent // "") != ""
            then "  \(bar($col)) \(dim)意図\(r) \(short(.intent; 30))"
            else empty end ),
          ( if (.status // "") == "subagent" and (.subagent_count // 0) > 0
            then "  \(bar($col)) \(dim)サブ\(r) \(.subagent_count)件\(if (.subagent_types // "") != "" then " \(dim)\(short(.subagent_types; 24))\(r)" else "" end)"
            else empty end ),
          "  \(bar($col)) \(dim)⏱ \(rel($d)) · \(.updated_at // "")\(r)",
          "";

      # 状態ごとのセッション群。0件のセクションは丸ごと出さない。
      def section($rows; $key; $icon; $label; $col; $now):
        ( [ $rows[] | select((.status // "") == $key) ]
          | sort_by(-(.updated_epoch // 0)) ) as $g
        | if ($g | length) == 0 then empty
          else
            "\(c($col))\($icon) \($label)\(r)  \(dim)— \($g | length)\(r)",
            ( $g[] | entry($col; $now; false) )
          end;

      . as $all
      | [ $all[] | select(is_idle($now) | not) ] as $rows
      | ( [ $all[] | select(is_idle($now)) ] | sort_by(-(.updated_epoch // 0)) ) as $idles
      | ["waiting", "completed", "subagent", "running"] as $known
      | [ $rows[] | (.status // "") as $s | select($known | index($s) | not) ] as $other
      | "\(bold) CLAUDE CODE STATUS\(r)  \(dim)· \($all | length) セッション · 更新 \($nowh)\(r)",
        "\(dim) ─────────\(r)",
        "",
        section($rows; "waiting";   "⚠️"; "質問中";   "33"; $now),
        ( if ($idles | length) == 0 then empty
          else
            "\(c("90"))💤 アイドル\(r)  \(dim)— \($idles | length)\(r)",
            ( $idles[] | entry("90"; $now; true) )
          end ),
        section($rows; "completed"; "✅"; "完了";     "32"; $now),
        section($rows; "subagent";  "🟣"; "サブ待ち"; "35"; $now),
        section($rows; "running";   "🔵"; "実行中";   "36"; $now),
        ( if ($other | length) == 0 then empty
          else
            "\(c("35"))❔ 不明\(r)  \(dim)— \($other | length)\(r)",
            ( $other[] | entry("35"; $now; false) )
          end )
    '
  fi
} > "$OUT.tmp.$$"

mv "$OUT.tmp.$$" "$OUT"

# 表示順そのままのセッション索引。status-view.py が「N番目のブロック＝索引のN番目」
# として突き合わせ、選択・詳細表示に使う。idle は表示側の降格判定と同じ基準。
if [ -z "$valid_json" ]; then
  printf '[]\n' > "$IDX.tmp.$$"
else
  printf '%s' "$valid_json" | "$JQ" -s --argjson now "$now" --argjson idle "$IDLE" '
    def is_idle: (($now - (.updated_epoch // 0)) >= $idle) and ((.status // "") != "waiting");
    def rank($idle_flag; $s):
      if   $s == "waiting"   then 0
      elif $idle_flag        then 1
      elif $s == "completed" then 2
      elif $s == "subagent"  then 3
      elif $s == "running"   then 4
      else 5 end;
    map(. + { _idle: is_idle })
    | sort_by([ rank(._idle; (.status // "")), -(.updated_epoch // 0) ])
    | map({
        session_id:      (.session_id // ""),
        status:          (.status // ""),
        idle:            ._idle,
        cwd:             (.cwd // ""),
        last_prompt:     (.last_prompt // ""),
        intent:          (.intent // ""),
        subagent_count:  (.subagent_count // 0),
        subagent_types:  (.subagent_types // ""),
        updated_at:      (.updated_at // ""),
        updated_epoch:   (.updated_epoch // 0),
        transcript_path: (.transcript_path // "")
      })' > "$IDX.tmp.$$"
fi
mv "$IDX.tmp.$$" "$IDX"
