#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# 中央設定。全スクリプトが先頭で source する。
# 対象リポジトリが決まったら「未定」の箇所を埋めるだけで動く。
# ─────────────────────────────────────────────────────────────

# ── 非秘密設定を loop.yaml から読み込む（任意。秘密＝App秘密鍵/Slack/GH_TOKEN は .env のまま）──
#   フラットな「ENV_VAR: 値」形式（キー＝環境変数名）。値は1行。
#   優先順位: env（.env / compose）> loop.yaml > 既定。＝既に env にある値（.env の秘密・緊急上書き）が勝つ。
#   yq が無い or ファイルが無ければ何もしない＝従来どおり .env だけで動く（フェイルセーフ）。
#   ※ bash 限定の構文（${!var}・プロセス置換）を使うので bash の時だけ実行する。
if [ -n "${BASH_VERSION:-}" ]; then
  _cfg_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  LOOP_CONFIG_YAML="${LOOP_CONFIG_YAML:-$_cfg_dir/../loop.yaml}"   # 箱レベルの1枚。コンテナでは /work/loop.yaml にマウント
  if [ -f "$LOOP_CONFIG_YAML" ] && command -v yq >/dev/null 2>&1; then
    while IFS='=' read -r _k _v; do
      [ -n "$_k" ] || continue
      [ -z "${!_k:-}" ] && export "$_k=$_v"      # env が空の時だけ YAML 値を採用（env 優先）
    done < <(yq e 'to_entries[] | select(.value != null) | .key + "=" + (.value | tostring)' "$LOOP_CONFIG_YAML" 2>/dev/null)
  fi
fi

# ── 対象リポジトリ（まだ未定。決まったら埋める）──
export TARGET_REPO_URL="${TARGET_REPO_URL:-}"            # 例: https://github.com/you/repo.git（token認証なのでHTTPS）
export TARGET_REPO_DIR="${TARGET_REPO_DIR:-/work/repo}"  # コンテナ内の clone 先
export DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"          # 直 push 禁止の保護対象（GitHub branch protection も併用）
export PR_BASE_BRANCH="${PR_BASE_BRANCH:-$DEFAULT_BRANCH}" # ループが開く PR の向き先（base）。既定は DEFAULT_BRANCH(main)。
                                                        #   develop 等に向けたい時に .env で上書き。作業ブランチ loop/<id> もこの base から切る。
                                                        #   ※ session-keeper が config を source して tmux を起こすので claude セッションに継承される（$BUILD_CMD 等と同経路）。

# ── GitHub 認証（2モード。bin/gh-token.sh が両対応）──
#   推奨: GitHub App（短命 installation token を自動発行・ローテーション）。
#     GITHUB_APP_ID と 秘密鍵（FILE か B64 のどちらか）を .env に入れる。
#     installation id は対象 repo から自動解決（明示したい場合のみ ID を設定）。
#   代替: 静的 GH_TOKEN（PAT / machine user）。App 系が未設定ならこちらを使う。
export GITHUB_APP_ID="${GITHUB_APP_ID:-}"
export GITHUB_APP_PRIVATE_KEY_FILE="${GITHUB_APP_PRIVATE_KEY_FILE:-}"   # PEM のパス（マウント時）
export GITHUB_APP_PRIVATE_KEY_B64="${GITHUB_APP_PRIVATE_KEY_B64:-}"     # PEM を base64 -w0 した1行（.env 向き）
export GITHUB_APP_INSTALLATION_ID="${GITHUB_APP_INSTALLATION_ID:-}"     # 任意。空なら repo から自動解決

# ── git commit の identity（未設定だと git commit が失敗する）──
export GIT_USER_NAME="${GIT_USER_NAME:-loop-bot}"
export GIT_USER_EMAIL="${GIT_USER_EMAIL:-loop-bot@users.noreply.github.com}"

# ── スタック依存コマンド（プレースホルダ。対象に合わせて埋める）──
#   Verifier サブエージェントが実行し、結果を loop-report --verify に渡す。
export BUILD_CMD="${BUILD_CMD:-echo 'TODO: set BUILD_CMD in config.sh'; false}"
export TEST_CMD="${TEST_CMD:-echo 'TODO: set TEST_CMD in config.sh'; false}"
export LINT_CMD="${LINT_CMD:-echo 'TODO: set LINT_CMD in config.sh'; false}"

# ── claude セッションが使うモデル ──
#   env_file 経由でコンテナ env に入り、session-keeper が source した後に tmux を起こすので
#   ペイン内の claude（と同一セッションの Verifier サブエージェント）に継承される。
#   無人ループは長時間・多タスク → 既定は Sonnet（速い・サブスク枠が保つ・usage limit backoff を減らす）。
#   難所中心の対象だけ .env で上書き（例: ANTHROPIC_MODEL=claude-opus-4-8）。
export ANTHROPIC_MODEL="${ANTHROPIC_MODEL:-claude-sonnet-4-6}"

