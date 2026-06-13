#!/usr/bin/env bash
# ループ操作のショートカット集

set -euo pipefail
CMD="${1:-}"

case "$CMD" in
  stats)  docker compose exec -u node loop ./bin/status.sh ;;
  attach) docker compose exec -u node loop tmux attach -t loop ;;
  *)
    echo "使い方: $0 <command>"
    echo "  stats   ダッシュボードを表示"
    echo "  attach  tmux セッションに接続"
    exit 1
    ;;
esac
