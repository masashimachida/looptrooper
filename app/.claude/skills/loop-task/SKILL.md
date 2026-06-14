---
name: loop-task
description: ループのドライバから注入された1件のタスクを、worktree隔離・独立検証・PR提案・loop-report報告まで自律処理する手順。「次のタスクを処理して: <path>」と指示されたら必ずこれに従う。
---

# loop-task

ドライバが「**次のタスクを処理して: `<path>`**」と指示したら、この手順に**厳密に**従う。
原則は記事のループエンジニアリング: 探索役(Fixer)と検証役(Verifier)を分け、**自分の宿題を自分で採点しない**。

## 手順

1. **タスク読込** — 指定された `<path>`（例 `/work/loop/.loop/queue/<id>.md`）を Read。ファイル名から `<id>` を控える。本文に `issue #<N>` があれば `<N>` も控える。
   - **本文に `pr_number:` があれば、新規実装フローではなく後述の「PR レビュー指摘への対応モード」に切り替える**（既存ブランチの修正・新規 PR は作らない）。

1.2. **issue 全体を読む（issue 由来タスクは必須）** — `issue #<N>` があれば `gh issue view <N> --comments` で**本文＋全コメント**を読む。
   タスク本文にはタイトルしか載っていないので、実際の要件・受け入れ条件・制約・前提は **issue 本体とコメントにしかない**。
   - **人間の最新コメントを最優先で考慮する** — 質問への回答・補足・再依頼、過去の往復（needs_info の回答／中断報告へのトリアージ指示）の続きはコメントに書かれている。本文だけ見て古い前提で進めない。
   - （`pr_number:` のタスクは「PR レビュー指摘への対応モード」で PR 側のコメントを読むため、ここは対象外。）

1.5. **メモリ参照（蓄積知識の活用）— 実装より前に必須** — `/work/loop/.loop/memory/MEMORY.md`（索引）を Read し、
   今回のタスクに関連しそうなカテゴリ（`conventions.md` / `review-prefs.md` / `pitfalls.md` / `outcomes.md`）があれば該当ファイルも Read する。
   **過去の規約・レビュー嗜好・失敗・現実のアウトカムを踏まえて**トリアージ・実装・対応する（同じ指摘を繰り返さない、既知の癖を踏まない）。
   - **`outcomes.md`（自動記録）に今回の対象 issue / 触る箇所と関連する負のアウトカム（revert・再オープン）があれば最優先で考慮**し、前回なぜ失敗したかを推定して同じ轍を踏まない。教訓化できたら `pitfalls.md`/`review-prefs.md` に昇格（手順6.5）。
   ※メモリは対象 repo の外（`/work/loop/.loop/memory/`）にある。**repo にコミットしない**。

2. **トリアージ（曖昧さの判定）— 実装より前に必須** — 「迷ったら実装」ではなく「迷ったら質問」。
   コードベースを軽く調べた上で、**実装方針を確信を持って決められないほど要件が曖昧**なら、推測で実装しない。
   - issue 由来タスク（`issue #<N>` がある）なら、issue にコメントで**具体的に質問**する:
     ```bash
     gh issue comment <N> --body "$(cat <<'MD'
     🤖 loop-bot: 着手前に確認させてください。

     **何が曖昧か**: <具体的に>
     **論点と選択肢**:
     - 論点A: (案1) … / (案2) …
     - 論点B: …
     **こちらのデフォルト案**: <情報がなければこう進める、という案>

     ご返信いただければ続行します。
     <!-- loop:awaiting-reply -->
     MD
     )"
     ```
     - 末尾の `<!-- loop:awaiting-reply -->` は**必ず**入れる（poll-gh が回答検知に使う）。質問は答えやすく具体的に。
     - 実装も worktree 作成もせず、報告のみ: `loop-report --task <id> --status needs_info --issue <N> --summary "<何を聞いたか1文>"`。
   - issue が無い手動タスクで曖昧なら、質問先が無いので `--status blocked --reason "情報不足: <不足点>"`。
   - 曖昧でなく方針が立つなら、そのまま次へ。

3. **隔離（Worktree）** — `git worktree add` で作業用ツリーを作り、ブランチ名は必ず `loop/<id>`。
   - **main へは絶対に直接コミット/プッシュしない。** push は `loop/<id>` のみ。

4. **実装（Fixer）** — タスク内容を実装。変更は**最小・1タスク1目的**（PR を小さく保ち、レビュー可能性を維持＝comprehension debt を抑える）。

5. **検証（Verifier ＝ 別サブエージェント）** — **自分で採点しない**。サブエージェントを1つ起動し、次を実行させて結果だけ受け取る:
   - ビルド/テスト/lint は **`$BUILD_CMD` / `$TEST_CMD` / `$LINT_CMD` を“そのまま”実行する**（compose で渡される）。
     **値が設定されていれば勝手に別コマンドへ置換しない**（例: `$BUILD_CMD` が `docker build …` なら docker build を実行する。`npm run build` 等に化けさせない）。
     サブエージェントには各変数の**展開後の実値**を渡し、実行前に `echo "$BUILD_CMD"`（等）で何を走らせるか記録してから実行する。
     **変数が空のときに限り** package.json 等から推測してよい。
   - `/code-review` で差分をレビュー
   いずれかが fail なら `status=failed`。green の時だけ次へ。

