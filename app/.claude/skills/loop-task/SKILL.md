---
name: loop-task
description: ループのドライバから注入された1件のタスクを、worktree隔離・独立検証・PR提案・loop-report報告まで自律処理する手順。「次のタスクを処理して: <path>」と指示されたら必ずこれに従う。
---

# loop-task

ドライバが「**次のタスクを処理して: `<path>`**」と指示したら、この手順に**厳密に**従う。
原則は記事のループエンジニアリング: 実装役(Fixer)と検証役(Verifier)を分け、**自分の宿題を自分で採点しない**。
さらにコスト/文脈節約のため、安いモデル(Haiku)へ2種類の委譲を徹底する（あなた＝メインは Sonnet 固定のまま）:
- **コードベースの調査（広い読み込み）→ 読み取り専用 `research` サブエージェント（Haiku）**
- **重い/ログの多いコマンド実行 → `verify-runner` サブエージェント（Haiku）**。最終検証だけでなく、**失敗の再現・デバッグのための実行**（CI で落ちた e2e の再現、docker build、npm ci など大量ログを吐くもの）も委譲する。
  メインスレッドで重いコマンドを直接叩くと、その巨大ログが Sonnet 文脈に流れ込んでコストが跳ねる（実測でこれが最大の浪費だった）。**メインで直接 Bash するのは出力の軽い操作だけ**にする。

## 手順

1. **タスク読込** — 指定された `<path>`（例 `/work/loop/.loop/queue/<id>.md`）を Read。ファイル名から `<id>` を控える。本文に `issue #<N>` があれば `<N>` も控える。
   - **本文に `pr_number:` があれば、新規実装フローではなく後述の「PR レビュー指摘への対応モード」に切り替える**（既存ブランチの修正・新規 PR は作らない）。
   - **本文に `spec_phase:` があれば、実装フローではなく `loop-decompose` スキルの手順に従う**（このフェーズの仕様を 1 PR 単位の issue 群に分解して起票するタスク。コード実装・worktree・PR は作らない）。以降の手順はこのスキルではなく loop-decompose に従うこと。

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
   - **作業ブランチは PR の向き先（base）から切る** — base は `$PR_BASE_BRANCH`（未設定なら `main`）。最新を取得してそこから分岐する:
     ```bash
     git fetch origin "${PR_BASE_BRANCH:-main}"
     git worktree add <dir> -b loop/<id> "origin/${PR_BASE_BRANCH:-main}"
     ```
     （base を main 以外にする運用があるため。base から切らないと PR 差分に base↔main の差が混ざる。）
   - **base ブランチへは絶対に直接コミット/プッシュしない。** push は `loop/<id>` のみ。

4. **実装（Fixer）** — タスク内容を実装。変更は**最小・1タスク1目的**（PR を小さく保ち、レビュー可能性を維持＝comprehension debt を抑える）。
   - **編集前の調査は `research` サブエージェント（Haiku・読み取り専用）に委譲する** — 「どこを変えるか」「構造・規約・既存の類似実装」「使用箇所の検索」など広く読む探索は research に投げ、返ってきた要約（`path:line`）を起点に動く。**実際に編集するファイルだけ自分で読む**（広い探索をメインの Sonnet 文脈に溜めない＝コストと文脈の節約）。
   - 編集そのもの（Write/Edit）はこのメインスレッド(Fixer)が行う。research には編集させない。
   - **デバッグのために重いコマンドを回す必要が出たら（CI で落ちた e2e を再現する・docker build を試す・特定テストだけ走らせる等）、メインで直接叩かず `verify-runner`（Haiku）に投げる**。返ってくる PASS/FAIL ＋要点だけを見て次の手を決める（巨大ログを Sonnet 文脈に溜めない＝今回のコスト浪費の主因をここで断つ）。軽い確認（`ls`/`cat` 数行/`git status` 等）は直接でよい。

