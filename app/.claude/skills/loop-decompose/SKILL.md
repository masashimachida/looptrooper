---
name: loop-decompose
description: 仕様書(spec/)の1フェーズを 1 PR 単位の issue 群に分解して起票する手順。本文に `spec_phase:` がある分解タスクで loop-task から委譲される。
---

# loop-decompose

`poll-spec.sh` が投函する**仕様フェーズの分解タスク**を処理する手順。
loop-task が本文の `spec_phase:` を見てこのスキルに委譲する。
**やることは「このフェーズを実装可能な issue 群に割って起票する」だけ**。
コードは書かない・worktree は作らない・PR は作らない（実装は各 issue を poll-gh が拾って loop-task が後で行う）。

原則（なぜ分解だけ無人で許すか）: spec は人間が承認済み。**承認ゲートは PR マージに移っている**ので、
issue を自動起票しても main には勝手に入らない（各 PR を人間がマージして初めてフェーズが進む）。
だから分解は止めず自動で回し、人間は「PR のマージ承認」と「spec の記述」だけに集中できる。

## 入力（タスク本文のキー）

- `spec_phase:` … フェーズ番号 NN（例 `01`）
- `spec_slug:` … フェーズの slug（例 `auth`）
- `milestone:` … マイルストーン名「NN: slug」（**poll-spec が作成済み**。issue はこれに紐付ける）
- `milestone_number:` … マイルストーンの番号
- `spec_overview:` … 全体像ファイルの相対パス（`spec/00-overview.md`。`(なし)` のこともある）
- `spec_file:` … このフェーズの仕様ファイルの相対パス（`spec/NN-slug.md`）

cwd は対象 repo（`/work/repo`）。パスはこの repo ルートからの相対。

## 手順

1. **タスク読込** — 指定された `<path>` を Read し、ファイル名から `<id>` を控える。上のキーを控える。

1.5. **メモリ参照** — `/work/loop/.loop/memory/MEMORY.md`（索引）と関連カテゴリ（特に `conventions.md`）を Read。
   既知の規約・命名・配置を踏まえて issue を書く（後続の loop-task が同じ規約で実装できるよう、issue 側で先回りする）。

2. **仕様を読む** — `spec_overview`（あれば）と `spec_file` を Read。
   - overview = 全体像・共通制約・用語。フェーズを跨ぐ前提（技術選定・命名規約・非機能要件）はここにある。
   - spec_file = このフェーズで実現すること。ここが分解の対象。

3. **接地（drift 補正）** — `spec_phase` が `01` でなければ、**先行フェーズはマージ済み**のはず。
   実際のコードを読んで現状に接地する（spec は理想、実装は現実。ズレたら現実に合わせて割る）。
   - 広い読み込みは `research` サブエージェント（Haiku・読み取り専用）に委譲し、要約（`path:line`）を起点にする。
   - 「このフェーズで何を足す/変えるか」を、既存の構造・命名・配置に沿って具体化する。

4. **分解（このスキルの本体）** — フェーズを **1 PR 単位**の issue に割る:
   - **粒度の上限 = 目安 ~10分で完了見込み**（経験則: 規定時間で終わらないタスクは大抵終わらない）。超えそうなら割る。
     小さくする本当の理由は timeout 回避より「**人間がマージ承認しやすい小さな PR**」にすること。
   - **フェーズ内の issue 数は無制限**（数を縛るとフェーズ間で粒度がブレる）。必要なだけ作る。
   - 各 issue は1つの明確な成果物（1 PR）に対応させる。曖昧・大きすぎ・依存が絡みすぎなら更に割る。

5. **起票（順序が重要＝作成 → 依存配線 → ラベルの順）** — レースを避けるためこの順を厳守する:

   5a. **issue を作成**（まだ `loop` ラベルは付けない）。body は `draft-loop-issue` 型で書く:
   ```
   ## 目的
   <この issue で何を達成するか。spec のどの部分か>
   ## 変更内容
   <触るファイル/モジュール・追加する関数や UI を具体的に（接地で読んだ実物に基づく）>
   ## 受け入れ条件
   - <観察可能な完了条件>
   - **実装後に `<検証コマンド>` を走らせて green**（必ず1つ入れる。$BUILD_CMD/$TEST_CMD のいずれか相当）
   ## 備考
   <制約・参照する spec の節・既存実装へのポインタ>
   ```
   作成は必ず `--milestone "<milestone>"` でこのフェーズに紐付ける（ラベルはまだ）:
   ```bash
   gh issue create -R <slug> --milestone "<milestone>" \
     --title "<簡潔なタイトル>" --body "<上記>"
   ```
   作成した issue 番号を控える。

   5b. **依存を配線**（フェーズ内に順序があるとき）— GitHub ネイティブの issue dependencies（"blocked by"）で:
   ```bash
   # B が A の完了に依存する場合（A を B の blocked_by に追加）
   gh api -X POST repos/<slug>/issues/<B>/dependencies/blocked_by -F issue_id=<A の node 数値 id>
   ```
   ※`issue_id` は REST の数値 issue id（`gh api repos/<slug>/issues/<N> --jq .id`）。issue 番号(#N)とは別物なので注意。
   並行可能な issue には依存を張らない（過剰な直列化は分解の意味を削ぐ）。

   5c. **最後に `loop` ラベルを付ける** — 全 issue の作成と依存配線が済んでから:
   ```bash
   gh issue edit <N> -R <slug> --add-label loop
   ```
   こうすると poll-gh が拾う時点で依存が揃っている（未ブロックのまま着手するレースを防ぐ）。
   ※最初から長いと分かっている issue には `loop:long` も付けてよい。

6. **報告（最後に必ず1回だけ）** — `loop-report` のみで完了を伝える:
   ```bash
   loop-report --task <id> --status done \
     --summary "フェーズ <NN: slug>: <M>件の issue を起票（#a, #b, #c …）"
   ```
   - 分解すべき内容が無い/既に起票済みだった等で何もしなかったら `--status skipped`。
   - 仕様が曖昧で分解できない（人間に確認が要る）なら、判断を仰ぐ issue を1本立てるのではなく
     `--status blocked --reason "<spec のどこが分解に足りないか>"` で人間トリアージへ回す（spec を直すのは人間の仕事）。

## やってはいけないこと

- コードを書く / worktree を作る / PR を開く（それは各 issue を拾った後の loop-task の仕事）。
- マイルストーンを新規作成する（poll-spec が作成済み。指定された `milestone` に紐付けるだけ）。
- 次フェーズまで先食いして分解する（このタスクは `spec_phase:` の1フェーズだけ。次は前フェーズ完了後に poll-spec が改めて投函する）。
- issue を作る前にラベルを付ける（依存が揃う前に poll-gh が拾うレースの原因）。
