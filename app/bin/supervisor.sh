#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# supervisor ── keeper と driver を起動。どちらかが死んだら両方落とす
#   → コンテナの restart=unless-stopped で全体が立ち上がり直す（最外の番人）。
#   コンテナの ENTRYPOINT/CMD はこれ。PID1 ゾンビ刈りは compose の init:true に任せる。
# ─────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
source ./config.sh
mkdir -p "$LOGS_DIR"

# 起動時に setup-target を自動実行（冪等）。
#   TARGET_REPO_URL があれば clone + 認証配線 + 設定流し込みを毎回再適用
#   → コンテナ作り直しや認証失効でも自動復旧する。
if [ -n "${TARGET_REPO_URL:-}" ]; then
  echo "[supervisor] running setup-target.sh ..."
  ./bin/setup-target.sh || echo "[supervisor] setup-target failed; will idle-wait"
fi

# それでも repo が無ければ（未設定 or 失敗）idle 待機。誤動作・crash-loop させない。
if [ ! -d "$TARGET_REPO_DIR/.git" ]; then
  echo "[supervisor] 対象 repo 未準備。config.sh の TARGET_REPO_URL を埋めて再起動 (or 手動 ./bin/setup-target.sh)。idle 待機。"
  while [ ! -d "$TARGET_REPO_DIR/.git" ]; do sleep 30; done
fi

./bin/session-keeper.sh & KEEPER=$!
sleep "$BOOT_WAIT"          # claude が立ち上がるのを待ってから driver 開始
./bin/driver.sh & DRIVER=$!
./bin/poller.sh & POLLER=$! # issue トリガの定期実行（LLM 非依存・常駐）

# どれか落ちたら全部落として終了 → コンテナ restart に委ねる
wait -n "$KEEPER" "$DRIVER" "$POLLER"
echo "[supervisor] a child exited; tearing down"
kill "$KEEPER" "$DRIVER" "$POLLER" 2>/dev/null || true
exit 1
