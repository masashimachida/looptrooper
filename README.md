# LoopTrooper 🫡

**自律的なコード保守ループの基盤。** `loop` ラベルを付けた GitHub issue を入力に、無人のエージェントが worktree 隔離 → 実装 → 検証 → PR 作成までを行う。マージは人間が行う。

このドキュメントは LoopTrooper を**ゼロから動かすための手順書**。設計の背景・仕組み・用語は [`doc/`](./doc/) を参照:

- [doc/architecture.md](./doc/architecture.md) — なぜこの形か（外部トリガ駆動・5つの罠・3層構造・dind・コスト）
- [doc/mechanism.md](./doc/mechanism.md) — タスクのライフサイクルとトリガ仕様（issue/PR/deps/ci/spec/outcome・依存関係・redo/long・メモリ）
- [doc/glossary.md](./doc/glossary.md) — 用語集（ドライバ・番人・Fixer/Verifier・dind 等の固有語）

---

## 前提（必須要件）

ホスト（コンテナを動かすマシン）に必要なもの:

- **Docker Engine 24.0 以上** — 内側で dind / BuildKit を使うため。`privileged` コンテナを動かせること
- **Docker Compose v2.20 以上**（`docker compose` サブコマンド形式）
- **bash**（loopctl はホストで動く。macOS 標準の bash 3.2 でも可）
- **git 2.5 以上**（任意。loopctl をこのリポジトリから clone する場合）

アカウント・対象側に必要なもの:

- **保守対象の GitHub リポジトリ**（private 可）。LoopTrooper 本体とは別物で、コンテナ内 `/work/repo` に clone される
- **GitHub App**（推奨）または repo 単位の fine-grained PAT
- **Claude のサブスク（Pro または Max）**。API キーは不要——対話セッションを使う

---

## ステップ1 — 対象 repo の安全装置（GitHub 側）

対象 repo の `main` に branch protection を掛ける:

- **Pull request 必須**（直接 push を禁止）
- **force push 禁止 / ブランチ削除禁止**

ループは `loop/<id>` ブランチへ push して PR を作るところまで行い、マージは人間が行う。

---

## ステップ2 — GitHub App を作る（推奨）

1. **App を新規作成** — **Settings → Developer settings → GitHub Apps → New GitHub App**
   - name: 任意（例 `myorg-looptrooper`）
   - Homepage URL: 任意（リポジトリ URL でよい）
   - Webhook: `Active` のチェックを**外す**（ポーリング駆動なので不要）