# ── effort（claude の thinking 量。トークン消費に直結）──
#   非空なら `claude --effort <level>` で起動。無人の定型保守は high が過剰なので既定 medium。
#   low は最安だが実装が甘くなり Verifier 不合格→リトライで逆に高くつくことがある。難所中心なら high。
#   有効値: low / medium / high / xhigh / max / auto（空にするとフラグ無し＝claude の既定）。
export EFFORT_LEVEL="${EFFORT_LEVEL:-medium}"

# ── Remote Control（claude セッションをスマホ / claude.ai/code から閲覧・操作する）──
#   非空ならその名前で `claude --remote-control <name>` を有効化（空にすると無効）。
#   アウトバウンドのみ（inbound ポートは開かない＝箱の方針と両立）・サブスク認証で動作・API キーでは不可。
#   注意: 有効時はあなたの Claude アカウントからこの無人 bot を操作できる。タスク処理中は driver の
#   注入と混線するのでスマホからは打たない（pane への書き込みは driver が唯一＝設計の核 #1）。
export REMOTE_CONTROL_NAME="${REMOTE_CONTROL_NAME:-looptrooper}"

# ── 依存脆弱性の自動起票（poll-deps.sh が環境からゴールを生成する）──
#   観測コマンドは差し替え可（出力は npm audit --json 形式を仮定してパースする）。
export AUDIT_CMD="${AUDIT_CMD:-npm audit --json}"   # 監査コマンド（stack に合わせ差替）
export DEPS_INTERVAL="${DEPS_INTERVAL:-86400}"      # 監査間隔秒（既定24h。poll-deps が自己スロットル）
export DEPS_MAX_PER_RUN="${DEPS_MAX_PER_RUN:-2}"    # 1回の実行で作る issue 上限（乱発防止）

# ── main の CI（GitHub Actions）が失敗したら issue 自動起票（poll-ci.sh）──
#   重いテスト（e2e 等）を自前 dind で再現するのではなく、マージを実際にゲートしてる正規環境=
#   CI の結果をそのまま受け取る。サンドボックス由来の偽陽性が出ず計算ゼロ。poll-outcome と同型の継続監視。
#   CI_WORKFLOW が空なら丸ごと skip（＝既定オフ。使うプロジェクトだけ対象ワークフローを指定）。
export CI_WORKFLOW="${CI_WORKFLOW:-}"                  # 監視するワークフロー名 or ファイル名（例: e2e.yml）。空＝無効
export CI_BRANCH="${CI_BRANCH:-$DEFAULT_BRANCH}"       # 監視するブランチ（既定は保護対象ブランチ=main）
export CI_ISSUE_LABEL="${CI_ISSUE_LABEL:-loop:proposed}" # 起票ラベル（既定 proposed＝人間承認後。即修正なら loop）
export CI_ISSUE_LONG="${CI_ISSUE_LONG:-true}"         # 起票時に loop:long も付ける（CI修正は長くなりがち＝timeout由来の再実行を避ける）。false で無効

# ── ループ基盤のパス ──
export LOOP_DIR="${LOOP_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
export TMUX_SESSION="${TMUX_SESSION:-loop}"
export QUEUE_DIR="$LOOP_DIR/.loop/queue"
export PROCESSED_DIR="$LOOP_DIR/.loop/processed"
export BLOCKED_DIR="$LOOP_DIR/.loop/blocked"
export RESULTS_DIR="$LOOP_DIR/.loop/results"
export DONE_DIR="$LOOP_DIR/.loop/done"
export LOGS_DIR="$LOOP_DIR/.loop/logs"
export STATE_DIR="$LOOP_DIR/.loop/state"
export AWAITING_DIR="$LOOP_DIR/.loop/awaiting"   # 曖昧で issue に質問し人間の回答待ちのタスク
export MEMORY_DIR="$LOOP_DIR/.loop/memory"       # ループが蓄積する知識（規約/レビュー嗜好/失敗/アウトカム）。対象 repo の外＝PRに混入しない
export OUTCOMES_DIR="$LOOP_DIR/.loop/outcomes"   # アウトカム観測の台帳（出荷/revert/再オープンのマーカー）
export STATE_BOARD="$LOOP_DIR/LOOP_STATE.md"

# ── タイミング ──
export TASK_TIMEOUT="${TASK_TIMEOUT:-1200}"   # 1 タスクのチェックポイントまでの待ち秒（既定20分）。超過したら延長せず中断させ、経過/理由/方針を自己申告させる（人間トリアージへ）
export TASK_TIMEOUT_LONG="${TASK_TIMEOUT_LONG:-3600}" # loop:long ラベルの issue 用の待ち秒（既定60分）。長時間タスクを許すが無制限ではない（超えればやはり中断・自己申告）
export CHECKPOINT_GRACE="${CHECKPOINT_GRACE:-180}"   # 中断指示後、自己申告(loop-report --status timeout)が返るのを待つ上限秒。来なければ応答不能とみなし crashed 扱いで再キュー
export TRIAGE_GRACE="${TRIAGE_GRACE:-60}"     # 着手通知の猶予秒。この間に skipped で返れば「着手」を通知しない（空振りは静かに）
export POLL_INTERVAL="${POLL_INTERVAL:-5}"    # キュー監視間隔秒（仕事ゼロ＝この sleep だけ＝無課金）
export STUCK_RECHECK="${STUCK_RECHECK:-2}"    # classify_stuck の 2 回キャプチャ間隔
export KEEPER_INTERVAL="${KEEPER_INTERVAL:-15}" # セッション生存チェック間隔
export POLL_GH_INTERVAL="${POLL_GH_INTERVAL:-900}" # issue ポーリング間隔秒（LLM を呼ばない＝安い。既定15分）
export ISSUE_SETTLE_SECS="${ISSUE_SETTLE_SECS:-180}" # 新規 issue の猶予秒。作成直後（依存登録などの配線が未完）の issue は1周見送る＝「作成→ポーリング→依存登録」のレースで未ブロック着手するのを防ぐ

