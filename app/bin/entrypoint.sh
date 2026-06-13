#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# entrypoint ── コンテナの PID1直下(tiniの子)。**root で動く唯一の層**。
#   やることは2つだけ:
#     1. 自前の Docker エンジン(dockerd)を root で起動する（dind / B案）。
#        対象 repo の検証(`docker compose build`/`$TEST_CMD` 等)はこの中で回す。
#        ホストの docker.sock は渡さない＝この箱の中で完結。privileged だが
#        breakout してもこの箱(=使い捨ての VM / EC2)の中に留まる前提で受容する。
#     2. 準備ができたら gosu で node に降格し supervisor を起動する。
#        claude --dangerously-skip-permissions は root では拒否されるため、
#        LLM スタック一式(keeper/driver/poller/claude)は必ず非 root=node で動かす。
#        root のままなのは dockerd ただ1つ＝権限の最小化を崩さない。
#   dockerd と supervisor を同じ「層状の番人」に載せる: どちらか死んだら両方
#   落として exit 1 → compose の restart=unless-stopped が箱ごと立て直す。
# ─────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
source ./config.sh
mkdir -p "$LOGS_DIR"

DOCKERD_LOG="$LOGS_DIR/dockerd.log"

echo "[entrypoint] starting dockerd (dind) ..."
dockerd >>"$DOCKERD_LOG" 2>&1 & DOCKERD=$!

# dockerd の準備待ち（root の docker info が応答するまで）。privileged 前提。
ready=0
for _ in $(seq 1 "$DOCKERD_WAIT"); do
  if docker info >/dev/null 2>&1; then ready=1; break; fi
  if ! kill -0 "$DOCKERD" 2>/dev/null; then
    echo "[entrypoint] dockerd died during startup; see $DOCKERD_LOG"; exit 1
  fi
  sleep 1
done
if [ "$ready" -ne 1 ]; then
  echo "[entrypoint] dockerd not ready after ${DOCKERD_WAIT}s; see $DOCKERD_LOG"
  kill "$DOCKERD" 2>/dev/null || true
  exit 1
fi
echo "[entrypoint] dockerd ready."

# LLM スタックは node で。gosu は環境変数を保持するので .env の値はそのまま継承される。
gosu node ./bin/supervisor.sh & SUP=$!

# dockerd か supervisor のどちらかが落ちたら両方落とす → 箱ごと restart に委ねる
wait -n "$DOCKERD" "$SUP"
echo "[entrypoint] a child (dockerd or supervisor) exited; tearing down"
kill "$DOCKERD" "$SUP" 2>/dev/null || true
exit 1
