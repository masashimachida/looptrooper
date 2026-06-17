#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# enqueue ── ポーラからタスクを投函する内部プリミティブ。
#   send-keys は呼ばない。ファイルを置くだけ＝混線(#1)と並行(#3)を構造的に回避。
#
#   ※タスク入力は GitHub に限定する（唯一の正規入力源）。呼べるのはポーラだけ:
#     - poll-gh.sh が LOOP_SOURCE=issue（issue 駆動）
#     - poll-pr.sh が LOOP_SOURCE=pr-review（PR レビュー指摘の往復）
#     - poll-spec.sh が LOOP_SOURCE=spec（仕様フェーズの分解＝issue 群を生成）
#     それ以外（手動・git hook 等）からの投函は事故防止のため拒否する。
#     smoke test も対象 repo に 'loop' ラベル付き issue を立てて行うこと。
#
#   内部呼び出し:
#     LOOP_SOURCE=issue enqueue.sh "<タイトル>"                 # 本文なし
#     LOOP_SOURCE=issue enqueue.sh "<タイトル>" path/to/body.md  # 本文をファイルから
#     echo "本文" | LOOP_SOURCE=issue enqueue.sh "<タイトル>" -   # 本文を stdin から
# ─────────────────────────────────────────────────────────────
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
source ./config.sh

# 入力源は GitHub（issue / PR レビュー）のみ。ポーラ以外からの投函を拒否する。
case "${LOOP_SOURCE:-}" in
  issue|pr-review|spec) ;;
  *)
    cat >&2 <<'MSG'
enqueue.sh: タスク入力は GitHub（issue / PR レビュー）に限定されています。
  対象 repo の issue に 'loop' ラベルを付けるか、ループの PR に changes-requested
  レビューを付ければ poller が自動で取り込みます。
  （これは内部プリミティブで、poll-gh.sh / poll-pr.sh が LOOP_SOURCE を設定して呼びます）
MSG
    exit 1 ;;
esac

mkdir -p "$QUEUE_DIR"

title="${1:?usage: enqueue.sh <title> [bodyfile|-]}"
slug=$(printf '%s' "$title" | tr -cs 'a-zA-Z0-9' '-' | tr 'A-Z' 'a-z' | sed 's/^-*//;s/-*$//' | cut -c1-40)
id="$(date +%Y%m%d-%H%M%S)-${slug:-task}"

body=""
if [ "${2:-}" = "-" ]; then body="$(cat)"
elif [ -n "${2:-}" ] && [ -f "$2" ]; then body="$(cat "$2")"
fi

cat > "$QUEUE_DIR/$id.md" <<EOF
# $title

$body
EOF
echo "$id"
