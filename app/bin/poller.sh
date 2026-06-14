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

log info "poller started (interval=${POLL_GH_INTERVAL}s)"
while true; do
  # 各トリガは set -e。失敗(ネットワーク等)はここで握って次周回へ＝poller は死なせない。
  # capability トグル: ENABLE_POLL_* が true のものだけ実行（config.sh、プロジェクト毎に取捨）。
  [ "${ENABLE_POLL_GH:-true}" = true ]      && { ./triggers/poll-gh.sh      >> "$LOGS_DIR/poller.log" 2>&1 || log warn "poll-gh failed (rc=$?); will retry next cycle"; }
  [ "${ENABLE_POLL_PR:-true}" = true ]      && { ./triggers/poll-pr.sh      >> "$LOGS_DIR/poller.log" 2>&1 || log warn "poll-pr failed (rc=$?); will retry next cycle"; }
  [ "${ENABLE_POLL_OUTCOME:-true}" = true ] && { ./triggers/poll-outcome.sh >> "$LOGS_DIR/poller.log" 2>&1 || log warn "poll-outcome failed (rc=$?); will retry next cycle"; }
  [ "${ENABLE_POLL_DEPS:-true}" = true ]    && { ./triggers/poll-deps.sh    >> "$LOGS_DIR/poller.log" 2>&1 || log warn "poll-deps failed (rc=$?); will retry next cycle"; }
  date +%s > "$STATE_DIR/poller.heartbeat"   # 巡回した証跡（status.sh が鮮度表示に使う。ログは汚さない）
  sleep "$POLL_GH_INTERVAL"
done