2. **権限を付ける**（Repository permissions）

   | 権限 | 用途 |
   |---|---|
   | Contents: **Read and write** | `git push`（loop/* ブランチ） |
   | Pull requests: **Read and write** | `gh pr create` / 更新 |
   | Issues: **Read and write** | issue 駆動トリガ＋コメント＋依存(blocked_by)の参照 |
   | Metadata: **Read-only** | 必須（自動で付く） |

   - **merge 用の権限は付けない**

3. **App ID を控える** — 作成後の General ページに表示される数字をメモ

4. **秘密鍵を生成** — General ページ下部の **Private keys → Generate a private key** で `.pem` を取得
   - base64 で1行化して `GITHUB_APP_PRIVATE_KEY_B64` に使う:
     ```bash
     base64 -w0 your-app.private-key.pem   # macOS は: base64 -i your-app.private-key.pem | tr -d '\n'
     ```

5. **対象 repo に install** — App の **Install App** から対象リポジトリ**だけ**を選ぶ（`Only select repositories`）

- **代替（PAT）**: App を作らないなら、対象 repo 1個に絞った fine-grained PAT（上表と同じ権限）を発行し `GH_TOKEN` に入れる。App が未設定のときだけ使われる

---

## ステップ3 — 起動する（`loopctl`・推奨）

複数 project を1台でまとめて操作する薄い CLI `bin/loopctl` を使う。`project = 1 コンテナ` のまま、`init → create → start → login` で増減できる。

```bash
# PATH を通すと loopctl だけで叩ける（任意。~/.zshrc 等に追記）
export PATH="$PWD/bin:$PATH"

# 1) 共有の土台（1回だけ）。共有 .env 雛形を作り、共有イメージ looptrooper:latest を build。
loopctl init
vi ~/.looptrooper/.env          # 秘密を記入（全 project 共有・1枚）

# 2) project を作る → loop.yaml を編集（対象 repo・BUILD/TEST/LINT・ENABLE_POLL_* 等）
loopctl create myapp
vi ~/.looptrooper/projects/myapp/config/loop.yaml

# 3) 起動（clone・設定/認証の流し込みは自動）→ サブスク認証を1回
loopctl start myapp
loopctl login myapp             # claude 画面で /login → Ctrl-b d で detach（project 毎に1回）
```

**`~/.looptrooper/.env`（秘密・全 project 共有1枚）** の中身:
```dotenv
# 認証は次のどちらか（App 推奨）:
# (A) GitHub App ── 短命 token を自動発行
GITHUB_APP_ID=123456
GITHUB_APP_PRIVATE_KEY_B64=LS0tLS1CRUdJTi...（base64 -w0 した1行）
# (B) 静的トークン（PAT / machine user）── App 系が未設定のときだけ使われる
# GH_TOKEN=github_pat_xxxxxxxx

# 任意
SLACK_WEBHOOK_URL=https://hooks.slack.com/services/...   # あれば通知を Slack へ
TZ=Asia/Tokyo
```

**`projects/myapp/config/loop.yaml`（非秘密設定・project 毎）** の主な編集点:
```yaml
TARGET_REPO_URL: https://github.com/you/repo.git   # 必須
BUILD_CMD: npm run build       # Verifier が回す実コマンド
TEST_CMD:  npm test
LINT_CMD:  npm run lint
ENABLE_POLL_GH: true           # issue 取得。トリガは既定すべて false なので使うものを true にする
ENABLE_POLL_PR: true           # PR レビュー対応を使うなら
```
> 設定の優先順位は **`.env` > `loop.yaml` > 既定（`config.sh`）**。秘密は `.env`、それ以外は `loop.yaml` に書く。

### 日常運用（loopctl）
```bash
loopctl list                 # project 一覧（up/down）
loopctl status myapp         # ダッシュボード（番人/認証/タスク/GitHub/メモリ/アウトカム）
loopctl logs myapp driver    # ログ追尾（driver|session|poller|dockerd）
loopctl stop myapp           # 停止（状態・clone は保持）
loopctl upgrade --all        # 本体更新: 共有イメージ再build → project 毎に drain → recreate
loopctl gc                   # host の孤児を刈る（死んだコンテナ・浮いた docker-lib・dangling イメージ）
loopctl destroy myapp        # 完全削除（確認あり）
```

> **構成**: `~/.looptrooper/`（`.env` 共有1枚 ＋ `projects/<name>/{config/loop.yaml, .loop}`）。`LOOPCTL_HOME` で場所変更可。
> **`/login` は project 毎に1回**（認証は project をまたいで共有できない）。一度ログインすれば再ログインは不要。

---

## スモークテスト（1件流して完走を確認）

タスク入力は **`loop` ラベル付き issue に限定**。対象 repo に issue を立てて流す:

```bash
gh issue create -R <owner>/<repo> --label loop \
  --title "smoke test" --body "READMEのtypoを1つ直してfeatureブランチでPRを開いて"
```

次の poll でループが拾う。PR が立てば完了＝`loopctl status myapp` / 通知に「PR ready」が出る。進行はログで追う:

```bash
loopctl logs myapp driver
```

---

## 監視

まず**一括ダッシュボード**を見れば、番人/認証/タスク/GitHub/メモリ/アウトカム/直近通知が一目で分かる:

```bash
loopctl status myapp
```

個別に追うとき（状態ファイルはホストの `~/.looptrooper/projects/myapp/.loop/` に出る）:

| 見るもの | コマンド / 場所 |
|---|---|
| 判断系ログ | `loopctl logs myapp driver` |
| 生ストリーム（全出力の記録） | `loopctl logs myapp session` |
| Claude の画面を覗く | `loopctl login myapp`（detach: Ctrl-b → d） |
| キューの中身 | `ls ~/.looptrooper/projects/myapp/.loop/{queue,blocked,processed}` |
| ある結果の詳細 | `cat ~/.looptrooper/projects/myapp/.loop/results/<id>.json` |

- 失敗の結末は対象 repo の issue にコメントされる（`gh issue view <N> --comments`）。

---

## タスクの入れ方

| やりたいこと | 方法 |
|---|---|
| 新規タスクを依頼 | 対象 repo の issue に **`loop` ラベル**を付ける（唯一の入力源） |
| 着手順を制御 | GitHub ネイティブの issue dependencies（"blocked by"）。ブロック元が閉じるまで着手されない |
| やり直しさせる | 既処理 issue に **`loop:redo` ラベル**を付けるだけ（iOS でもタップ可） |
| 長時間タスクを許可 | issue に **`loop:long` ラベル**（チェックポイントを20分→60分に延長） |
| PR の指摘に対応させる | ループの PR に**人間が changes-requested レビュー**を付ける（既存ブランチに push して更新） |

> 各ラベル・トリガの詳しい挙動は [doc/mechanism.md](./doc/mechanism.md) を参照。

---

## トラブルシュート

| 症状 | 原因 / 対処 |
|---|---|
| `gh pr create` は通るが `git push` が認証エラー | credential helper(`gh-token.sh`)未設定 or 認証に Contents:write が無い。`setup-target.sh` 再実行＋App/PAT の権限確認 |
| `git commit` が "who are you?" | identity 未設定。`GIT_USER_NAME/EMAIL` を設定 → `setup-target.sh` 再実行 |
| タスクが `blocked/` に溜まる（権限） | 許可リスト不足。`.loop/logs` で止まったコマンドを確認し `.claude/settings.json` の allow を追加 |
| ループが進まない・"usage limit" | サブスク上限。driver が自動でリセットまで sleep（`driver.log` に `usage limit`）。待てば再開 |
| セッションが何度も落ちる | crash-loop ブレーカが停止＆通知。多くは**未ログイン**。`loopctl login`（または `tmux attach` で `/login`） |
| タスクが拾われない | driver 未起動 or queue が空、もしくは `ENABLE_POLL_GH` が false。`pgrep -af driver.sh` と `loop.yaml` を確認 |
| 起動が idle 待機のまま | `TARGET_REPO_URL` 未設定 or clone 失敗。`.env`/`loop.yaml` と `setup-target.sh` のログ確認 |
| ディスクが膨らんで遅い/タスク停止 | dind の docker-lib 肥大。コンテナ内は `BETWEEN_TASKS_CMD` で、host の死んだコンテナ・浮いた volume は `loopctl gc` で刈る |

---

## 設定リファレンス（主要変数）

設定は `config.sh`（既定の単一ソース）に集約され、`loop.yaml`（非秘密）と `.env`（秘密）で上書きする。

| 変数 | 意味（既定） |
|---|---|
| `TARGET_REPO_URL` | 対象 repo の URL（HTTPS・必須） |
| `BUILD_CMD` / `TEST_CMD` / `LINT_CMD` | Verifier が回す検証コマンド |
| `VERIFY_SETUP_CMD` / `BETWEEN_TASKS_CMD` | 検証の環境準備 / タスク境界の後始末（dind 内） |
| `ANTHROPIC_MODEL` | claude セッションのモデル（既定 `claude-sonnet-4-6`。難所中心なら `claude-opus-4-8`） |
| `PR_BASE_BRANCH` | ループが開く PR の向き先 base（既定 main） |
| `TASK_TIMEOUT` / `TASK_TIMEOUT_LONG` | チェックポイントまでの待ち秒（既定 1200=20分 / `loop:long` は 3600=60分） |
| `CHECKPOINT_GRACE` | 中断指示後、自己申告が返るのを待つ上限秒（既定 180） |
| `ENABLE_POLL_*` | GH/PR/OUTCOME/DEPS/CI/SPEC トリガの on/off（**既定すべて false**） |
| `POLL_GH_INTERVAL` / `POLL_TICK` | issue ポーリング間隔秒（既定 900）/ poller 基底起床間隔（既定 60） |
| `POLL_<NAME>_CRON` | ポーラー毎の cron 式（空＝既定間隔。例 `0 3 * * *`） |
| `CLEAR_BETWEEN_TASKS` | タスク毎に `/clear` で文脈を捨てる（既定 true） |
| `USAGE_BACKOFF` | usage limit 時の sleep 秒（既定 1800） |
| `CRASH_LIMIT` / `CRASH_WINDOW` | crash-loop ブレーカの閾値（既定 3 / 600） |
| `SLACK_WEBHOOK_URL` / `NOTIFY_CMD` | 通知先（空ならログのみ。`.env` 側＝秘密） |

### ディレクトリ（`.loop/`）
| パス | 役割 |
|---|---|
| `queue/` | 未処理タスク（`<id>.md`） |
| `results/` | 結果＝完了ファイル（`<id>.json`） |
| `processed/` | 完了（done/skipped） |
| `blocked/` | 要対応（failed/blocked） |
| `awaiting/` | 回答待ち（needs_info/timeout） |
| `state/` | in-progress マーカ・トリガの既処理印 |
| `memory/` | タスクを跨ぐ学習（PR に混入しない） |
| `logs/` | driver.log / session.log |
