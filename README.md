# claude-status

Claude Code の全セッションの状態（実行中・質問中・サブ待ち・完了）を集めて表示する。

- `bin/` hook から呼ばれて `~/.claude/status/` にセッションごとの JSON と `status.md` を書くスクリプト群、ビューア（`status-view.py`）
- `shell/cs.zsh` `cs`（ステータス常時表示）と `ci`（意図1行の記録）

スクリプト同士は自分の置き場所からの相対パスで呼び合うので、repo の場所は問わない。
状態データの置き場所は `~/.claude/status/` 固定。

## セットアップ

`.zshrc`:

```zsh
source ~/dev/tools/claude-status/shell/cs.zsh
```

`settings.json` の hooks（`claude-multiprofile` の各プロファイルにも同じものを入れる）:

| イベント | スクリプト |
|---|---|
| UserPromptSubmit / Notification / Stop | `bin/status-update.sh` |
| PostToolUse | `bin/status-resume.sh` |
| SubagentStart / SubagentStop | `bin/status-subagent.sh` |
| SessionStart | `bin/status-session-start.sh` |
| SessionEnd（matcher: `logout\|prompt_input_exit\|clear\|other`） | `bin/status-cleanup.sh` |

`jq` は `/opt/homebrew/bin/jq` を使う。ビューアは `/usr/bin/python3` の標準ライブラリのみで動く。
