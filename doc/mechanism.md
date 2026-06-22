# 仕組み（タスクのライフサイクルとトリガ仕様）

ループが実際にどう回るかの仕様をまとめる。
使い方は [README](../README.md) を、設計の背景は [architecture.md](./architecture.md) を参照。
トリガ、ドライバ、番人、poller などの用語は [glossary.md](./glossary.md) にまとめた。

---

## タスクのライフサイクル（ファイルが状態機械）

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

マージは必ず人間が行う。
ループは `loop/<id>` feature ブランチへの push と PR の提案で止まる。

- **起動時の `recover_inflight()`**：`*.inprogress` が残っていれば中断とみなし、result を消して再処理する（queue に残す）。
- **状態マーカー**：`state/issue-<N>.seen` が既処理（再投函しない）、`.awaiting` が回答待ち、`.blocked` が依存未完了で待機中、`state/pr-<N>.review` が対応済みレビュー id を表す。

---

## タイムアウトは分割ミスのフィードバック（チェックポイント方式）

driver は `TASK_TIMEOUT`（既定20分。`loop:long` ラベルの issue は `TASK_TIMEOUT_LONG`＝既定60分）まで待つ。
超過してなお stuck 判定が working なら、延長せず Escape で中断する。
そして Claude に「経過、なぜ終わらないか、今後の方針」を issue にコメントさせ、`loop-report --status timeout` で自己申告させる（`CHECKPOINT_GRACE` 内に返らなければ応答不能とみなして再キューする）。

外からは「遅いだけ」か「堂々巡り」かを判別できない。
だから本人に申告させ、人間がトリアージ（redo / 分割 / `loop:long`）する。
これは「規定時間で終わらないタスクは大抵終わらない」という経験則に基づく。

- **失敗の結末を issue に残す**：`failed`/`blocked`/壊れた result と modal 停止のとき、driver が issue にコメントする（要約と隠しマーカー `<!-- loop:outcome -->`）。
  ループ基盤と起票セッションが別マシンでも、人間は `gh issue view <N> --comments` で失敗の中身を読める（生ログは出さず、漏えい面を最小化する。raw は基盤側の `.loop/logs` に残す）。
  crashed/hung は requeue を前提とし、スパムを避けるためコメントしない。

---

## トリガ（すべて opt-in・本体既定 false）

`ENABLE_POLL_<NAME>`（GH/PR/OUTCOME/DEPS/CI/SPEC）の本体既定はすべて false で、何もしない素の箱になっている。
使うトリガだけ `config/loop.yaml` で `true` にする（主入力である poll-gh すら明示的に on にする）。

ポーラーは `poller.sh` が `POLL_TICK`（既定60s）で起き、各ポーラーの予定を判定する。
cron デーモンには依存せず、cron の「書式」だけを自前 bash で評価する。
`POLL_<NAME>_CRON`（GH/PR/OUTCOME/DEPS/CI）が空なら既定間隔（`POLL_GH_INTERVAL`＝15分）ごと、cron 式なら標準5フィールドでマッチする分に1回走る。

### poll-gh（issue が主入力）
対象 repo の `loop` ラベル付き issue を拾い、`enqueue.sh` で投函する。
冪等で、既処理は `.seen` により再投函しない。
要件が曖昧なら bot が issue に質問し、回答待ち（`.awaiting`）になる。

- **依存関係（順序制御）**：GitHub ネイティブの issue dependencies（"blocked by"）を REST で参照する。
  ブロック元が未完了（open、または closed でも `not_planned`）なら enqueue せず `.seen` も立てず、次 poll で再評価する。
  ブロック開始時に `.blocked` を立てて一度だけ通知し、解消したら消す。
- **再着手 `loop:redo`**：既処理 issue を「もう一度やって」と人間が指示する手段。
  ファイルを触らず、issue に `loop:redo` ラベルを付けるだけでよい（iOS でもタップできる）。
  `.seen`/`.awaiting`/`.blocked` を消し、`loop:redo` を外して `loop` を付け直すと、通常どおり再 enqueue される（1回で消費する冪等な操作）。
