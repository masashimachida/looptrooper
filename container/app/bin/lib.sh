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
    # attachment の fallback は OS のプッシュ通知プレビュー用の要約。これが無いと
    # 内容が attachments/blocks の中だけにあり、通知欄に出せず "[no preview available]"
    # になる。fallback は通知・非リッチクライアント専用でチャンネル本文には重複表示されない
    # （本文は下の blocks が担う）。色付きサイドバー(attachments)もそのまま維持。
    { attachments: [ {
        color: $color,
        fallback: $text,
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

# TRUSTED_ASSOCIATIONS（空白区切り）を jq の配列リテラルに変換する。
#   例: "OWNER MEMBER COLLABORATOR" → ["OWNER","MEMBER","COLLABORATOR"]
#   poll-gh（awaiting 解除）と poll-pr（レビュー検知）が --argjson で jq に渡し、
#   author_association がこの集合に入るコメント/レビューだけを「人間の指示」と認める。
trusted_assoc_jq() {
  local out="" a
  for a in ${TRUSTED_ASSOCIATIONS:-}; do out="$out\"$a\","; done
  printf '[%s]' "${out%,}"
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

# 間隔指定("30m"/"2h"/"90s"/"45"=分) を秒に変換。不正なら 1 を返す。
to_seconds() {
  local v="$1" n u
  n="${v%[smhd]}"; u="${v#"$n"}"
  [[ "$n" =~ ^[0-9]+$ ]] || return 1
  case "$u" in
    s) echo "$n";;
    h) echo $(( n * 3600 ));;
    d) echo $(( n * 86400 ));;
    m|"") echo $(( n * 60 ));;     # 単位なしは「分」（"⚪分間隔"の既定）
    *) return 1;;
  esac
}

# 間隔スケジュールの発火判定（前回から指定間隔以上たっていれば true=0 を返し lastrun を更新）。
#   $1 = state キー（例 gh, deps）, $2 = 間隔指定（"30m"/"2h"/"90s"/"45"=分）。
due_every() {
  local key="$1" spec="$2" f now last secs
  secs=$(to_seconds "$spec") || { log warn "poll $key: 不正な間隔指定 '$spec'（例: 30m/2h/90s/45）"; return 1; }
  f="$STATE_DIR/poll-$key.lastrun"
  now=$(date +%s); last=$(cat "$f" 2>/dev/null || echo 0)
  [ $((now - last)) -ge "$secs" ] || return 1
  echo "$now" > "$f"
  return 0
}

