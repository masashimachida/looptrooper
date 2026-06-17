FROM node:22-bookworm

# Claude Code CLI
RUN npm install -g @anthropic-ai/claude-code

# ループに必要なツール（openssl は GitHub App の JWT 署名に使う）
RUN apt-get update && apt-get install -y --no-install-recommends \
      tmux git jq ca-certificates curl less openssl \
    && rm -rf /var/lib/apt/lists/*

# yq (mikefarah) ── config.sh が loop.yaml（非秘密設定）をパースするのに使う。
#   debian apt の yq は別物(python版)なので公式バイナリを取得。
RUN curl -fsSL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_$(dpkg --print-architecture)" \
      -o /usr/local/bin/yq && chmod +x /usr/local/bin/yq

# GitHub CLI (gh) ── 公式 apt リポジトリから
RUN mkdir -p -m 755 /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
       -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
       > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# ── 自前の Docker エンジン(dind / B案) ──
#   箱が自前の dockerd を持ち、対象 repo の検証(`docker compose build`/`$TEST_CMD` 等)を
#   この中で回す。ホストの docker.sock は渡さない＝この箱の中で完結（compose は privileged）。
#   gosu は entrypoint で root→node に降格するため。node を docker グループに入れて
#   降格後も dockerd のソケットに届くようにする（socket の group は docker）。
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg \
       -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
       > /etc/apt/sources.list.d/docker.list \
    && apt-get update && apt-get install -y --no-install-recommends \
       docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
       gosu iptables \
    && rm -rf /var/lib/apt/lists/* \
    && usermod -aG docker node

WORKDIR /work/loop
# 箱(Dockerfile/compose/docs/.git)ではなく本体だけを取り込む。
# app/ の中身が /work/loop 直下になるので LOOP_DIR=/work/loop で従来のパスが不変。
COPY app/ /work/loop
RUN chmod +x bin/*.sh bin/loop-report triggers/*.sh 2>/dev/null || true

# ── 非 root 実行のための配線 ──
#   claude --dangerously-skip-permissions は root では拒否される（セキュリティ上の仕様）。
#   base image の node ユーザ(uid 1000)で動かす。ホストの ./.loop(uid 1000) とも一致。
#   loop-report は root のうちに PATH へ通す（node は /usr/local/bin に書けないため）。
RUN ln -sf /work/loop/bin/loop-report /usr/local/bin/loop-report \
    && mkdir -p /work/repo /work/claude-home \
    && chown -R node:node /work

# gh ラッパー: 実 gh の手前(/usr/local/bin が PATH 優先)に置き、毎回フレッシュな
#   トークンを GH_TOKEN に注入してから実 gh を exec する。これで Claude セッション・
#   poller・driver いずれの `gh` 呼び出しも、App の短命トークン失効を意識せず使える。
RUN printf '%s\n' '#!/usr/bin/env bash' \
      'export GH_TOKEN="$(/work/loop/bin/gh-token.sh 2>/dev/null)"' \
      'exec /usr/bin/gh "$@"' > /usr/local/bin/gh \
    && chmod +x /usr/local/bin/gh

# ── 起動の入口は root の entrypoint ──
#   dind の dockerd だけ root で起こし、即 gosu で node に降格して supervisor を回す
#   （root で動くのは dockerd ただ1つ＝権限の最小化）。USER は指定しない＝root 開始。
#   ゾンビ刈り・シグナル処理は compose の init:true(tini) に任せる。
CMD ["./bin/entrypoint.sh"]
