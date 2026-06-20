# 仕組み — タスクのライフサイクルとトリガ仕様

ループが実際にどう回るかの仕様。**使い方は [README](../README.md)**、**設計の背景は [architecture.md](./architecture.md)** を参照。
（トリガ・ドライバ・番人・poller 等の用語は [glossary.md](./glossary.md) を参照）

---

## タスクのライフサイクル（ファイル＝状態機械）

```
trigger（poll-gh=issue / poll-pr=PRレビュー指摘） → enqueue.sh → .loop/queue/<id>.md
  driver が拾う → .loop/state/<id>.inprogress を立てて inject
  Claude が loop-report → .loop/results/<id>.json(status)
  driver が route_result でルーティング:
    done       → .loop/processed/   （✅ PR 通知）
    skipped    → .loop/processed/   （空振り）
    needs_info → .loop/awaiting/     （issue に質問済み・人間の回答待ち）
    timeout    → .loop/awaiting/     （規定時間超過で中断・自己申告済み・人間トリアージ待ち）
    failed/blocked/壊れた result → .loop/blocked/  （⚠️ 通知 ＋ issue に結末コメント）
```

**マージは必ず人間。** ループは `loop/<id>` feature ブランチ＋PR 提案で止まる。

- **起動時 `recover_inflight()`**: `*.inprogress` が残っていれば中断とみなし result を消して再処理（queue に残す）。
- **状態マーカー**: `state/issue-<N>.seen` = 既処理（再投函しない）／`.awaiting` = 回答待ち／`.blocked` = 依存未完了で待機中／`state/pr-<N>.review` = 対応済みレビュー id。

---

## タイムアウト＝「分割ミスのフィードバック」（チェックポイント方式）

driver は `TASK_TIMEOUT`（既定20分。`loop:long` ラベルの issue は `TASK_TIMEOUT_LONG`＝既定60分）まで待ち、超過かつ stuck 判定が working なら**延長せず Escape で中断**し、Claude に「経過・なぜ終わらないか・今後の方針」を issue にコメントさせ `loop-report --status timeout` で自己申告させる（`CHECKPOINT_GRACE` 内に返らなければ応答不能とみなし再キュー）。

外からは「遅いだけ」か「堂々巡り」か判別できないので、本人に申告させ人間がトリアージ（redo / 分割 / `loop:long`）する。経験則「規定時間で終わらないタスクは大抵終わらない」に基づく。

- **失敗の結末を issue に残す**: `failed`/`blocked`/壊れた result と modal 停止時に、driver が issue にコメント（要約＋隠しマーカー `<!-- loop:outcome -->`）。ループ基盤と起票セッションが別マシンでも、人間は `gh issue view <N> --comments` で失敗の中身を読める（生ログは出さない＝漏えい面の最小化。raw は基盤側 `.loop/logs`）。crashed/hung は requeue 前提でスパム回避のため無コメント。

---

## トリガ（全て opt-in・本体既定 false）

`ENABLE_POLL_<NAME>`（GH/PR/OUTCOME/DEPS/CI/SPEC）の**本体既定は全て false ＝何もしない素の箱**。使うトリガだけ `config/loop.yaml` で `true` にする（poll-gh＝主入力すら明示的に on）。

ポーラーは `poller.sh` が `POLL_TICK`（既定60s）で起き、各ポーラーの予定を判定する。**cron デーモンには依存せず、cron の“書式”だけ自前 bash で評価する**。`POLL_<NAME>_CRON`（GH/PR/OUTCOME/DEPS/CI）が空なら既定間隔（`POLL_GH_INTERVAL`＝15分）ごと、cron 式なら標準5フィールドでマッチする分に1回。

### poll-gh（issue＝主入力）
対象 repo の `loop` ラベル付き issue を拾い、`enqueue.sh` で投函。冪等（既処理は `.seen` で再投函しない）。要件が曖昧なら bot が issue に質問し回答待ち（`.awaiting`）になる。

