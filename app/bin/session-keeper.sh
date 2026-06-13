#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# session-keeper ── tmux + claude の生存を保証する番人。
#   死んでいれば再起動。crash-loop はサーキットブレーカで停止＆通知。
# ※雛形（未テスト）。
# ─────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
source ./config.sh
source ./bin/lib.sh
mkdir -p "$LOGS_DIR"

crashes=()
record_crash() {
  local now kept=() t
  now=$(date +%s); crashes+=("$now")
  for t in "${crashes[@]}"; do [ $((now - t)) -le "$CRASH_WINDOW" ] && kept+=("$t"); done
  crashes=("${kept[@]}")
  if [ "${#crashes[@]}" -ge "$CRASH_LIMIT" ]; then
    notify "🛑 crash-loop: ${CRASH_WINDOW}秒間に ${#crashes[@]} 回再起動。keeper を停止します。"
    log fatal "crash-loop breaker tripped"
    exit 1   # supervisor 経由でコンテナごと落ち、restart policy 判断に委ねる
  fi
}

# claude が pane の前面プロセスとして生きているか（liveness 判定の単一ソース）
claude_running() { grep -qiE '\b(claude|node)\b' <<<"$(pane_cmd)"; }

launch_claude() {
  # Claude セッションは対象 repo を cwd に起動する。
  # 無人運用なので許可モーダルを承認できる人間がいない → スキップする。
  # 安全性はコンテナ隔離＋push を loop/* に限定＋main の branch protection で担保。
  # REMOTE_CONTROL_NAME が非空なら Remote Control を有効化（スマホ/claude.ai から閲覧。アウトバウンドのみ）。
  local rc_flag=""
  [ -n "${REMOTE_CONTROL_NAME:-}" ] && rc_flag=" --remote-control ${REMOTE_CONTROL_NAME}"
  # EFFORT_LEVEL が非空なら thinking 量を固定（既定 medium＝トークン節約）。
  local effort_flag=""
  [ -n "${EFFORT_LEVEL:-}" ] && effort_flag=" --effort ${EFFORT_LEVEL}"
  tmux send-keys -t "$TMUX_SESSION" -l "claude --dangerously-skip-permissions${effort_flag}${rc_flag}"
  sleep 0.3
  tmux send-keys -t "$TMUX_SESSION" Enter
  # 前面化（プロンプト出現）まで待つ＝起動途中を「死んでいる」と誤検知して
  # 二重起動するレースを防ぐ。LAUNCH_GRACE 秒で上がらなければ起動失敗とみなす。
  local waited=0
  while [ "$waited" -lt "$LAUNCH_GRACE" ]; do
    sleep 1; waited=$((waited+1))
    claude_running && return 0
  done
  return 1
}

ensure_session() {
  if ! tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    log keeper "creating tmux session + claude in $TARGET_REPO_DIR"
    tmux new-session -d -s "$TMUX_SESSION" -c "$TARGET_REPO_DIR" 2>/dev/null \
      || tmux new-session -d -s "$TMUX_SESSION"
    # 生ストリームを追記ログ化（forensics 専用。scrollback truncation なし）
    tmux pipe-pane -t "$TMUX_SESSION" -o "cat >> '$LOGS_DIR/session.log'"
    sleep 1
    # 初回起動。上がれば正常＝crash ではない。上がらなければ起動失敗としてカウント。
    if launch_claude; then log keeper "claude up"
    else log keeper "claude failed to come up within ${LAUNCH_GRACE}s"; record_crash; fi
    return
  fi
  # 既存セッションで claude が前面にいない＝本当に落ちた。launch_claude が起動完了まで
  # 待つので、起動途中(まだ bash)を誤検知して二重投入することはない。
  if ! claude_running; then
    log keeper "claude not running; relaunching"
    record_crash                         # 落ちた事実を 1 回だけカウント
    launch_claude || log keeper "relaunch failed within ${LAUNCH_GRACE}s"
  fi
}

log info "keeper started"
while true; do
  ensure_session
  sleep "$KEEPER_INTERVAL"
done
