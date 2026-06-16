#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# 共有関数。各スクリプトが config.sh の後に source する。
# ※雛形（未テスト）。対象 repo 接続時に実地で通すこと。
# ─────────────────────────────────────────────────────────────

log() {
  local level="${1:-info}"; shift
  printf '%s [%s] %s\n' "$(date +%FT%T)" "$level" "$*" >> "$LOGS_DIR/driver.log"
}

notify() {
  local msg="$1"
  log notify "$msg"
  if [ -n "${NOTIFY_CMD:-}" ]; then
    printf '%s' "$msg" | bash -c "$NOTIFY_CMD" >/dev/null 2>&1 || true   # 明示オーバーライド（Discord 等）
  elif [ -n "${SLACK_WEBHOOK_URL:-}" ]; then
    slack_post "$msg" || true                                           # Slack はリッチ整形で送る
  fi
}

# Slack Incoming Webhook へ Block Kit の attachment でリッチに送る。
#   - 先頭絵文字から重大度を判定し、サイドバーの色を変える（緑/青/黄/赤）。
#   - 本文は mrkdwn セクション。GitHub の PR/issue URL は linkify で <url|PR #N> /
#     <url|#N> のリンク形式に変換（生 URL を貼らない）。
#   - コンテキスト行に対象 repo と時刻を添える。
# jq でペイロードを組み立てる＝引用符/改行/絵文字を安全にエスケープ。
slack_post() {
  local msg="$1" color slug ctx
  case "$msg" in
    ✅*)        color="#2eb67d";;   # 成功（緑）
    🚀*|⏳*|🔧*) color="#36c5f0";;   # 進行/情報（青）
    ❓*|⚠️*)     color="#ecb22e";;   # 要注意/要対応（黄）
    🛑*|⛔*)     color="#e01e5a";;   # 致命/ブロック（赤）
    *)          color="#9aa0a6";;   # その他（グレー）
  esac
  slug=$(target_slug)
  ctx="🔁 loop"; [ -n "$slug" ] && ctx="$ctx · 📦 $slug"
  ctx="$ctx · 🕒 $(date +%FT%T%z)"
  jq -n --arg text "$msg" --arg color "$color" --arg ctx "$ctx" '
    # GitHub の PR/issue URL を Slack のリンク形式に。/pull/N→PR #N、/issues/N→#N。
    def linkify:
      gsub("(?<u>https?://[^\\s|()]+/pull/(?<n>[0-9]+))"; "<\(.u)|PR #\(.n)>")
      | gsub("(?<u>https?://[^\\s|()]+/issues/(?<n>[0-9]+))"; "<\(.u)|#\(.n)>");
    { attachments: [ {
        color: $color,
        blocks: [
          { type: "section", text: { type: "mrkdwn", text: ($text | linkify) } },
          { type: "context", elements: [ { type: "mrkdwn", text: $ctx } ] }
        ]
    } ] }' \
  | curl -s -X POST -H 'Content-type: application/json' -d @- "$SLACK_WEBHOOK_URL" >/dev/null 2>&1
}

# ── GitHub URL ヘルパ（通知にできるだけ URL を添えるため）──
# 対象 repo の owner/name slug を解決（解決後はキャッシュ）。失敗時は空。
target_slug() {
  if [ -z "${_TARGET_SLUG:-}" ]; then
    _TARGET_SLUG=$(git -C "$TARGET_REPO_DIR" remote get-url origin 2>/dev/null \
                   | sed -E 's#.*github\.com[:/]##; s#\.git$##')
  fi
  printf '%s' "${_TARGET_SLUG:-}"
}

# issue 番号 → GitHub issue URL（slug か番号が無ければ空文字）。
issue_url() {
  local n="$1" slug; slug=$(target_slug)
  [ -n "$slug" ] && [ -n "$n" ] && printf 'https://github.com/%s/issues/%s' "$slug" "$n"
}

# タスク id（=タスクファイル）に紐づく issue 番号を拾う。無ければ空。
#   入力は issue 限定なので本文に必ず "issue #N" が含まれる（enqueue/poll-gh が書く）。
task_issue() {
  local id="$1" f
  for f in "$QUEUE_DIR/$id.md" "$AWAITING_DIR/$id.md" "$PROCESSED_DIR/$id.md" "$BLOCKED_DIR/$id.md"; do
    [ -f "$f" ] || continue
    grep -oE 'issue #[0-9]+' "$f" | head -1 | grep -oE '[0-9]+'
    return
  done
}

