#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# poller ── 入力トリガ(poll-gh.sh=issue / poll-pr.sh=PRレビュー)を定期実行する常駐ループ。
#   LLM を呼ばない＝安い。cron 依存を避け、keeper/driver と同じく
#   supervisor 配下の常駐 bash として動かす（コンテナ再起動で自動復旧）。
# ─────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
source ./config.sh
source ./bin/lib.sh
mkdir -p "$LOGS_DIR" "$STATE_DIR"

# 1ポーラーの実行可否を判定して走らせる。各トリガは set -e。失敗(ネットワーク等)は
# ここで握って次周回へ＝poller は死なせない。
#   ・ENABLE_POLL_<NAME> が true のものだけ実行（capability トグル。プロジェクト毎に取捨）。
#   ・POLL_<NAME>_AT が空なら毎周回（間隔ベース。deps/ci は中で self-throttle）。
#     "HH:MM" が入っていれば毎日その時刻以降に1回だけ（due_daily＝cron 不要の「⚪時実行」）。
run_poll() {
  local up="$1" script="$2" key="$3"
  local enable_var="ENABLE_POLL_$up" at_var="POLL_${up}_AT" at
  [ "${!enable_var:-true}" = true ] || return 0
  at="${!at_var:-}"
  [ -n "$at" ] && { due_daily "$key" "$at" || return 0; }
  "$script" >> "$LOGS_DIR/poller.log" 2>&1 || log warn "$key poll failed (rc=$?); will retry next cycle"
}

log info "poller started (interval=${POLL_GH_INTERVAL}s)"
while true; do
  run_poll GH      ./triggers/poll-gh.sh      gh
  run_poll PR      ./triggers/poll-pr.sh      pr
  run_poll OUTCOME ./triggers/poll-outcome.sh outcome
  run_poll DEPS    ./triggers/poll-deps.sh    deps
  run_poll CI      ./triggers/poll-ci.sh      ci
  date +%s > "$STATE_DIR/poller.heartbeat"   # 巡回した証跡（status.sh が鮮度表示に使う。ログは汚さない）
  sleep "$POLL_GH_INTERVAL"
done
