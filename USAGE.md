# USAGE — LoopTrooper の使い方

実際に動かすための手順書。設計の背景は [README.md](./README.md) を参照。

> ⚠️ これは**雛形**。初回起動時に「tmux画面ヒューリスティクス」「サブスク初回ログイン」「トリガ配線」を実地で詰める前提。

---

## 前提

- Docker / Docker Compose
- 保守対象の GitHub リポジトリ（private 可）
- **GitHub App**（推奨）または repo単位 fine-grained PAT（後述の権限/スコープ）
- Claude のサブスク（Pro / Max）

---

## 1. 初回セットアップ

### 1-1. 設定は `.env` に集約（gitignore 済み・再ビルド不要）
対象ごとに変える値と秘密は **`.env` に集約**。`docker-compose.yml` の `env_file: .env` で丸ごとコンテナに注入される。
```bash
cp .env.example .env   # → 認証（GitHub App か GH_TOKEN）と対象の値を埋める
```
`.env` の中身（`.env.example` 参照）:
```dotenv
TARGET_REPO_URL=https://github.com/you/repo.git
BUILD_CMD=npm run build
TEST_CMD=npm test
LINT_CMD=npm run lint
ANTHROPIC_MODEL=claude-sonnet-4-6   # claude のモデル（任意。既定 Sonnet / 難所中心なら claude-opus-4-8）
GIT_USER_NAME=loop-bot
GIT_USER_EMAIL=loop-bot@users.noreply.github.com
TZ=Asia/Tokyo

# 認証は次のどちらか（App 推奨）:
# (A) GitHub App ── 短命 token を自動発行。秘密鍵 PEM は base64 -w0 した1行を貼る
GITHUB_APP_ID=123456
GITHUB_APP_PRIVATE_KEY_B64=LS0tLS1CRUdJTi...（1行）
# (B) 静的トークン（PAT / machine user）── App 系が未設定のときだけ使われる
# GH_TOKEN=github_pat_xxxxxxxx
```
> 秘密（App 秘密鍵 / GH_TOKEN）は `.env` だけに置き、`config.sh` には絶対書かない。
> 認証トークンの供給は `bin/gh-token.sh` が一元化（App=発行+キャッシュ / 静的=そのまま）。
> `env_file: .env` がこれらをコンテナ env に注入し、`config.sh` の `${VAR:-default}` を上書きする。
> `BUILD_CMD/TEST_CMD/LINT_CMD` は Claude(Verifier)セッションにも env として継承されるので `$TEST_CMD` でそのまま使える。
> 派生パスやチューニング定数（`POLL_INTERVAL` 等）の既定値は `config.sh` 側。変えたい時だけ `.env` で上書き。
> ⚠️ `.env` だけ作っても **`env_file:` で参照しないとコンテナに入らない**（`.env` 単体は compose ファイルの変数置換用）。

