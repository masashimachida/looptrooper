# アーキテクチャ — なぜこの形か

LoopTrooper の設計判断の背景。**使い方は [README](../README.md)** を、**タスクのライフサイクルとトリガの仕様は [mechanism.md](./mechanism.md)** を参照。
（トリガ・ドライバ・番人・Fixer/Verifier・dind 等の用語は [glossary.md](./glossary.md) を参照）

---

## 全体像

サブスク内・非対話 API 回避・ほぼ全自動、を同時に満たすため
**「開きっぱなしの対話セッションを外部トリガで駆動する」** 構成を採る。
LLM を呼ぶのは「タスク処理」だけで、トリガ・ドライバ・番人はすべて素の bash（＝空振り時は課金ゼロ）。

```
[外部トリガ: shell, ゼロ課金]
  poller が定期ポーリング（唯一の入力源）: 'loop' ラベル issue ＋ PR への changes-requested レビュー
        │ poll-gh.sh(issue) / poll-pr.sh(PRレビュー) → enqueue.sh（send-keys は呼ばない＝混線/並行を構造的に回避）
        ▼
  .loop/queue/<id>.md
        │
[単一常駐ドライバ driver.sh]  ← pane を触る唯一のプロセス
        │ 固定フレーズだけ注入（本文はファイル）
        ▼
  tmux: claude（対話セッション・サブスク認証）
        │ SKILL.md の手順で処理:
        │   worktree 隔離 → Fixer 実装 → Verifier(別サブエージェント)が検証 → PR 提案
        ▼
  loop-report → .loop/results/<id>.json  ← sentinel + status + 出力を統合
        │
  driver がルーティング（done=PR通知 / failed・blocked=⚠️ / skipped=空振り）

[番人] Docker restart → supervisor → session-keeper（claude生存）→ driver（タスク進捗）＋ poller（issue取得）
```

---

## 5つの「罠」への対処（設計の要点）

| 罠 | 対処 |
|---|---|
| #1 注入タイミング | 単一ドライバ＋完了 sentinel＋**短い固定フレーズ注入**（本文はファイル） |
| #2 権限 | `acceptEdits`＋allowlist＋deny tail。**main 直 push 禁止 / feature-push のみ / マージ手動**。番人は環境×権限の積 |
| #3 並行 | ドライバが直列処理。enqueue はファイル投函のみ（`tmux send-keys` を呼ばない） |
| #4 監視/復旧 | 層状番人＋状態ファイルで冪等復旧＋「遅い/詰まった」区別＋usage 上限 sleep＋crash-loop ブレーカ |
| #5 出力取得 | ターミナルを parse しない。`loop-report` の result file に統合。verification は **Verifier 由来**（自己採点禁止） |

---

## 設計の核（“なぜこの形か”を読まずに触ると壊す）

1. **pane を触るのは driver ただ1つ。** `enqueue.sh` は `tmux send-keys` を呼ばない——`.loop/queue/<id>.md` にファイルを置くだけ。これで注入の混線（並行・割り込み）を構造的に回避している。driver は1件ずつ直列処理し、短い固定フレーズだけ注入する（タスク本文はファイル側）。

2. **完了判定はターミナルを parse しない。** Claude は最後に `loop-report` を1回叩き、`.loop/results/<id>.json`（= sentinel ＋ status ＋ 検証結果）を書く。driver はこのファイルの出現を待つ。`capture-pane` は生存確認と stuck 分類専用で、成否判断には使わない。

3. **検証は自己採点禁止（Fixer/Verifier 分離）。** 実装（Fixer）と検証（別サブエージェントが `$BUILD_CMD`/`$TEST_CMD`/`$LINT_CMD` ＋ `/code-review` を実行）を分ける。

4. **番人は層状。** コンテナ CMD は `entrypoint.sh`（root で動く唯一の層）。これが dind の `dockerd` を起こし、準備完了を待って `gosu node ./bin/supervisor.sh` に降格する。`supervisor.sh` が `session-keeper`（claude 生存）＋ `driver`（タスク進捗）＋ `poller`（issue 取得）を起動。どれか1つでも死ねば supervisor が全部落とし、entrypoint が `dockerd` と supervisor を束ねてどちらか落ちたら両方落とす → compose の `restart=unless-stopped` が最外で立て直す。keeper は crash-loop サーキットブレーカ（`CRASH_LIMIT`/`CRASH_WINDOW`）付き。

