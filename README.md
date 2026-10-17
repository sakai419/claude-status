# claude-status

Claude Code の全セッションの状態（実行中・質問中・サブ待ち・待受中・完了）を集めて表示する。

並び順は 質問中 → アイドル → キープ → 完了 → 待受中 → サブ待ち → 実行中。

- サブ待ち: ターンを終えたが、サブエージェントがまだ走っている
- 待受中: ターンを終えたが、バックグラウンドの Bash・Monitor や cron の予約が残っていて、そのイベントで再び動き出す
- 更新が30分止まると、質問中以外は「アイドル」にまとめて表示する
- キープ: あえて残しているセッションに手動で印を付けると、アイドルにならずにアイドルの直後の「キープ」にまとまる。印は外すまで残り、再開して動いている間は元の状態のところに印付きで出る。`cs` では `p`、デスクトップアプリでは詳細の右上のしおりか、行の右クリックで付け外しする

- `bin/` hook から呼ばれて `~/.claude/status/` にセッションごとの JSON と `status.md` を書くスクリプト群、ビューア（`status-view.py`）
- `shell/cs.zsh` `cs`（ステータス常時表示）と `ci`（意図1行の記録）

スクリプト同士は自分の置き場所からの相対パスで呼び合うので、repo の場所は問わない。
状態データの置き場所は `~/.claude/status/` 固定。プロンプトの抜粋を含むので、自分だけが読める権限で作る。

## セットアップ

必要なもの: `jq`、`python3`（macOS は Command Line Tools に入っている）、zsh

```sh
git clone https://github.com/sakai419/claude-status.git ~/dev/tools/claude-status   # 置き場所はどこでもよい
~/dev/tools/claude-status/install.sh
```

`install.sh` は次のことをする。何回実行しても同じ結果になる。

- `settings.json` の hooks に `bin/` のスクリプトを登録する（下の表）。既存の hooks には触れず、変更前のファイルは `settings.json.bak.claude-status.<日時>` に残す。登録するコマンドの末尾には目印の `# claude-status` が付き、入れ直しや取り除きはこの目印で自分の分を見分ける
- `~/.zshrc` に `shell/cs.zsh` を読み込む行を足す（`cs` と `ci` が使えるようになる）

| オプション | 内容 |
|---|---|
| `--config-dir DIR` | 登録先のプロファイル。既定は `$CLAUDE_CONFIG_DIR`、無ければ `~/.claude`。複数回指定できる |
| `--dry-run` | 書き込まず、増減する hook を表示する |
| `--no-zshrc` | `~/.zshrc` に触れない |

repo を別の場所へ移したら、もう一度 `install.sh` を実行すれば登録が新しい場所に置き換わる。
取り除くときは `uninstall.sh`（オプションは同じ）。状態データ（`~/.claude/status/`）は残すので、不要なら手で消す。

登録される hooks:

| イベント | スクリプト |
|---|---|
| UserPromptSubmit / Notification / Stop | `bin/status-update.sh` |
| PostToolUse | `bin/status-resume.sh` |
| SubagentStart / SubagentStop | `bin/status-subagent.sh` |
| SessionStart | `bin/status-session-start.sh` |
| SessionEnd（matcher: `logout\|prompt_input_exit\|clear\|other`） | `bin/status-cleanup.sh` |

## デスクトップアプリ（macOS）

`cs` と同じ一覧を、黒背景のウィンドウで表示する。左にセッション一覧、右に選んだセッションの詳細。

```sh
app/build.sh --install   # ビルドして ~/Applications に入れ、起動する
```

- 詳細ではプロンプトの全文とエージェントの返答（Markdown を整形して表示）が読める
- ↑↓ / j k で選択を動かせる
- 「一覧から消す」は `cs` の `x` と同じ（JSON を消すだけで、プロセスは止めない）
- キープの印は詳細の右上のしおり、または行の右クリックで付け外しする（`cs` の `p` と同じ）
- メニューバーにも件数を出す。手当てが要る「質問中」があるとその件数になる。ウィンドウを閉じても、メニューバーの「ウィンドウを開く」で戻せる
- 「ログイン時に起動」は一覧の下のチェックで切り替える
- 一覧の右上のコントローラーで、右側をミニゲーム（2048）に切り替えられる。矢印キー / WASD で動かし、Esc か一覧の行を選ぶと詳細に戻る。盤面はアプリを閉じるまで残る
- iTerm2 のホットキーウィンドウのように、⌥S でいつでもウィンドウを呼び出せる。どのアプリを使っていても（フルスクリーンでも）いま見ている画面の手前に出て、もう一度押すかよそをクリックすると引っ込む。ウィンドウは他のウィンドウより常に手前に出る
- 一覧の右上のピンで固定すると、よそをクリックしても引っ込まない
- 設定（一覧の右上の歯車、メニューバー、または ⌘,）で、ショートカットを登録し直したり、ウィンドウの不透明度を変えたりできる。記録中は Esc でやめ、⌫ で消す。⌘ ⌃ ⌥ のどれかを含む組み合わせ（F キーは単独でも可）だけ登録できる

必要なもの: macOS 15 以降、Swift（Xcode または Command Line Tools）。署名はアドホックなので、ビルドした Mac でだけ使う想定。
repo を移したらビルドし直す（一覧から消したときに `bin/claude-status-render.sh` を呼ぶため、ビルド時に場所を埋め込んでいる）。

## ライセンス

MIT