5. **検証（自分で採点しない＝別サブエージェント）** — メイン(Fixer)は採点しない。2つに分けて、いずれも別サブエージェントに任せる:
   - **5a. ビルド/テスト/lint の実行 → `verify-runner` サブエージェント（Haiku）** — `$BUILD_CMD` / `$TEST_CMD` / `$LINT_CMD` を**“そのまま”実行**（compose で渡される実値。**勝手に別コマンドへ置換しない**＝`docker build …` を `npm run build` 等に化けさせない。変数が空のときだけ推測可）。verify-runner には各変数の**展開後の実値**を渡す。返ってくるのは **PASS/FAIL と失敗時の最小抜粋だけ**（npm ci 等の長いログ全文はメイン文脈に持ち込まない＝安いモデルで消化させコストと文脈を節約）。
   - **5b. コードレビュー → 別サブエージェント（Sonnet）** — `/code-review` で差分をレビュー。バグ検出の品質ゲートなので Haiku に落とさず Sonnet（model 既定=inherit）で行う。
   - 5a / 5b いずれか fail なら `status=failed`。両方 green の時だけ次へ。

6. **提案** — 検証が green の時だけ:
   - `git push origin loop/<id>`（base 直 push 不可・force 不可）
   - `gh pr create --base "${PR_BASE_BRANCH:-main}"` で PR を開く（向き先は base ブランチ。これが人間レビューへの引き渡し。**マージはしない**）

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
5. **検証** — 通常と同じ（手順5）。**5a. `verify-runner`(Haiku) でビルド/テスト/lint 実行 → 5b. 別サブエージェント(Sonnet) で `/code-review`**。両方 green の時だけ次へ。
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
- `timeout` — driver から規定時間超過で中断を指示された時のみ使う（自発的には使わない）。後述「中断報告モード」参照。`--issue <N>`。

> **`failed`/`blocked` の `--summary`/`--reason` は driver が issue にコメントとして転記する**（結末サマリ）。
> ループ基盤と起票セッションが別マシンに分離していても、人間は `gh issue view <N> --comments` で失敗の中身を読める。
> 生ログは出ないので、**「どこで・なぜ落ちたか・次の一手」を人間可読の粒度で**書くこと（検証の失敗箇所は `--verify` に、原因は `--summary`/`--reason` に）。

## 中断報告モード（driver から「規定時間超過」で中断を指示されたら）

実装の途中で「⏸ 規定時間（…秒）を超過しました。…作業を中断し…報告してください」と注入されたら、このモードに切り替える。
規定時間内に終わらなかった＝issue が大きすぎ／曖昧／想定外の障害、のいずれか。**外（システム）からは「遅いだけ」か「堂々巡り」か判別できない**ので、
あなた自身が状況を申告して人間にトリアージ（redo / 分割 / `loop:long`）を委ねるのが目的。

1. **新たな実装はしない**。動いている作業を止める（worktree の変更は破棄前提＝push しない）。
2. **issue にコメントで自己申告**する。末尾に awaiting マーカー（`<!-- loop:awaiting-reply -->`）を必ず入れる:
   ```bash
   gh issue comment <N> --body "$(cat <<'MD'
   🤖 loop-bot: 規定時間を超過したため作業を中断しました。

   **ここまでの経過**: <何を実装/調査し、どこまで進んだか>
   **なぜ終わらなかったか**: <時間がかかる理由 / 詰まり。例: テスト一式に N 分 / X で堂々巡り / 依存 Y 未解決>
   **今後の方針**: <続ければ終わる見込みか / 分割すべきか / 要件確認が要るか>

   ご判断ください（そのまま再実行なら `loop:redo`、時間のかかる作業なら `loop:long` も併せて、分割なら issue を分けてください）。
   <!-- loop:awaiting-reply -->
   MD
   )"
   ```
3. **報告**: `loop-report --task <id> --status timeout --issue <N> --summary "<中断理由を1文>"`。
   driver がこれを人間トリアージ待ち（awaiting）に置く。**部分実装は残さない**（次の着手は新しい worktree でやり直し）。

## 禁止事項
- main / master への直接 push、force push、`gh pr merge`。
- `loop-report` 以外での完了申告（ドライバが検知できず詰まる）。
- `.claude/` 配下の編集（自分の番人を書き換えない）。
- 1タスクで複数の無関係な変更を混ぜること。
