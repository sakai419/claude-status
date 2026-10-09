#!/bin/bash
# claude-status を取り除く。オプションは install.sh と同じ（--config-dir / --dry-run / --no-zshrc）。
exec "$(dirname "$0")/install.sh" --uninstall "$@"