# ── cron 書式スケジュール（cron デーモンには依存せず、書式だけ自前 bash で評価する）──
# 単一フィールドのマッチ。$1=フィールド式（* / a / a-b / a,b / */s / a-b/s）, $2=現在値, $3=*用の最小値。
_cron_field() {
  local spec="$1" cur="$2" min="$3" part lo hi step parts
  cur=$((10#$cur))
  IFS=',' read -ra parts <<< "$spec"   # read -ra はカンマ分割のみ（* を glob しない）
  for part in "${parts[@]}"; do
    step=1
    [[ "$part" == */* ]] && { step="${part#*/}"; part="${part%/*}"; }
    if   [ "$part" = "*" ];    then lo="$min"; hi=999999
    elif [[ "$part" == *-* ]]; then lo="${part%-*}"; hi="${part#*-}"
    else                            lo="$part"; hi="$part"; fi
    lo=$((10#$lo)); hi=$((10#$hi)); step=$((10#$step))
    [ "$cur" -ge "$lo" ] && [ "$cur" -le "$hi" ] && [ $(( (cur - lo) % step )) -eq 0 ] && return 0
  done
  return 1
}

# 5フィールドの cron 式が現在時刻にマッチするか。$1="分 時 日 月 曜"（曜は0-6, 0=日）。
#   dom/dow は AND 判定（標準 cron の OR 例外までは踏襲しない＝直感どおり両方一致で発火）。
cron_match() {
  local mi h dom mon dow
  read -r mi h dom mon dow <<< "$1"
  [ -n "$dow" ] || { log warn "cron 式は5フィールド必須: '$1'"; return 1; }
  _cron_field "$mi"  "$(date +%M)" 0 || return 1
  _cron_field "$h"   "$(date +%H)" 0 || return 1
  _cron_field "$dom" "$(date +%d)" 1 || return 1
  _cron_field "$mon" "$(date +%m)" 1 || return 1
  _cron_field "$dow" "$(date +%w)" 0 || return 1
  return 0
}

# cron スケジュールの発火判定（マッチする「分」に1回だけ true=0 を返す）。$1=key, $2=cron式。
#   poller は POLL_TICK ごとに起きてこれを呼ぶ。同じ分での重複発火は lastmin で防ぐ。
due_cron() {
  local key="$1" expr="$2" f nowmin last
  cron_match "$expr" || return 1
  f="$STATE_DIR/poll-$key.lastmin"
  nowmin=$(date +%Y%m%d%H%M); last=$(cat "$f" 2>/dev/null || echo "")
  [ "$nowmin" = "$last" ] && return 1   # この分は既に走った
  echo "$nowmin" > "$f"
  return 0
}

# タスク id → issue タイトル（通知に添える）。タスクファイル1行目 "# issue #N: <title>" から拾う。
#   先頭の "# " と "issue #N: " 接頭辞を剥がしてタイトルだけ返す。無ければ空。
task_title() {
  local id="$1" f
  for f in "$QUEUE_DIR/$id.md" "$AWAITING_DIR/$id.md" "$PROCESSED_DIR/$id.md" "$BLOCKED_DIR/$id.md"; do
    [ -f "$f" ] || continue
    head -1 "$f" | sed -E 's/^#+[[:space:]]*//; s/^issue #[0-9]+:[[:space:]]*//'
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

# pane が idle（プロンプトに復帰）になるまで最大 timeout 秒待つ。idle で 0、超過で 1。
#   タスク境界で clear/注入する前に呼ぶ。完了判定は result ファイル（loop-report）だが、
#   Claude はファイルを書いた後も締めの出力を続ける＝ファイル出現＝idle ではない。
#   ここで idle を待たずに /clear を撃つと前タスクの生成中に刺さって取りこぼし、
#   文脈が消えない（ユーザー体感「clear が効いてない」）レースになるため、必ず待つ。
wait_idle() {
  local timeout="${1:-30}" start=$SECONDS
  while ! is_idle; do
    [ $((SECONDS - start)) -ge "$timeout" ] && return 1
    sleep 1
  done
  return 0
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
  # working 判定（＝詰まりではない）。順に:
  #   (a) 生成中           : 'esc to interrupt'
  #   (b) 背景エージェント待ち: メインスレッドはバックグラウンドのサブエージェント
  #       （verify-runner 等）の完了を待って静止する＝画面が動かず esc も出ないが crash/hung ではない。
  #       これを hung と誤判定して無言再キューしていた（実際は作業中）ので working に含める。
  #   (c) 画面が変化        : a != b（スピナーのカウンタ更新等）
  elif grep -qi 'esc to interrupt' <<<"$b" \
       || grep -qiE 'background agent|waiting for [0-9]+ (background )?agent' <<<"$b" \
       || [ "$a" != "$b" ]; then echo working
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

# タスク間でセッションの会話文脈をリセットする（Claude Code の /clear を注入）。
#   タスクは互いに独立（worktree 隔離・issue 駆動・各タスクが開始時に .loop/memory を読む）で、
#   タスクを跨ぐ知識は会話履歴ではなく .loop/memory のファイルに置く設計＝履歴を捨てても次タスクは
#   メモリを読み直して同じ状態から始められる。これで累積文脈による毎タスクの入力トークン増
#   （会話が伸びるほど二次関数的に増える）とオートコンパクト費を断つ＝コスト最適化。
#   ※pane が idle（プロンプト）の時に呼ぶこと。/clear はスキルの利用可否には影響しない
#     （次の「次のタスクを処理して」で loop-task は通常どおり起動する）。
# pane を idle（プロンプト復帰）へ追い込む。**待たずに割る**のが要点:
#   loop-report が result を書いた時点でタスクは完了済み＝その後の締め narration や
#   周期アンケートのポップアップは**使い捨て**。礼儀正しく idle を待つと（旧 wait_idle）
#   締め出力が長い／アンケートが居座ると上限まで待って結局 /clear を生成中に撃ち込み飲まれた。
#   そこで Escape で締め出力を中断・ポップアップを退避しながら idle を確認する。idle で 0。
settle_pane() {
  local tries="${1:-6}"
  while [ "$tries" -gt 0 ]; do
    is_idle && return 0
    tmux send-keys -t "$TMUX_SESSION" Escape 2>/dev/null || true   # 生成中なら中断・ポップアップなら退避
    sleep 0.6
    tries=$((tries-1))
  done
  is_idle
}

# /clear が着地（＝会話文脈がクリアされた）かを実用判定する。
#   既知の失敗＝「/clear が入力欄に未送信のまま残留」。よって idle かつ末尾入力欄に
#   "/clear" 残留が無ければ着地とみなす（成功時は composer が空＝末尾に出ない）。
cleared() {
  is_idle || return 1
  ! pane_text | tail -3 | grep -q '/clear'
}

# タスク間でセッションの会話文脈をリセットする（Claude Code の /clear を注入）。
#   タスクは互いに独立（worktree 隔離・issue 駆動・各タスクが開始時に .loop/memory を読む）で、
#   タスクを跨ぐ知識は会話履歴ではなく .loop/memory のファイルに置く設計＝履歴を捨てても次タスクは
#   メモリを読み直して同じ状態から始められる。これで累積文脈による毎タスクの入力トークン増
#   （会話が伸びるほど二次関数的に増える）とオートコンパクト費を断つ＝コスト最適化。
#   要点: 前タスクの締め出力は使い捨てなので**待たず Escape で割って**確実に /clear を着地させ、
#         着地を検証して未着地なら撃ち直す（旧版は idle を待ち切れず /clear を飲まれていた）。
clear_context() {
  # 1) pane を確実にプロンプトへ戻す（締め出力・ポップアップは使い捨て＝待たず Escape で割る）。
  settle_pane "${CLEAR_SETTLE_TRIES:-6}" || log warn "clear: pane を idle に戻せないまま /clear を試行する"
  # 2) /clear を撃つ→着地を検証→未着地なら撃ち直す。
  #   入力欄に被さる interstitial（周期アンケート "How is Claude doing this session?" や
  #   スラッシュ補完ポップアップ）があると Enter がそちらに吸われ /clear が未送信で残る実害が
  #   あったため、毎試行 Escape で退避してから打つ。
  local tries="${CLEAR_RETRIES:-2}"
  while :; do
    tmux send-keys -t "$TMUX_SESSION" Escape
    sleep 0.3
    tmux send-keys -t "$TMUX_SESSION" -l "/clear"
    sleep 0.3
    tmux send-keys -t "$TMUX_SESSION" Enter
    sleep "${CLEAR_SETTLE:-1}"   # /clear 後にプロンプトが戻るのを待つ
    cleared && return 0
    tries=$((tries-1))
    [ "$tries" -le 0 ] && break
    log warn "clear: /clear が着地せず再試行（残り ${tries}）"
    settle_pane 3 || true
  done
  log warn "clear: /clear の着地を確認できず（文脈が残った可能性）"
  return 1
}

# タスク境界で「設定された後始末フック」を必ず1回走らせる（成否・timeout・crash いずれでも）。
#   driver は中身を知らない＝スタック非依存。何を掃除するか（例: 内側 dind の残コンテナ/イメージ/
#   ボリュームの prune）は $BETWEEN_TASKS_CMD（config/loop.yaml）に置く＝docker 知識は config 側だけ。
#   狙い: verify で box が上げた stack（worktree 名=compose プロジェクト名ごとの固有イメージ~2GB＋
#   postgres/匿名ボリューム）が、agent の crash/timeout で後始末されず累積するのを、box が境界で保証して断つ。
#   未設定なら no-op（dind を使わない target では何もしない）。**タスク間でのみ呼ぶこと**（実行中の検証 stack を消さない）。
# 中断タスクの残骸 worktree/ブランチを掃除する（再キュー前提）。
#   crash/timeout で中断したタスクは worktree（`loop/<id>` ブランチ）を後始末せず
#   残す。同一 id で再キューすると loop-task の `git worktree add -b loop/<id>` が
#   「branch already exists」で決定的に失敗し、LLM が復旧にもがいて時間を溶かし
#   →また殺される無限クラッシュループに陥る（実際に踏んだ）。再着手は新しい素の
#   worktree でやり直す設計なので、残骸はここで確実に消す＝LLM の対処運に依存せず
#   構造で断つ（番人は素の bash）。worktree dir は claude が任意に選ぶので、
#   ブランチ名 `loop/<id>` から逆引きして除去する。
clean_stale_worktree() {
  local id="$1" repo="${TARGET_REPO_DIR:-/work/repo}" branch="loop/$id" wt
  [ -d "$repo/.git" ] || return 0
  command -v git >/dev/null 2>&1 || return 0
  # ブランチ `loop/<id>` を checkout している worktree を逆引き
  wt=$(git -C "$repo" worktree list --porcelain 2>/dev/null \
        | awk -v b="refs/heads/$branch" '
            /^worktree /{w=substr($0,10)} /^branch /{if($2==b) print w}')
  if [ -n "$wt" ]; then
    git -C "$repo" worktree remove --force "$wt" 2>/dev/null \
      && log recover "stale worktree 除去: $wt ($branch)" \
      || log warn "stale worktree 除去に失敗: $wt ($branch)"
  fi
  git -C "$repo" worktree prune 2>/dev/null
  if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$repo" branch -D "$branch" 2>/dev/null \
      && log recover "stale ブランチ削除: $branch" \
      || log warn "stale ブランチ削除に失敗: $branch"
  fi
}

run_between_tasks() {
  [ -n "${BETWEEN_TASKS_CMD:-}" ] || return 0
  log info "between-tasks cleanup フックを実行"
  timeout "${BETWEEN_TASKS_TIMEOUT:-120}" bash -lc "$BETWEEN_TASKS_CMD" >/dev/null 2>&1 \
    || log warn "between-tasks cleanup が非ゼロ終了（無視して継続）"
}

# タスク境界で、claude が起動したまま残った子孫プロセス（dev サーバ/watcher/run_in_background の
# bash 等）を刈る。claude 本体・pane shell・tmux・dockerd・番人は一切触らない。
#   Escape はタスクの生成を止めるだけ＝子プロセスは生き残る。timeout はキューが空だと次タスクの
#   /clear が来ず無期限に居座るため、境界で確実に回収する。docker 経由の残骸は run_between_tasks が拾う。
#   境界では claude は idle（報告/clear 済み）＝正当な子は無い → 子孫＝漏れと断定できる。
#   **タスク間でのみ呼ぶこと**（実行中タスクの子プロセスを巻き込まない）。
#   nohup/setsid で PID 1 に再養子された孤児は子孫から外れて取り逃すが、それは入口（settings.json
#   deny）で塞ぐ＝出入口の二段構え。
reap_task_procs() {
  [ "${REAP_BETWEEN_TASKS:-true}" = true ] || return 0
  local cpid; cpid=$(pgrep -f 'claude --dangerously-skip-permissions' 2>/dev/null | head -1)
  [ -n "$cpid" ] || return 0
  # claude(cpid) の子孫を BFS で集める（claude 本体は含めない）。
  local descendants="" frontier="$cpid" next p child
  while [ -n "$frontier" ]; do
    next=""
    for p in $frontier; do
      for child in $(pgrep -P "$p" 2>/dev/null); do
        descendants="$descendants $child"; next="$next $child"
      done
    done
    frontier="$next"
  done
  descendants="${descendants# }"
  [ -n "$descendants" ] || return 0
  log info "reap: claude(pid=$cpid) の残存子孫を刈る: $descendants"
  kill -TERM $descendants 2>/dev/null || true
  sleep "${REAP_GRACE:-2}"
  kill -KILL $descendants 2>/dev/null || true
}
