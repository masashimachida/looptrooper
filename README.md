# LoopTrooper 🫡

Addy Osmani の [Loop Engineering](https://addyosmani.com/blog/loop-engineering/) に着想を得た、
**自律的なコード保守ループ**の骨組み。

> 命令書（`loop` ラベルの GitHub issue）を出すだけ。あとは無人の「隊員（Trooper）」が
> worktree に展開し、実装し、別班が検証し、PR を具申するまでを夜通し回す。
> 賢く一発ではなく、**規律正しく・無数に・休まず**。

> 思想: 「自分が毎回プロンプトを打つ代わりに、エージェントに自動でプロンプトを打つシステムを設計する」。
> 構成要素 — ①外部トリガ(Automations) ②worktree隔離 ③Skills ④gh連携(Connectors) ⑤Fixer/Verifierサブエージェント ⑥状態ファイル。

> ⚠️ これは**雛形（未テスト）**。対象リポジトリが決まったら `config.sh` を埋めて実地で通すこと。

---

## アーキテクチャ（なぜこの形か）

サブスク内・非対話API回避・ほぼ全自動、を満たすため **「開きっぱなしの対話セッションを外部トリガで駆動する」** 構成を採用。

```
[外部トリガ: shell, ゼロ課金]               ← ①Automations
  poller が定期ポーリング（唯一の入力源）: 'loop' ラベル issue ＋ PR への changes-requested レビュー
        │ poll-gh.sh(issue) / poll-pr.sh(PRレビュー) → enqueue.sh（send-keysは呼ばない＝混線/並行を構造的に回避）
        ▼
  .loop/queue/<id>.md
        │
[単一常駐ドライバ driver.sh]  ← pane を触る唯一のプロセス
        │ 固定フレーズだけ注入（本文はファイル）
        ▼
  tmux: claude（対話セッション・サブスク認証）
        │ SKILL.md の手順で処理:
        │   worktree隔離 → Fixer実装 → Verifier(別サブエージェント)が検証 → PR提案
        ▼
  loop-report → .loop/results/<id>.json  ← sentinel + status + 出力を統合 ⑥
        │
  driver がルーティング（done=PR通知 / failed・blocked=⚠️ / skipped=空振り）

[番人] Docker restart → supervisor → session-keeper（claude生存）→ driver（タスク進捗）
```

### 5つの「罠」への対処（設計の要点）
| 罠 | 対処 |
|---|---|
| #1 注入タイミング | 単一ドライバ＋完了sentinel＋**短い固定フレーズ注入**（本文はファイル） |
| #2 権限 | `acceptEdits`＋allowlist＋deny tail。**main直push禁止/feature-pushのみ/マージ手動**。番人は環境×権限の積 |
| #3 並行 | ドライバが直列処理。enqueue はファイル投函のみ |
| #4 監視/復旧 | 層状番人＋状態ファイルで冪等復旧＋「遅い/詰まった」区別＋usage上限sleep＋crash-loopブレーカ |
| #5 出力取得 | ターミナルをparseしない。`loop-report` の result file に統合。verificationは**Verifier由来**（自己採点禁止） |

---

## セットアップ

1. **対象リポジトリを決めて `config.sh` を埋める**
   - `TARGET_REPO_URL`（必須）
   - `BUILD_CMD` / `TEST_CMD` / `LINT_CMD`（Verifier が使う実コマンド）

2. **GitHub 側の安全装置（重要）**
   - 対象 repo の `main` に **branch protection**: PR必須・force push禁止・削除禁止
   - **認証は GitHub App 推奨**（短命 installation token を自動発行・ローテーション。bot として人間と区別できる）。
     App を作成 → 対象 repo に install → 権限 Contents/Pull requests/Issues = Read and write。
     `.env` に `GITHUB_APP_ID` と秘密鍵（`GITHUB_APP_PRIVATE_KEY_B64` ＝ PEM を `base64 -w0` した1行）。
   - 代替として **repo 単位の fine-grained PAT**（machine user 推奨）でも可。その場合は `.env` に `GH_TOKEN=...`。

3. **認証情報の最小化**
   - コンテナに渡す秘密は **GitHub App の秘密鍵 1個だけ**（PAT 運用なら `GH_TOKEN` 1個）。ホストの gh auth / SSH鍵 / cloud鍵 は渡さない。
   - トークン供給は `bin/gh-token.sh` に一元化。git は credential helper、`gh` は PATH ラッパー経由で毎回フレッシュなトークンを使う。

4. **起動**
   ```bash
   docker compose build
   docker compose up -d
   docker compose exec -u node loop ./bin/setup-target.sh   # clone + 設定流し込み
   # 初回のみ Claude のサブスクログイン:
   docker compose exec -u node loop tmux attach -t loop      # /login して認証 → detach (Ctrl-b d)
   ```

5. **トリガ（issue 駆動のみ。設定不要）**
   - タスク入力は対象 repo の **'loop' ラベル付き issue に限定**。supervisor 配下の poller が常駐ポーリングする（cron 不要）。
   - 間隔は `POLL_GH_INTERVAL`（既定900秒。`.env` で上書き可）。`enqueue.sh` は poller 専用の内部プリミティブで、手動・git hook からは拒否される。

6. **1件流して動作確認**
   - 対象 repo に `loop` ラベルを付けた issue を立てる（例: 「READMEのtypoを1つ直してPRを開いて」）。
   - 次の poll でループが拾い、`app/LOOP_STATE.md` / 通知に「PR ready」が出れば一周完走。

---

## 運用

- 人間が見るのは **`app/LOOP_STATE.md` の ⚠️ セクション**と、PR レビュー（=マージゲート）だけ。
- 詳細ログ: `.loop/logs/driver.log`（判断系）/ `.loop/logs/session.log`（生ストリーム・forensics）。
- **マージは必ず人間**。ループは feature ブランチ＋PR提案で止まる。

## コスト（空振りの扱い）
- 仕事がない間はトリガが沈黙＝**LLM 課金ゼロ**（ドライバはファイル監視 sleep のみ）。
- 1タスクの処理コストは「トリアージ＋実装＋検証」の実作業分。
- サブスクの使用量上限に当たったら、ドライバが**リセットまで自動 sleep**（無駄打ちしない）。

## ファイル
ルートは「箱」（ビルド・デプロイ・ドキュメント）、`app/` が箱の中で動く本体。
`Dockerfile` は `COPY app/ /work/loop` で app/ の中身だけを取り込む。
```
Dockerfile                 イメージ定義（app/ のみ取り込む / 非rootで起動）
docker-compose.yml         restart=unless-stopped, init, 認証は .env 経由
.env / .env.example        設定と秘密（GITHUB_APP_* または GH_TOKEN, SLACK_WEBHOOK_URL 等）
app/config.sh              中央設定（ここを埋める）
app/bin/supervisor.sh      keeper + driver + poller を起動（コンテナ CMD）
app/bin/session-keeper.sh  tmux+claude 生存番人・crash-loopブレーカ
app/bin/driver.sh          単一常駐ドライバ（キュー消化・sentinel待ち・stuck分類）
app/bin/poller.sh          issue トリガの定期実行（常駐）
app/bin/loop-report        Claude が最後に叩く報告コマンド（result file 生成）
app/bin/enqueue.sh         poller がタスクを投函する内部プリミティブ（issue 由来のみ受理）
app/bin/setup-target.sh    対象 repo clone + 設定流し込み
app/bin/gh-token.sh        GitHub 認証トークン供給（App=短命token発行 / 静的GH_TOKEN）
app/bin/status.sh          一括ダッシュボード（状態を1コマンドで表示）
app/.claude/settings.json  対象 repo へ配布する権限プロファイル（allow/deny）
app/.claude/skills/loop-task/  タスク処理手順（Fixer/Verifier/PR/loop-report）
app/triggers/              入力/観測ポーリング（poll-gh=issue / poll-pr=PRレビュー / poll-outcome=アウトカム / poll-deps=依存脆弱性の自動起票）
app/.loop/                 実行時状態（ホストにバインドマウント）
app/LOOP_STATE.md          状態ボード（人間用）
```
