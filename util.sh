#!/usr/bin/env bash
# ループ操作のショートカット集（単一 project デバッグ用。複数 project は bin/loopctl を使う）。
#   compose は container/ 配下に移動したので -f で明示する。

set -euo pipefail
CMD="${1:-}"
DC="docker compose -f $(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/container/docker-compose.yml"

case "$CMD" in
  stats)  $DC exec -u node loop ./bin/status.sh ;;
  attach) $DC exec -u node loop tmux attach -t loop ;;
  *)
    echo "使い方: $0 <command>"
    echo "  stats   ダッシュボードを表示"
    echo "  attach  tmux セッションに接続"
    exit 1
    ;;
esac