# タスクに紐づくタイムアウト秒（チェックポイントまでの待ち）。タスクファイルに
# "task_timeout: <秒>" があればそれ（loop:long の issue 用に poll-gh が書く）、無ければ既定 TASK_TIMEOUT。
task_timeout() {
  local id="$1" f v=""
  for f in "$QUEUE_DIR/$id.md" "$AWAITING_DIR/$id.md" "$PROCESSED_DIR/$id.md" "$BLOCKED_DIR/$id.md"; do
    [ -f "$f" ] || continue
    v=$(grep -oE 'task_timeout:[[:space:]]*[0-9]+' "$f" | head -1 | grep -oE '[0-9]+')
    break
  done
  echo "${v:-$TASK_TIMEOUT}"
}

# tmux pane の生テキスト取得。判断（成否）には使わない ── liveness / stuck 分類専用。
pane_text() { tmux capture-pane -p -t "$TMUX_SESSION" 2>/dev/null; }
pane_cmd()  { tmux display -p -t "$TMUX_SESSION" '#{pane_current_command}' 2>/dev/null; }

# Claude がアイドル（入力待ち）か。注入前の belt-and-suspenders。
is_idle() {
  local a b
  a=$(pane_text | tail -8); sleep 0.6; b=$(pane_text | tail -8)
  [ "$a" = "$b" ] && ! grep -qi 'esc to interrupt' <<<"$b"
}

# result file(=sentinel) の出現を待つ。timeout で 1 を返す。
wait_result() {
  local id="$1" timeout="$2" waited=0
  while [ ! -f "$RESULTS_DIR/$id.json" ]; do
    sleep 2; waited=$((waited+2))
    [ "$waited" -ge "$timeout" ] && return 1
  done
  return 0
}

# 「遅い」と「詰まった」を区別: working|limit|modal|crashed|hung
#
# modal 誤検知の防止（重要）:
#   許可モーダルは「生成が止まって画面が静止し、末尾に選択肢UIが出る」状態。
#   逆に 'esc to interrupt' が出ている＝生成中なら、モーダルは原理的に存在し得ない。
#   そこで modal は (1) 生成中でない (2) pane 末尾に許可フレーズ (3) 同末尾に選択肢UI(❯ / "1. Yes" 等)
#   の3条件を全て満たす時だけに限定する。pane 全体を緩い語で grep すると、実装中の
#   Claude 出力（コード・説明文に "permission to" 等が混入）を modal と誤判定し、
#   延長なしで blocked に落としてしまうため。
classify_stuck() {
  local a b tl
  a=$(pane_text); sleep "$STUCK_RECHECK"; b=$(pane_text)
  # modal 判定の前に常駐クローム行を除外する（重要）:
  #   Claude Code のフッター "Auto-update failed: no write permission to npm prefix" は
  #   "permission to" を含むため、idle 時（API 500 等で生成停止）にこの行を拾って
  #   許可モーダルと誤判定し、偽 blocked に落としていた。"bypass permissions on" の
  #   ステータス行も同類なので落とす。これらは状態判定に無関係な装飾。
  tl=$(tail -12 <<<"$b" | grep -vE 'no write permission to npm prefix|Auto-update failed|bypass permissions on')
  if   grep -qiE 'usage limit|resets at|rate limit' <<<"$b"; then echo limit
  elif ! grep -qiE '\b(claude|node)\b' <<<"$(pane_cmd)"; then echo crashed
  elif ! grep -qi 'esc to interrupt' <<<"$b" \
       && grep -qiE 'do you want|allow this|grant this|permission to' <<<"$tl" \
       && grep -qE '❯|[0-9]+\. (Yes|No|Allow|Don)' <<<"$tl"; then echo modal
  elif grep -qi 'esc to interrupt' <<<"$b" || [ "$a" != "$b" ]; then echo working
  else echo hung
  fi
}

# usage limit のバックオフ。画面から時刻が拾えれば使う余地あり（今は固定）。
sleep_until_reset() {
  log limit "usage limit hit; backing off ${USAGE_BACKOFF}s"
  notify "⏸ usage limit によりループ一時停止（${USAGE_BACKOFF}秒バックオフ）"
  sleep "$USAGE_BACKOFF"
}

# 短い固定フレーズだけ注入する（本文はタスクファイル側）。text と Enter は分けて送る。
inject() {
  local phrase="$1"
  tmux send-keys -t "$TMUX_SESSION" -l "$phrase"
  sleep 0.3
  tmux send-keys -t "$TMUX_SESSION" Enter
}