6. **提案** — 検証が green の時だけ:
   - `git push origin loop/<id>`（main 不可・force 不可）
   - `gh pr create` で PR を開く（これが人間レビューへの引き渡し。**マージはしない**）

6.5. **メモリ更新（学びの記録）— 次のタスクに効かせる** — 今回得た“**次に効く**”知識だけを `/work/loop/.loop/memory/` に簡潔に追記/更新する:
   - 新たに分かったコードベースの規約・ビルド/テスト/起動の癖・主要ファイルの在り処 → `conventions.md`
   - PR レビューで指摘された点（特に繰り返し系。例「Xの変更にはテスト必須」）→ `review-prefs.md`
   - つまずいた失敗とその回避法 → `pitfalls.md`
   追記したら必要に応じて `MEMORY.md` 索引も更新。**規律**: 1項目は短く / 既存項目は更新して重複を増やさない / 誤りは消す / 一過性・既知のことは書かない。
   学びが無ければ何もしない（空振りでも可）。※メモリは repo にコミットしない（`.loop` 配下）。

7. **報告（最後に必ず1回だけ）** — 完了報告は **`loop-report` のみ**。他の方法で「終わった」と言わない。これがドライバへの sentinel になる:

   ```bash
   loop-report --task <id> --status done \
     --branch loop/<id> --pr <PR_URL> \
     --verify "build=pass,tests=pass,review=pass" \
     --summary "<何をしたか1〜2文>" --next "<フォローアップがあれば>"
   ```

## PR レビュー指摘への対応モード（本文に `pr_number:` がある場合）

ループが開いた PR に**人間が changes-requested レビュー**を付けたときのタスク。
通常の新規実装フロー（手順3〜6）の代わりに、**既存 PR の指摘を直す**。新規ブランチ・新規 PR は作らない。

1. 本文の `pr_number` / `pr_branch` / `pr_url` を控える。
2. **指摘を読む**（changes-requested レビュー本文＋インラインコメント）:
   ```bash
   gh pr view <pr_number> --comments
   gh api repos/<slug>/pulls/<pr_number>/reviews  --jq '.[] | select(.state=="CHANGES_REQUESTED")'
   gh api repos/<slug>/pulls/<pr_number>/comments   # インライン指摘(path/line/body)
   ```
3. **既存ブランチを worktree に取り出す**（新規ブランチを作らない）:
   ```bash
   git fetch origin <pr_branch>
   git worktree add <dir> <pr_branch>
   ```
4. **指摘に対応して実装**（最小差分。指摘以外の無関係な変更を混ぜない）。
5. **検証（Verifier ＝ 別サブエージェント）** — 通常と同じ（`$BUILD_CMD`/`$TEST_CMD`/`$LINT_CMD` ＋ `/code-review`）。green の時だけ次へ。
6. **同じブランチに push して PR を更新**（新規 PR は作らない＝push で自動更新される）:
   ```bash
   git push origin <pr_branch>
   gh pr comment <pr_number> --body "🤖 loop-bot: レビュー指摘に対応しました（<short sha>）。<対応点の要約>"
   ```
7. **メモリ更新（このモードでは特に重要）** — 受けたレビュー指摘、とりわけ**繰り返し起きそうな嗜好**を `review-prefs.md` に記録する（例「APIハンドラ追加時はテスト必須」「命名は既存の camelCase に合わせる」）。次回の新規実装で**先回りして守る**ためのもの。本体メモリ規律（手順6.5）に従う。
   - **再発の検出**: 追記しようとした嗜好が `review-prefs.md` に**既に在る**なら、それは「自分の記憶を活かせず同じ指摘を受けた」＝アウトカム不良。その項目に `【再発N回】` を付けて先頭に上げ、なぜ守れなかったかを一言添える（次回より強く効かせる）。
8. **報告**: `loop-report --task <id> --status done --branch <pr_branch> --pr <pr_url> --verify "build=pass,tests=pass,review=pass" --summary "指摘<X>に対応"`。
   - 指摘が曖昧で対応方針を決められない → PR にコメントで質問し、`--status blocked --reason "PRで質問: <要点>"`（PR 側の clarification 往復は当面 blocked 扱い）。

## status の使い分け
- `done` — 検証 green かつ PR を開いた。
- `failed` — 実装したが検証 red。`--verify` に失敗箇所、`--summary` に原因。
- `needs_info` — 要件が曖昧で、issue に質問を投稿して回答待ち（手順2）。`--issue <N>` 必須。実装はしない。
- `blocked` — 権限不足・情報不足で進めない（質問先の issue も無い）。`--reason` に理由。
- `skipped` — 点検した結果、対応不要だった（“空振り”）。`--summary` に判断理由。

> **`failed`/`blocked` の `--summary`/`--reason` は driver が issue にコメントとして転記する**（結末サマリ）。
> ループ基盤と起票セッションが別マシンに分離していても、人間は `gh issue view <N> --comments` で失敗の中身を読める。
> 生ログは出ないので、**「どこで・なぜ落ちたか・次の一手」を人間可読の粒度で**書くこと（検証の失敗箇所は `--verify` に、原因は `--summary`/`--reason` に）。

## 禁止事項
- main / master への直接 push、force push、`gh pr merge`。
- `loop-report` 以外での完了申告（ドライバが検知できず詰まる）。
- `.claude/` 配下の編集（自分の番人を書き換えない）。
- 1タスクで複数の無関係な変更を混ぜること。