- **依存関係（順序制御）**: GitHub ネイティブの issue dependencies（"blocked by"）を REST で参照。ブロック元が未完了（open、または closed でも `not_planned`）なら enqueue せず `.seen` も立てない＝次 poll で再評価。ブロック開始時に `.blocked` を立てて1回だけ ⛔ 通知し、解消したら消す。
- **再着手 `loop:redo`**: 既処理 issue を「もう一度やって」と人間が指示する手段。ファイルを触らず **issue に `loop:redo` ラベルを付けるだけ**（iOS でもタップ可）。`.seen`/`.awaiting`/`.blocked` を消し、`loop:redo` を外して `loop` を付け直す→通常どおり再 enqueue（1回で消費＝冪等）。
- **長時間許可 `loop:long`**: 「この issue は時間がかかる」と人間がトリアージするための持続的な属性ラベル。enqueue 時にこれを見て driver のチェックポイントを既定20分→60分に延ばす（無制限ではない）。
- **needs_info の往復**: bot が曖昧と判断 → issue にコメント（隠しマーカー `<!-- loop:awaiting-reply -->`）→ driver が `.awaiting` を立てる → 最新コメントがマーカーのままなら待機継続、人間が返信したら `.awaiting` を消して再投入。

### poll-pr（PR レビュー往復）
`loop/*` の open PR を見て、**人間の最新 changes-requested レビュー** id を検出。未記録なら修正タスクを投函 → SKILL の「PR レビュー指摘対応モード」が**既存ブランチに push して PR 更新**（新規 PR は作らない）。対応済みレビュー id を記録するので同じ指摘では再発火せず、人間が**新しい** changes-requested を出すと再発火する。

### poll-deps（依存脆弱性 → 自動起票）
`AUDIT_CMD`（既定 `npm audit --json`）で対象 repo を監査。high/critical かつ修正版がある脆弱性を自動で issue 起票（非メジャー→`loop`＝自走／メジャー→`loop:proposed`＝人間承認）。重複は `state/dep-<advisory>.filed` で抑制、1回 `DEPS_MAX_PER_RUN` 件まで。実行頻度は `POLL_DEPS_CRON`（既定 `0 3 * * *`＝毎日3時）。

### poll-ci（main の CI 失敗 → 起票）
`CI_WORKFLOW`（既定空＝無効）で指定したワークフローの、`CI_BRANCH`（既定 main）の最新の完了 run を見て、`failure`/`timed_out`/`startup_failure` なら issue 自動起票（run URL ＋失敗ジョブ名を添える・生ログは貼らない）。重荷の再現を避け、マージを実際にゲートしている正規環境（CI）の結果をそのまま受け取る設計。既定で `loop:long` も付ける（CI 修正は調査＋再 CI 待ちで長くなりがちなため）。

### poll-spec（仕様書駆動の自律分解）
対象 repo の `SPEC_DIR`（既定 `spec/`）を入力に、**フェーズ単位で issue 群を自律生成**する。フェーズ = GitHub マイルストーン「NN: slug」。**遅延分解**＝前フェーズ完了（`open_issues==0` かつ `closed>0`）を検知したら次フェーズを1回だけ分解（前フェーズのマージ済み実物を読んで割る＝drift 補正）。実際の分解は `LOOP_SOURCE=spec` で投函する分解タスク（`loop-decompose` スキル）に委譲＝LLM はそこだけ。**承認ゲートは PR マージ**（issue 再承認はしない）。

### poll-outcome（アウトカム観測）
マージ済み loop PR の“その後”を見て、**revert された / 閉じた issue が再オープンした**という**負のアウトカム**を検出し、`.loop/memory/outcomes.md` に追記＋⚠️ 通知。「テスト緑」という代理指標でなく現実の結末がメモリに返り、loop-task が次に同じ轍を踏まないよう参照する。

---

## ループのメモリ（タスクを跨ぐ学習）

`.loop/memory/`（`MEMORY.md` 索引 ＋ `conventions.md`/`review-prefs.md`/`pitfalls.md`/`outcomes.md`）。loop-task が**開始時に読み**（既知の規約・レビュー嗜好・失敗を踏まえて実装）、**終了時に“次に効く”学びだけ書き戻す**。対象 repo の外（PR に混入しない）・バインドマウントで永続。特に PR レビュー指摘を `review-prefs.md` に溜めて新規実装で先回りさせる。

---

## 入力の制約

タスク入力は **対象 repo の `loop` ラベル付き issue に限定**（＋ PR レビュー指摘）。`enqueue.sh` は poller 専用の内部プリミティブで、`LOOP_SOURCE`（`issue` / `pr-review` / `spec`）が無いと拒否する＝手動投函・git hook 等の入力は受け付けない（事故防止）。
