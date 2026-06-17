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
#   ・POLL_<NAME>_CRON で2モード（cron デーモンには依存せず書式だけ自前評価）:
#       空        → 既定間隔 POLL_GH_INTERVAL ごと（後方互換。deps/ci は中でさらに self-throttle）
#       cron式    → 標準5フィールド cron（例 "*/30 * * * *"=30分毎 / "0 3 * * *"=毎日3時 / "0 9 * * 1-5"=平日9時）
#   基底の起床間隔は POLL_TICK（既定60s）＝cron は分粒度なので 60s 以下で取りこぼさない。
run_poll() {
  local up="$1" script="$2" key="$3"
  local enable_var="ENABLE_POLL_$up" cron_var="POLL_${up}_CRON" cron
  [ "${!enable_var:-true}" = true ] || return 0
  cron="${!cron_var:-}"
  if [ -z "$cron" ]; then due_every "$key" "${POLL_GH_INTERVAL}s" || return 0   # 既定間隔
  else                    due_cron  "$key" "$cron"                || return 0   # cron 式
  fi
  "$script" >> "$LOGS_DIR/poller.log" 2>&1 || log warn "$key poll failed (rc=$?); will retry next cycle"
}

# 起動直後は各ポーラーを1回走らせたい（再起動後すぐ拾う）。間隔系の lastrun だけ消す
# （日次の lastday は残す＝同日2回実行を避ける／deps 内部の self-throttle にも触れない）。
rm -f "$STATE_DIR"/poll-*.lastrun 2>/dev/null || true

log info "poller started (tick=${POLL_TICK}s, default-interval=${POLL_GH_INTERVAL}s)"
while true; do
  run_poll GH      ./triggers/poll-gh.sh      gh
  run_poll PR      ./triggers/poll-pr.sh      pr
  run_poll OUTCOME ./triggers/poll-outcome.sh outcome
  run_poll DEPS    ./triggers/poll-deps.sh    deps
  run_poll CI      ./triggers/poll-ci.sh      ci
  date +%s > "$STATE_DIR/poller.heartbeat"   # 巡回した証跡（status.sh が鮮度表示に使う。ログは汚さない）
  sleep "$POLL_TICK"
done