# ── ポーラー capability の有効/無効（プロジェクト毎に取捨）──────────
#   false にすると poller.sh がそのポーラーを丸ごとスキップする（＝そのプロジェクトでは無効化）。
#   poll-gh / poll-pr は主入力源なので既定 on。outcome / deps は任意機能。
#   今後 spec 分解・observer 等を足す時も、この ENABLE_POLL_<NAME> 規約に揃える。
export ENABLE_POLL_GH="${ENABLE_POLL_GH:-true}"           # issue 取得（主入力）
export ENABLE_POLL_PR="${ENABLE_POLL_PR:-true}"           # PR レビュー指摘取得（主入力）
export ENABLE_POLL_OUTCOME="${ENABLE_POLL_OUTCOME:-true}" # マージ後アウトカム観測（revert / issue 再オープン）
export ENABLE_POLL_DEPS="${ENABLE_POLL_DEPS:-true}"       # 依存脆弱性 → issue 自動起票
export ENABLE_POLL_CI="${ENABLE_POLL_CI:-true}"          # main の CI 失敗 → issue 自動起票（CI_WORKFLOW 未設定なら実質無効）

# ── ポーラーの実行スケジュール（任意・ポーラー毎・cron 書式）──────────
#   cron デーモンには依存しない（書式だけ自前 bash=lib.sh の cron_match で毎 tick 評価）。
#     空      → 既定間隔 POLL_GH_INTERVAL ごと（後方互換。deps/ci は中でさらに self-throttle）
#     cron式  → 標準5フィールド「分 時 日 月 曜」（曜 0-6, 0=日）。* / a-b / a,b / */s 対応。
#               例 "*/30 * * * *"=30分毎 / "0 3 * * *"=毎日3時 / "0 9 * * 1-5"=平日9時 / "0 */4 * * *"=4時間毎
#   時刻は TZ（既定 Asia/Tokyo）基準。発火粒度は POLL_TICK。主入力(GH/PR)は短間隔、1日1回系(DEPS/CI)は時刻指定が向く。
export POLL_TICK="${POLL_TICK:-60}"   # poller の基底起床間隔秒（cron は分粒度なので 60s 以下推奨。取りこぼし防止）
export POLL_GH_CRON="${POLL_GH_CRON:-}"
export POLL_PR_CRON="${POLL_PR_CRON:-}"
export POLL_OUTCOME_CRON="${POLL_OUTCOME_CRON:-}"
export POLL_DEPS_CRON="${POLL_DEPS_CRON:-}"
export POLL_CI_CRON="${POLL_CI_CRON:-}"

export BOOT_WAIT="${BOOT_WAIT:-12}"           # claude 起動待ち（driver 開始まで）
export DOCKERD_WAIT="${DOCKERD_WAIT:-30}"     # dind: entrypoint が dockerd 起動完了を待つ上限秒
export LAUNCH_GRACE="${LAUNCH_GRACE:-30}"     # claude 起動完了(前面化)をこの秒数まで待つ＝起動レース誤検知の防止
export USAGE_BACKOFF="${USAGE_BACKOFF:-1800}" # usage limit 時の固定バックオフ秒

# ── crash-loop サーキットブレーカ ──
export CRASH_LIMIT="${CRASH_LIMIT:-3}"        # CRASH_WINDOW 秒内にこの回数死んだら停止
export CRASH_WINDOW="${CRASH_WINDOW:-600}"

# ── 通知（任意。空ならログのみ）──
#   優先順位: NOTIFY_CMD（明示オーバーライド・stdin にメッセージ） > Slack > ログのみ。
#   Slack: .env に SLACK_WEBHOOK_URL を入れるだけで有効化。lib.sh の slack_post() が
#   Block Kit の attachment（先頭絵文字から重大度→色のサイドバー ＋ 本文 mrkdwn ＋
#   repo/時刻のコンテキスト行）でリッチに POST する。URL は Slack が自動リンク。
#   ※NOTIFY_CMD を直接定義すれば上書きできる（Discord なら 'jq -Rsa "{content: .}" | curl ...' 等）。
#     その場合はリッチ整形を通さず、生テキストを stdin で渡す。
export SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"
export NOTIFY_CMD="${NOTIFY_CMD:-}"                  # 明示指定があれば尊重、無ければ空（Slack か ログのみ）