5. **権限の最小化。** コンテナに渡す秘密は1個だけ（GitHub App の秘密鍵、PAT 運用なら `GH_TOKEN`）。認証は `bin/gh-token.sh` に一元化＝App なら短命 installation token を発行・キャッシュ、静的 `GH_TOKEN` ならそのまま供給。push は `loop/<id>` ブランチのみ、マージは必ず人間。
   - **Docker は自前で持つ（dind）。** 対象 repo が Docker 化されていても触らず、その `Dockerfile`/`compose` を箱の中の dockerd でそのままビルド・検証する。ホストの `docker.sock` は渡さない＝この箱で完結。代償は compose の `privileged: true`（内側 dockerd が cgroup/iptables/overlay を握るため必須）で、「箱＝使い捨ての VM」前提で受容する。

---

## 3層構造とファイル

- **ルート** = 「艦隊レイヤ」: `bin/loopctl`（複数 project を1台で操作する host 側 CLI）・`.env*`（秘密）・ドキュメント。
- **`container/`** = 「コンテナ定義一式」: `Dockerfile` / `docker-compose.yml` / `config/`（マウントする loop.yaml）／ そして **`container/app/`** = 「本体」（ループが実際に動かすスクリプト・設定・状態）。
- `Dockerfile`（`container/` 配下）はビルドコンテキストが `container/` なので `COPY app/ /work/loop` で `container/app/` の中身だけをイメージに入れる。→ コンテナ内では `container/app/bin/driver.sh` は `/work/loop/bin/driver.sh`、`LOOP_DIR=/work/loop`。

```
bin/loopctl                艦隊 CLI（host 側。init/create/start/login/.../upgrade/gc）
.env / .env.example        設定と秘密（GITHUB_APP_* または GH_TOKEN, SLACK_WEBHOOK_URL 等。root に1枚）
container/Dockerfile             イメージ定義（container/app/ のみ取り込む / dind）
container/docker-compose.yml     restart=unless-stopped, init, 認証は .env 経由（loopctl が -p で多重起動）
container/config/                マウントする loop.yaml（雛形 loop.yaml.example・非秘密設定）
container/app/config.sh              中央設定（全パスとタイミングの単一ソース）
container/app/bin/supervisor.sh      keeper + driver + poller を起動（降格後の番人ルート）
container/app/bin/session-keeper.sh  tmux+claude 生存番人・crash-loop ブレーカ
container/app/bin/driver.sh          単一常駐ドライバ（キュー消化・sentinel 待ち・stuck 分類）
container/app/bin/poller.sh          トリガの定期実行（常駐・cron 書式を自前評価）
container/app/bin/loop-report        Claude が最後に叩く報告コマンド（result file 生成）
container/app/bin/enqueue.sh         poller がタスクを投函する内部プリミティブ（issue/pr-review 由来のみ受理）
container/app/bin/setup-target.sh    対象 repo clone + 設定/プロファイル流し込み
container/app/bin/gh-token.sh        GitHub 認証トークン供給（App=短命 token 発行 / 静的 GH_TOKEN）
container/app/bin/status.sh          一括ダッシュボード（状態を1コマンドで表示）
container/app/.claude/settings.json  対象 repo へ配布する権限プロファイル（allow/deny）
container/app/.claude/skills/loop-task/      タスク処理手順（Fixer/Verifier/PR/loop-report）
container/app/.claude/skills/loop-decompose/ spec フェーズの分解スキル（executor 側）
container/app/triggers/              入力/観測ポーリング（poll-gh/pr/outcome/deps/ci/spec）
container/app/.loop/                 実行時状態（ホストにバインドマウント）
container/app/LOOP_STATE.md          状態ボード（人間用の静的メモ）
```

---

## コスト（空振りの扱い）

- 仕事がない間はトリガが沈黙＝**LLM 課金ゼロ**（ドライバはファイル監視 sleep のみ）。
- 1タスクの処理コストは「トリアージ＋実装＋検証」の実作業分。
- サブスクの使用量上限に当たったら、ドライバが**リセットまで自動 sleep**（`USAGE_BACKOFF`・無駄打ちしない）。
- タスク毎に `/clear` で会話文脈を捨て、累積文脈による入力トークン増とオートコンパクト費を断つ（`CLEAR_BETWEEN_TASKS`）。タスクは互いに独立（worktree 隔離・issue 駆動・跨ぐ知識は `.loop/memory` のファイル側）なので履歴を捨てても次タスクは同じ状態から始められる。