- **長時間許可 `loop:long`**：「この issue は時間がかかる」と人間がトリアージするための持続的な属性ラベル。
  enqueue 時にこれを見て、driver のチェックポイントを既定20分から60分に延ばす（無制限ではない）。
- **needs_info の往復**：bot が曖昧と判断すると issue にコメントする（隠しマーカー `<!-- loop:awaiting-reply -->`）。
  driver が `.awaiting` を立て、最新コメントがマーカーのままなら待機を続ける。
  人間が返信したら `.awaiting` を消して再投入する。

### poll-pr（PR レビュー往復）
`loop/*` の open PR を見て、人間の最新の changes-requested レビュー id を検出する。
未記録なら修正タスクを投函し、SKILL の「PR レビュー指摘対応モード」が既存ブランチに push して PR を更新する（新規 PR は作らない）。
対応済みレビュー id を記録するので同じ指摘では再発火せず、人間が新しい changes-requested を出すと再発火する。

### poll-deps（依存脆弱性から自動起票）
`AUDIT_CMD`（既定 `npm audit --json`）で対象 repo を監査する。
high/critical かつ修正版がある脆弱性を自動で issue 起票する（非メジャーなら `loop` で自走、メジャーなら `loop:proposed` で人間承認）。
重複は `state/dep-<advisory>.filed` で抑制し、1回あたり `DEPS_MAX_PER_RUN` 件までにする。
実行頻度は `POLL_DEPS_CRON`（既定 `0 3 * * *`＝毎日3時）で決まる。

### poll-ci（main の CI 失敗から起票）
`CI_WORKFLOW`（既定空で無効）で指定したワークフローの、`CI_BRANCH`（既定 main）の最新の完了 run を見る。
`failure`/`timed_out`/`startup_failure` なら issue を自動起票する（run URL と失敗ジョブ名を添え、生ログは貼らない）。
重いテストを箱の中で再現せず、マージを実際にゲートしている正規環境（CI）の結果をそのまま受け取る設計にしている。
CI 修正は調査と再 CI 待ちで長くなりがちなので、既定で `loop:long` も付ける。

### poll-spec（仕様書駆動の自律分解）
対象 repo の `SPEC_DIR`（既定 `spec/`）を入力に、フェーズ単位で issue 群を自律生成する。
フェーズは GitHub マイルストーン「NN: slug」に対応する。
遅延分解を採り、前フェーズ完了（`open_issues==0` かつ `closed>0`）を検知したら次フェーズを一度だけ分解する（前フェーズのマージ済み実物を読んで割ることで drift を補正する）。
実際の分解は `LOOP_SOURCE=spec` で投函する分解タスク（`loop-decompose` スキル）に委譲し、LLM を呼ぶのはそこだけにする。
承認ゲートは PR マージに置き、issue の再承認はしない。

### poll-outcome（アウトカム観測）
マージ済み loop PR の「その後」を見て、revert された、あるいは閉じた issue が再オープンしたという負のアウトカムを検出する。
検出すると `.loop/memory/outcomes.md` に追記し、通知する。
「テスト緑」という代理指標ではなく現実の結末がメモリに返るので、loop-task が次に同じ轍を踏まないよう参照できる。

---

## ループのメモリ（タスクを跨ぐ学習）

`.loop/memory/`（`MEMORY.md` 索引と `conventions.md`/`review-prefs.md`/`pitfalls.md`/`outcomes.md`）に学習を溜める。
loop-task は開始時にこれを読み（既知の規約、レビュー嗜好、失敗を踏まえて実装する）、終了時に次に効く学びだけを書き戻す。
メモリは対象 repo の外にあり（PR に混入しない）、バインドマウントで永続する。
特に PR レビュー指摘を `review-prefs.md` に溜め、新規実装で先回りさせる。

---

## 入力の制約

タスク入力は対象 repo の `loop` ラベル付き issue に限定する（PR レビュー指摘も含む）。
`enqueue.sh` は poller 専用の内部プリミティブで、`LOOP_SOURCE`（`issue` / `pr-review` / `spec`）が無いと拒否する。
これにより手動投函や git hook などの入力を受け付けず、事故を防ぐ。