### 1-2. GitHub 側の安全装置
- 対象 repo の `main` に **branch protection**: PR必須・force push禁止・削除禁止
- **GitHub App の権限**（または PAT のスコープ。対象 repo 1個だけに付与）:
  | 権限 | 用途 |
  |---|---|
  | Contents: Read and write | `git push`（loop/* ブランチ） |
  | Pull requests: Read and write | `gh pr create` |
  | Issues: Read and write | issue 駆動トリガ＋コメント＋**依存(blocked_by)の参照** |
  | Metadata: Read | 必須 |
  - `merge` 用の権限は付けない（トークンレベルでもマージ不可）

### 1-3. ビルド & 起動
```bash
docker compose build
docker compose up -d
```
起動すると supervisor が `setup-target.sh` を自動実行 → clone + 認証配線 + 設定流し込み。

### 1-4. Claude のサブスク初回ログイン（初回だけ）
```bash
docker compose exec -u node loop tmux attach -t loop
#  → claude の画面で /login して認証 → 完了したら Ctrl-b を押して d で detach
```
認証情報は `claude-home` volume に永続化されるので、以降の再起動では不要。

### 1-5. 動作確認（スモークテスト）
タスク入力は **'loop' ラベル付き issue に限定**しているので、対象 repo に issue を立てて流す:
```bash
# 対象 repo に loop ラベルの issue を作成（例: typo 修正）
gh issue create -R <owner>/<repo> --label loop \
  --title "smoke test" --body "READMEのtypoを1つ直してfeatureブランチでPRを開いて"

# 次の poll を待つ（または手動で1回ポーリング）
docker compose exec -T -u node loop ./triggers/poll-gh.sh
docker compose exec -u node loop tail -f .loop/logs/driver.log
```
PR が立てば一周完走。`app/LOOP_STATE.md` / 通知に「PR ready」が出る。

---

## 2. タスクの流れ（何が起きるか）

```
enqueue → .loop/queue/<id>.md
   driver が固定フレーズ注入 → Claude(SKILL.md手順)
     worktree隔離 → Fixer実装 → Verifier(別agent)検証 → push(loop/<id>) → gh pr create
   loop-report → .loop/results/<id>.json
   driver がルーティング:
     done    → .loop/processed/  +「PR ready」通知
     skipped → .loop/processed/  （空振り。安い）
     failed  → .loop/blocked/    + ⚠️通知
     blocked → .loop/blocked/    + ⚠️通知
```
**マージは必ず人間**。ループは PR 提案で止まる。

---

## 3. タスクの入れ方（issue 駆動のみ）

タスク入力は **GitHub issue に限定**している。対象 repo の issue に `loop` ラベルを付けると、
poller がそれを拾ってタスク化する。これが唯一の入力源。

ポーリングは supervisor 配下の `poller.sh` が常駐で回す（cron 不要）。間隔は `config.sh` の
`POLL_GH_INTERVAL`（既定 900 秒。`.env` で上書き可。本リポジトリは 300 秒＝5分に設定）。
（冪等: 既処理の issue は再投函しない。要件が曖昧なら bot が issue に質問し回答待ちになる）

**依存関係（順序制御）**: GitHub ネイティブの issue dependencies（"blocked by"）に対応。
issue B を issue A で "blocked by" 設定すると、A が完了して閉じる（closed かつ not_planned 以外）まで
B は着手されない。ブロック中は `issue-<N>.blocked` を立てて1回だけ ⛔ 通知し、依存が解けた周回で自動着手する。

**PR レビュー往復**: ループが開いた PR に**人間が changes-requested レビュー**を付けると、`poll-pr.sh` が
それを検出し「指摘対応タスク」を投函。ループは**既存ブランチに修正を push**して PR を更新する（新規 PR は作らない）。
同じ指摘では再発火せず、新しい changes-requested を出すと再対応する（GitHub App により bot/人間を author で判別）。

**依存脆弱性の自動起票**: `poll-deps.sh`（既定24hごと）が `AUDIT_CMD`（既定 `npm audit --json`）で監査し、
high/critical かつ修正版がある脆弱性を**自動で issue 化**。非メジャー修正は `loop`（実装〜PRまで自走）、
メジャー（破壊的）修正は `loop:proposed`（あなたが `loop` を付けて承認したら着手）。重複起票はしない／1回 `DEPS_MAX_PER_RUN` 件まで。

**再着手（やり直し）**: 既処理の issue をもう一度やってほしいときは、**issue に `loop:redo` ラベルを付けるだけ**
（GitHub UI / iOS でタップ）。ファイル操作は不要。poller が状態をクリアして再投入し、ラベルは1回で外す。
マージ後に revert / 再オープンが起きると ⚠️ 通知が出るので、必要なら `loop:redo` を付けて再対応させる。

> `enqueue.sh` は poller 専用の内部プリミティブで、`LOOP_SOURCE`（`issue` / `pr-review`）が無いと拒否する。
> 手動投函・git hook 等の入力は受け付けない（事故防止）。

---

## 4. 監視

まずは**一括ダッシュボード**を見れば、番人/認証/タスク/GitHub/メモリ/アウトカム/直近通知が一目で分かる:
```bash
docker compose exec -u node loop ./bin/status.sh
```

個別に追うとき:

| 見るもの | コマンド / 場所 |
|---|---|
| 一括ダッシュボード | `docker compose exec -u node loop ./bin/status.sh` |
| 判断系ログ | `docker compose exec -u node loop tail -f .loop/logs/driver.log` |
| 生ストリーム（forensics） | `.loop/logs/session.log` |
| Claude の画面を覗く | `docker compose exec -u node loop tmux attach -t loop`（detach: Ctrl-b → d） |
| キューの中身 | `docker compose exec -u node loop ls .loop/queue .loop/blocked .loop/processed` |
| ある結果の詳細 | `docker compose exec -u node loop cat .loop/results/<id>.json` |

---

## 5. 日常運用コマンド

```bash
# 一時停止 / 再開（状態は volume に残る）
docker compose stop loop
docker compose start loop

# 停止（volume は残す）
docker compose down
# 完全消去（状態・認証も消える。注意）
docker compose down -v

# blocked タスクを直して再投入
docker compose exec -u node loop mv .loop/blocked/<id>.md .loop/queue/

# 認証の確認（App/静的どちらも gh-token.sh が供給）
docker compose exec -u node loop ./bin/gh-token.sh >/dev/null && echo "token OK"
docker compose exec -u node loop gh api rate_limit --jq .rate   # トークンが有効か実際に叩いて確認
docker compose exec -u node loop git -C /work/repo remote -v

# driver が動いているか
docker compose exec -u node loop pgrep -af driver.sh
```

---

## 6. トラブルシュート

| 症状 | 原因 / 対処 |
|---|---|
| `gh pr create` は通るが `git push` が認証エラー | git credential helper(`gh-token.sh`)未設定 or 認証に Contents:write が無い。`./bin/setup-target.sh` 再実行＋App/PAT の権限確認 |
| `git commit` が "who are you?" | identity 未設定。`config.sh` の `GIT_USER_NAME/EMAIL` → `setup-target.sh` 再実行 |
| タスクが `blocked/` に溜まる（権限） | 許可リスト不足。`.loop/logs` で止まったコマンドを確認し、`/fewer-permission-prompts` or `.claude/settings.json` の allow を追加 |
| ループが進まない・"usage limit" | サブスク上限。driver が自動でリセットまで sleep（`driver.log` に `usage limit`）。待てば再開 |
| セッションが何度も落ちる | crash-loop ブレーカが停止＆通知。多くは **未ログイン**。`tmux attach` で `/login` |
| `is_idle`/`classify_stuck` が誤判定 | Claude Code の表示文言と不一致。`bin/lib.sh` の grep 文字列（`esc to interrupt` 等）を実画面に合わせて調整 |
| タスクが拾われない | driver 未起動 or queue に `.md` が無い。`pgrep -af driver.sh` と `ls .loop/queue` を確認 |
| 起動が idle 待機のまま | `TARGET_REPO_URL` 未設定 or clone 失敗。`.env` と `setup-target.sh` のログ確認 |

---

## 7. 設定リファレンス（`config.sh` 主要変数）

| 変数 | 意味 |
|---|---|
| `TARGET_REPO_URL` / `TARGET_REPO_DIR` | 対象 repo の URL（HTTPS）/ コンテナ内 clone 先 |
| `BUILD_CMD` / `TEST_CMD` / `LINT_CMD` | Verifier が回す検証コマンド |
| `ANTHROPIC_MODEL` | claude セッションのモデル（既定 `claude-sonnet-4-6`。難所中心なら `claude-opus-4-8`） |
| `GIT_USER_NAME` / `GIT_USER_EMAIL` | commit の identity |
| `TASK_TIMEOUT` | 1タスクの最大待ち秒（既定 1800） |
| `POLL_INTERVAL` | キュー監視間隔秒（仕事ゼロ＝この sleep だけ＝無課金） |
| `USAGE_BACKOFF` | usage limit 時の sleep 秒 |
| `CRASH_LIMIT` / `CRASH_WINDOW` | crash-loop ブレーカの閾値 |
| `NOTIFY_CMD` | 通知コマンド（stdin でメッセージ受領。空ならログのみ） |

### ディレクトリ
| パス | 役割 |
|---|---|
| `.loop/queue/` | 未処理タスク（`<id>.md`） |
| `.loop/results/` | 結果＝sentinel（`<id>.json`） |
| `.loop/processed/` | 完了（done/skipped） |
| `.loop/blocked/` | 要対応（failed/blocked） |
| `.loop/state/` | in-progress マーカ・トリガの既処理印 |
| `.loop/logs/` | driver.log / session.log |
