# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> このリポジトリのドキュメント・コメントは日本語で統一されている。変更時もそれに合わせること。
> 出典思想: Addy Osmani "Loop Engineering"。使い方は `README.md`、仕組み・設計は `doc/architecture.md` / `doc/mechanism.md`。

## このリポジトリは何か

**自律的なコード保守ループの基盤**。開きっぱなしの Claude 対話セッション（tmux 内・サブスク認証）を、
外部トリガ（GitHub の issue ＋ PR レビュー指摘のポーリング＝唯一の入力源）で駆動し、worktree 隔離 → 実装 → 独立検証 → PR 提案までを無人で回す。
LLM を呼ぶのは「タスク処理」だけで、トリガ・ドライバ・番人はすべて素の bash（＝空振り時は課金ゼロ）。

**重要: ここはループ基盤“そのもの”の開発リポジトリ。** 保守“対象”のリポジトリは別物で、
`config.sh` の `TARGET_REPO_URL` を埋めてコンテナ内 `/work/repo` に clone される。混同しないこと。

## 3層構造（最初に理解すべき構造）

- **ルート** = 「艦隊レイヤ」: `bin/loopctl`（複数 project を1台で操作する host 側 CLI）・`.env*`（秘密）・ドキュメント。
- **`container/`** = 「コンテナ定義一式」: `Dockerfile` / `docker-compose.yml` / `config/`（マウントする loop.yaml）／ そして **`container/app/`** = 「本体」（ループが実際に動かすスクリプト・設定・状態）。
- `Dockerfile`（`container/` 配下）は **ビルドコンテキストが `container/`** なので `COPY app/ /work/loop` で **`container/app/` の中身だけ**をイメージに入れる。
  → コンテナ内では `container/app/bin/driver.sh` は `/work/loop/bin/driver.sh`、`LOOP_DIR=/work/loop`。
  パスを追うときは「`container/app/` を剥がすと `/work/loop/`」と読み替える。
- **なぜ container/ にまとめたか**: loopctl（艦隊＝N コンテナを束ねる host レイヤ）と、コンテナ1個分の定義・中身を物理的に分けるため。`bin/loopctl` は `container/docker-compose.yml` を `-p loop-<name>` で多重起動するだけ。詳細は下の「複数 project の運用」。

## 設計の核（“なぜこの形か”を読まずに触ると壊す）

1. **pane を触るのは driver ただ1つ。** `enqueue.sh` は `tmux send-keys` を**呼ばない**——
   `.loop/queue/<id>.md` にファイルを置くだけ。これで注入の混線（並行・割り込み）を構造的に回避している。
   driver は1件ずつ直列処理し、`inject()`（`bin/lib.sh`）で**短い固定フレーズだけ**注入する（タスク本文はファイル側）。
2. **完了判定はターミナルを parse しない。** Claude は最後に `loop-report` を1回叩き、
   `.loop/results/<id>.json`（= sentinel ＋ status ＋ 検証結果）を書く。driver はこのファイルの出現を待つ（`wait_result`）。
   `pane_text`/`capture-pane` は**生存確認と stuck 分類専用**で、成否判断には使わない（`classify_stuck`: working/limit/modal/crashed/hung）。
3. **検証は自己採点禁止（Fixer/Verifier 分離）。** タスク処理手順は `container/app/.claude/skills/loop-task/SKILL.md`。
   実装（Fixer）と検証（別サブエージェントが `$BUILD_CMD`/`$TEST_CMD`/`$LINT_CMD` ＋ `/code-review` を実行）を分ける。
4. **番人は層状。** コンテナ CMD は `entrypoint.sh`（**root で動く唯一の層**）。これが dind の `dockerd` を起こし、
   準備完了を待って `gosu node ./bin/supervisor.sh` に降格する。`supervisor.sh` が `session-keeper`（claude 生存）＋ `driver`（タスク進捗）＋ `poller`（issue 取得）を起動。
   どれか1つでも死ねば supervisor が全部落とし、さらに entrypoint が `dockerd` と supervisor を `wait -n` で束ねて**どちらか落ちたら両方落とす**→ compose の `restart=unless-stopped` が最外で立て直す。
   keeper は crash-loop サーキットブレーカ（`CRASH_LIMIT`/`CRASH_WINDOW`）付き。
5. **権限の最小化。** コンテナに渡す秘密は1個だけ（**GitHub App の秘密鍵**、PAT 運用なら `GH_TOKEN`）。
   認証は `bin/gh-token.sh` に一元化＝App なら短命 installation token を発行・キャッシュ、静的 `GH_TOKEN` ならそのまま供給。
   git は credential helper、`gh` は PATH ラッパー(`/usr/local/bin/gh`)経由で毎回フレッシュなトークンを使う（App の1時間失効を吸収）。
   `container/app/.claude/settings.json` は
   `acceptEdits` ＋ allowlist ＋ deny（main 直 push / force / `gh pr merge` / `rm -rf` / `.env` 読み / `.claude/` 編集を禁止）。
   push は `loop/<id>` ブランチのみ、マージは必ず人間。PR の向き先(base)は `PR_BASE_BRANCH`（既定 main）で設定可＝作業ブランチもこの base から切る。
   - **Docker は自前で持つ（dind / B案）。** 対象 repo が Docker 化されていても触らず、その `Dockerfile`/`compose` を**箱の中の dockerd でそのまま**ビルド・検証する。
     ホストの `docker.sock` は渡さない＝この箱で完結。代償は compose の `privileged: true`（内側 dockerd が cgroup/iptables/overlay を握るため必須）で、
     これは「箱＝使い捨ての VM / EC2」前提で受容する（breakout しても箱の中＝VM-root まで・ホストや隣のプロジェクトには届かない）。
     root で動くのは `dockerd` ただ1つ、LLM スタックは従来どおり node。`settings.json` の allowlist に `docker compose`/`docker build` 等を追加済み
     （ただし `docker` を握ると deny は原理的に迂回可能＝箱の使い捨て性が最後の砦）。`/var/lib/docker` は名前付き vol（実FS）に逃がし overlay on overlay を回避。

## タスクのライフサイクル（ファイル＝状態機械）

```
trigger（poll-gh=issue / poll-pr=PRレビュー指摘） → enqueue.sh → .loop/queue/<id>.md
  driver が拾う → .loop/state/<id>.inprogress を立てて inject
  Claude が loop-report → .loop/results/<id>.json(status)
  driver が route_result でルーティング:
    done       → .loop/processed/   （✅ PR 通知）
    skipped    → .loop/processed/   （空振り）
    needs_info → .loop/awaiting/     （issue に質問済み・人間の回答待ち。state に issue-<N>.awaiting）
    timeout    → .loop/awaiting/     （規定時間超過で中断・自己申告済み・人間トリアージ待ち。state に issue-<N>.awaiting）
    failed/blocked/壊れた result → .loop/blocked/  （⚠️ 通知 ＋ issue に結末コメント）
```

- **タイムアウト＝「分割ミスのフィードバック」（チェックポイント方式）**: driver は `TASK_TIMEOUT`（既定20分。`loop:long` ラベルの issue は `TASK_TIMEOUT_LONG`＝既定60分）まで待ち、超過かつ `classify_stuck`=working なら**延長せず Escape で中断**し、Claude に「経過・なぜ終わらないか・今後の方針」を issue にコメントさせ `loop-report --status timeout` で自己申告させる（`CHECKPOINT_GRACE` 内に返らなければ応答不能とみなし再キュー）。外からは「遅いだけ」か「堂々巡り」か判別できないので、本人に申告させ人間がトリアージ（redo / 分割 / `loop:long`）する。経験則「規定時間で終わらないタスクは大抵終わらない」に基づき、旧来の「working の間は見限らず延長・detach・reaper」は**廃止**した。`classify_stuck` の modal 判定は「生成停止＋末尾に許可フレーズ＋選択肢UI」の3条件に限定（実装中出力の誤検知＝偽 blocked を防ぐ）。
- **失敗の結末を issue に残す（分離環境対応）**: `route_result` の `failed`/`blocked`/壊れた result と、modal 停止時に、driver が `comment_outcome()` で **issue にコメント**（`--summary`/`--reason`/`--verify`/`--next` の要約＋隠しマーカー `<!-- loop:outcome -->`）。ループ基盤と起票セッションが別マシンでも、人間は `gh issue view <N> --comments` で失敗の中身を読める＝GitHub を唯一の共有面に使う（生ログは出さない＝漏えい面の最小化。raw は基盤側 `.loop/logs`）。crashed/hung は requeue 前提でスパム回避のため無コメント。
- **タスク毎に `/clear`（文脈リセット＝コスト最適化）**: driver は次タスクの注入直前（pane idle 時）に `clear_context()` で `/clear` を注入し、前タスクの会話文脈を捨てる（`CLEAR_BETWEEN_TASKS`＝既定 true・`CLEAR_SETTLE` で安定待ち）。**タスクは互いに独立**（worktree 隔離・issue 駆動・各タスクが開始時に `.loop/memory` を読む）で、**跨ぐ知識は会話履歴ではなくメモリのファイル側**に置く設計なので、履歴を捨てても次タスクは同じ状態から始められる。狙いは累積文脈による毎タスクの入力トークン増（会話が伸びるほど二次関数的）とオートコンパクト費を断つこと（重いログを Haiku 委譲でメイン文脈に溜めない最適化と同根）。注入はタスク境界でのみ起こるので、タイムアウト時の自己申告など**タスク内の文脈連続性は壊さない**。
- 起動時 `recover_inflight()`: `*.inprogress` が残っていれば中断とみなし result を消して再処理（queue に残す）。
- `state/issue-<N>.seen` = 既処理（再投函しない）。`state/issue-<N>.awaiting` = 回答待ち。`state/issue-<N>.blocked` = 依存未完了で待機中。`state/pr-<N>.review` = 対応済みレビュー id。
- **再着手ジェスチャ `loop:redo`**: 既処理 issue を「もう一度やって」と人間が指示する手段。ファイルを触らず **issue に `loop:redo` ラベルを付けるだけ**（iOS でもタップ可）。
  `poll-gh.sh` の redo パスが `.seen`/`.awaiting`/`.blocked` を消し、`loop:redo` を外して `loop` を付け直す→本処理パスが通常どおり再 enqueue（1回で消費＝冪等）。再オープン検出の通知もこのラベルを案内する。ラベルは `setup-target` が冪等作成。
- **長時間許可ジェスチャ `loop:long`**: 「この issue は時間がかかる」と人間がトリアージするための**持続的な属性ラベル**（`loop:redo` と直交。timeout で中断した issue を「長いだけ」と判断した時に付けて再開する、または最初から長いと分かっている issue に付ける）。`poll-gh.sh` が enqueue 時にこれを見て task 本文に `task_timeout: $TASK_TIMEOUT_LONG` を書き、driver のチェックポイントを既定20分→60分に延ばす（無制限ではない＝超えればやはり中断・自己申告）。ラベルは `setup-target` が冪等作成。
- **プランモード `loop:plan`（議論はするが実装しない）**: 「`loop` 無しだと bot が見に来ない／`loop` を付けると実装まで走ってしまう」の**中間状態**を埋めるラベル。付くと `poll-gh.sh` は（`loop` が無くても）この issue を拾い、`mode: plan` を task 本文に書いて投函＝loop-task は**コードに一切触れず**、issue 本文＋全コメント＋メモリを読んで**方針/設計をコメントで応答**するだけ（worktree・実装・PR・検証コマンドは無し）。bot は末尾に awaiting マーカーを付け `loop-report --status plan` で報告→driver が `.awaiting` に置く＝**needs_info と同じ往復配管を再利用**し、人間が返信すれば再 enqueue してまた応答する（`loop:plan` が付く限り何度でも議論）。**実装への移行＝人間が `loop:plan` を外して `loop` に付け替えるだけ**（ラベル＝人間ゲートの既存思想に統一・iOS でもタップ可）。`poll-gh` は `state/issue-<N>.fromplan` マーカーでこの「プランからの昇格」を検知し、プラン中の待機 state を捨てて最新の議論を踏まえた新規実装として走らせる（awaiting マーカーが最新でも待たない＝ラベル切替が実装の合図）。`loop` と `loop:plan` が両方付く間は安全側に倒して**プランが優先**（実装しない）。議論はゲートしないので settle/依存(blocked_by)/`loop:long` は適用しない。ラベルは `setup-target` が冪等作成。
- **環境からゴール生成（依存脆弱性）**: `poll-deps.sh`（LLM 非依存。実行頻度は `POLL_DEPS_CRON`＝既定 `0 3 * * *`=毎日3時が唯一の権威。旧 `DEPS_INTERVAL` の内部スロットルは廃止＝cron と二重管理・増回の握り潰しを避けた）が `AUDIT_CMD`（既定 `npm audit --json`）で対象 repo を監査。
  high/critical かつ修正版がある脆弱性を**自動で issue 起票**（非メジャー→`loop`＝実装〜PRまで自走／メジャー→`loop:proposed`＝人間承認）。重複は `state/dep-<advisory>.filed` で抑制、1回 `DEPS_MAX_PER_RUN` 件まで。マージは人間ゲート・Verifier が通らなければ PR は出ない。
- **環境からゴール生成（仕様書駆動の自律分解）**: `poll-spec.sh`（LLM 非依存。`ENABLE_POLL_SPEC`／既定 15 分間隔。`spec/` が無ければ no-op）が対象 repo の `SPEC_DIR`（既定 `spec/`）を入力に、**フェーズ単位で issue 群を自律生成**する。入力＝`00-overview.md`（全体像・共通制約）＋ `NN-slug.md`（フェーズ1枚＝意味の単位）。**フェーズ = GitHub マイルストーン「NN: slug」**（完了検知＝`open_issues==0` かつ `closed>0`／自前 state 台帳が不要）。**遅延分解**＝前フェーズ完了を検知したら次フェーズを1回だけ分解（前フェーズのマージ済み実物を読んで割る＝drift 補正）。poll-spec(bash) は「次に分解すべきフェーズの検知」と「マイルストーン作成（＝冪等マーカー。存在＝分解済み/分解中）」だけを行い、実際の分解は `LOOP_SOURCE=spec` で投函する**分解タスク**（`loop-decompose` スキル／`setup-target` が配布）に委譲＝**LLM はそこだけ**。分解器は spec を 1 PR 単位（目安 ~10 分粒度・フェーズ内 issue 数は無制限）の issue に割り、`--milestone` で紐付け・`blocked_by` で順序配線・**最後に `loop` ラベル**（作成→依存→ラベルの順＝poll-gh が拾う時に依存が揃う）。**承認ゲートは PR マージに移動**（issue 再承認はしない＝spec を人間が承認済み・マージは必ず人間なので全自動でも main に勝手に入らない）。分解タスクが空マイルストーンを残して失敗したら driver が ⚠️ 通知＝人間が GitHub でそのマイルストーンを削除すれば次 poll で再分解（GitHub を唯一の共有面に）。
- **main の CI 失敗 → 起票**: `poll-ci.sh`（poller が毎周回実行・LLM 非依存）が `CI_WORKFLOW`（既定空＝無効）で指定した GitHub Actions ワークフローの、`CI_BRANCH`（既定 main）の**最新の完了 run**を見て、`failure`/`timed_out`/`startup_failure` なら **issue 自動起票**（既定 `CI_ISSUE_LABEL=loop:proposed`＝人間承認後／run URL ＋失敗ジョブ名を添える・生ログは貼らない）。重複は run id ごとの `state/ci-<id>.filed` ＋隠しマーカー `<!-- loop:ci-failure -->` 付き open issue の存在で抑制。CI 修正は調査＋再CI待ちで長くなりがちなので **既定で `loop:long` も付ける**（`CI_ISSUE_LONG=true`／timeout→再実行の二重払いを避ける）。
  **重いテストを自前 dind で再現せず、マージを実際にゲートしてる正規環境（CI）の結果をそのまま受け取る**設計（サンドボックス由来の偽陽性が出ない・計算ゼロ・poll-outcome と同型の継続監視）。per-task の Verifier は未 push ブランチを検証するので従来どおり自前 dind のまま（CI はまだ走らない）＝役割が違う。
- **アウトカム観測（結末をメモリに返す）**: `poll-outcome.sh`（poller が毎周回実行・LLM 非依存）がマージ済み loop PR の“その後”を見て、
  **revert された / 閉じた issue が再オープンした**という**負のアウトカム**を検出し、`.loop/memory/outcomes.md` に追記＋⚠️通知。`.loop/outcomes/` のマーカーで冪等。
  これで「テスト緑」という代理指標でなく**現実の結末**がメモリに返り、loop-task が次に同じ轍を踏まないよう参照する（＝検証の自己採点を現実で補正する）。
- **トリガは全て opt-in（本体既定 false）**: `ENABLE_POLL_<NAME>`（GH/PR/OUTCOME/DEPS/CI/SPEC）の**本体既定は全て false ＝何もしない素の箱**。使うトリガだけ `config/loop.yaml` で `true` にする（poll-gh＝主入力すら明示的に on）。狙いは本体を inert に保ち、挙動を config 側の意思表示だけで決めること。新しいトリガを足す時もこの規約（既定 false）に揃える。
- **ポーラーの実行スケジュール（cron 書式・ポーラー毎）**: `poller.sh` は `POLL_TICK`（既定60s）で起き、各ポーラーの予定を判定する（`run_poll`＝`ENABLE_POLL_<NAME>` トグルと併せて捌く）。**cron デーモンには依存せず、cron の“書式”だけ自前 bash（`lib.sh` の `cron_match`／`_cron_field`）で評価する**（＝「番人は素の bash」を保ったまま表現力だけ cron に揃える）。`POLL_<NAME>_CRON`（GH/PR/OUTCOME/DEPS/CI）で:
  - **空** → 既定間隔 `POLL_GH_INTERVAL`（15分）ごと（後方互換・`due_every`／`state/poll-<name>.lastrun`。deps/ci は中でさらに self-throttle）
  - **cron式**（標準5フィールド「分 時 日 月 曜」, `*` `a-b` `a,b` `*/s` 対応）→ マッチする分に1回（`due_cron`／同分重複は `state/poll-<name>.lastmin` で抑止・TZ 基準）。例 `"*/30 * * * *"`=30分毎, `"0 3 * * *"`=毎日3時, `"0 9 * * 1-5"`=平日9時。
  起動時は間隔系 `lastrun` を消して各ポーラーを1回走らせる（再起動後すぐ拾う／cron の `lastmin` は残し同分2重実行を防ぐ）。dom/dow は AND 判定（標準 cron の OR 例外は踏襲しない）。
- **ループのメモリ（タスクを跨ぐ学習）**: `.loop/memory/`（`MEMORY.md` 索引 ＋ `conventions.md`/`review-prefs.md`/`pitfalls.md`/`outcomes.md`）。
  loop-task が**開始時に読み**（既知の規約・レビュー嗜好・失敗を踏まえて実装）、**終了時に“次に効く”学びだけ書き戻す**。対象 repo の外（PR に混入しない）・バインドマウントで永続。
  狙いは「毎回まっさらな1回プロンプト」からの脱却（＝経験を蓄積して賢くする）。特に PR レビュー指摘を `review-prefs.md` に溜めて新規実装で先回りさせる。setup-target が冪等 seed。
- **PR レビュー往復（changes-requested → 修正）**: `poll-pr.sh` が `loop/*` の open PR を見て、**人間（`user.type=="User"`）の最新 changes-requested レビュー** id を検出。
  `state/pr-<N>.review` に未記録なら `LOOP_SOURCE=pr-review` で修正タスクを投函（本文に `pr_number`/`pr_branch`）→ SKILL の「PR レビュー指摘対応モード」が**既存ブランチに push して PR 更新**（新規 PR は作らない）。
  対応済みレビュー id を記録するので同じ指摘では再発火せず、人間が**新しい** changes-requested を出すと再発火する。App により author で判定＝隠しマーカー不要。
- **依存関係（順序制御）**: GitHub ネイティブの issue dependencies（"blocked by"）を `poll-gh.sh` が REST（`dependencies/blocked_by`）で参照。
  ブロック元が未完了（open、または closed でも `not_planned`）なら enqueue せず `.seen` も立てない＝次 poll で再評価。
  ブロック開始時に `.blocked` を立てて1回だけ ⛔ 通知し、解消したら消す。独自規約ではなく GitHub 標準の関係を使う。
- **needs_info の往復**: bot が曖昧と判断 → issue にコメント（末尾に隠しマーカー `<!-- loop:awaiting-reply -->`）→ driver が `.awaiting` を立てる
  → `poll-gh.sh` は最新コメントがマーカーのままなら待機継続、人間が返信したら `.awaiting` を消して再投入。
  判定はコメント本文の隠しマーカーで行う（マーカー文字列は `poll-gh.sh` と `SKILL.md` で一致必須）。
  ※当初は bot と人間が同一 PAT で投稿し author で区別できなかったための方式。**GitHub App 運用では bot は別 author（`…[bot]`）になるため author 判定に置換可能**だが、マーカー撤去は未実施（PR レビュー往復の実装とあわせて行う予定）。

## `.claude/` が3系統あることに注意（用途が別）

- **リポジトリ直下の `.claude/`** = この基盤を**開発するセッション**（あなた）用。bash の構文チェックや compose 操作を許可する軽い設定。
- **`planner/`**（root の人間レイヤ）= **人間が対象 repo の checkout で使う**プランナー道具（`skills/draft-loop-issue`・`commands/draft-loop-spec.md`）。コンテナにも対象 repo にも自動配布されない＝人間が `~/.claude/` へコピーして使う。**`container/app/`（イメージ payload）の外**に置く（配布されない＝コンテナに不要だから。bin/loopctl と同じ host/人間レイヤ）。
- **`container/app/.claude/`** = 保守対象 repo へ**配布される**プロファイル（自分用ではない）。`setup-target.sh` が対象 repo の `.claude/` に
  `settings.json` と `skills/loop-task/`・`skills/loop-decompose/`（あれば `agents/`）をコピーする。`container/app/.claude/skills/loop-task/SKILL.md` を編集すると
  **ループの挙動そのもの**が変わる（権限・手順・禁止事項）。ここはループの「番人」なので慎重に。
  → 開発用の緩い権限を `container/app/.claude/` に書かないこと。混同するとループの安全装置を弱める。
- **`container/app/.claude/skills/loop-decompose/`** = **仕様フェーズの分解スキル（executor 側＝無人）**。`poll-spec.sh` が `LOOP_SOURCE=spec` で投函した分解タスク（本文に `spec_phase:`）を loop-task が委譲する。spec の1フェーズを 1 PR 単位の issue 群に割って起票するだけ（コード・PR は作らない）。draft-loop-issue（人間用）と違い **`setup-target` が配布する**（bot の `/work/repo` で動くため）。
- **`planner/skills/draft-loop-issue/`**（root の人間レイヤ。コンテナには入れない＝`container/app/` の外）= **人間（プランナー役）が対話的に使う起票スキル**。`loop-task`（executor＝無人）と対になる入力側の道具で、
  **`setup-target` では配布しない**（bot の `/work/repo` ではなく、人間が対象 repo を checkout したセッションで使う）。設置は人間のグローバル `~/.claude/skills/` か、対象 repo へコミット。
  狙いは「issue の質がループ出力の質を決める」を踏まえ、対象 repo に接地した精密な issue を `loop`/`loop:proposed` で立てること（認知の欠落(1)の人間ドリブン版）。
- **`planner/commands/draft-loop-spec.md`**（root の人間レイヤ。コンテナには入れない）= **人間が対話的に叩く spec 起草スラッシュコマンド** `/draft-loop-spec`（`draft-loop-issue` の上流）。`grill-me` 風に**容赦なく問い詰めて**曖昧さを潰し、対象 repo に接地して `poll-spec` が食う `spec/`（`00-overview.md` ＋ フェーズ毎の `NN-slug.md`）を書き出す。issue までは割らない（それは `loop-decompose` の仕事）。**ファイル生成のみ**で commit/push/PR はしない（spec は既定ブランチに入った瞬間に自動分解が始まる重い変更なので人間が反映を判断）。skill ではなく command にしたのは「人間が意図的に起動する対話ツール」だから。`draft-loop-issue`（skill）同様 **`setup-target` では配布しない**（人間が `~/.claude/commands/` か対象 repo にコピーして使う）。

## 複数 project の運用＝`loopctl`（艦隊 CLI）

**`project = 1 コンテナ` のまま、複数 project を1台でまとめて操作する薄い bash CLI**（`bin/loopctl`＝ホスト側ツール。`app/bin` は箱の中身なので別物）。
箱を融合せず（隔離は Docker に任せる）、`docker compose -p loop-<name>` を組み立てるだけ＝**コンテナ内のスクリプトは一切変えない**。
- 構成3層: ① このリポジトリ＝イメージ源（共有・1回 build・loopctl 同梱） ② `~/.looptrooper`＝実行時データ（`.env` 秘密1枚を全 project 共有 ＋ `projects/<name>/{config/loop.yaml, .loop}`） ③ Docker volume＝`-p loop-<name>` が `claude-home`/`docker-lib` を**自動で project 分離**（dind も認証 volume も per-project）。
- per-project の非秘密設定は**既存の `loop.yaml` 機構そのまま**（`projects/<name>/config/loop.yaml` を `/work/config` にマウント）。秘密は共有 `.env`。
- 認証はサブスクの refresh が**使い切り回転**＝共有不可（`docs`/メモリ参照）。**`/login` は project 毎に1回**（生涯1回・自走更新）。
- 初回フロー: `loopctl init`（土台＋共有イメージ build）→ `create <p>`（loop.yaml 雛形）→ 編集 → `start <p>` → `login <p>`。
- 他: `status / list / logs / stop / upgrade [--all]（共有イメージ再build→drain→recreate）/ destroy`。
- 単一 project の直 `docker compose up`（下記）も**後方互換で残る**（compose の変数に既定値あり）＝デバッグ用。

## よく使うコマンド

> **`exec` は必ず `-u node`。** dind 化で entrypoint を root で動かすためコンテナの既定ユーザが root になった。
> tmux セッション・`.loop`・`/work/repo` はすべて node 所有なので、`docker compose exec` を素で打つと root で実行され
> tmux は「no session」、clone は root 所有ファイルを作って node が書けなくなる。人間が打つ exec は `-u node` を付ける。
> 複数 project を運用するなら下記の素の compose ではなく **`loopctl`（上記）**を使う。下記は単一 project デバッグ用。

```bash
# 素の docker compose は container/ 配下で実行（compose が container/docker-compose.yml に移動）
cd container

# ビルド & 起動（本番運用）
docker compose build
docker compose up -d
docker compose exec -u node loop ./bin/setup-target.sh        # 対象 repo clone + 設定/認証流し込み（冪等。supervisor も起動時に自動実行）
docker compose exec -u node loop tmux attach -t loop          # 初回のみ /login でサブスク認証 → detach は Ctrl-b d

# 1件流して動作確認（入力は issue 限定。loop ラベル issue を立てて poller に拾わせる）
gh issue create -R <owner>/<repo> --label loop --title "smoke test" --body "READMEのtypoを1つ直してPRを開いて"
docker compose exec -u node loop ./triggers/poll-gh.sh        # 次の定期 poll を待たず手動で1回回す

# 状態とログ
docker compose exec -u node loop ./bin/status.sh              # 一括ダッシュボード（番人/認証/タスク/GitHub/メモリ/アウトカム/直近通知）
docker compose config >/dev/null                             # compose のパラメータ化が壊れていないか（container/ で実行）
cat ../container/app/LOOP_STATE.md                            # 人間用の状態ボード（静的メモ。ライブ状況は status.sh）
tail -f ../container/app/.loop/logs/driver.log               # 判断系ログ（root からは container/app/.loop/logs/）
```

```bash
# スクリプトの構文チェック（リポジトリ root で。テストスイートは無い ── 全て bash）
bash -n bin/loopctl container/app/bin/*.sh container/app/bin/loop-report container/app/triggers/*.sh
```

**タスク入力は GitHub issue に限定。** 唯一の入力源は対象 repo の `loop` ラベル付き issue で、`poll-gh.sh` が拾う。
`enqueue.sh` は poller 専用の内部プリミティブ（`LOOP_SOURCE=issue` が無いと拒否＝手動・git hook からは投函不可）。
内部呼び出し形: `LOOP_SOURCE=issue enqueue.sh "<title>" -`（本文は stdin / ファイル / 省略）。

## 開発上の約束ごと

- **テストフレームワークは無い。** 中身は bash スクリプト群（README 上「雛形・未テスト」）。
  変更後は最低限 `bash -n` で構文確認し、可能ならコンテナ内で実地に1件流す。
- 全スクリプトは先頭で `source ./config.sh`（中央設定・全パスとタイミングの単一ソース）→ 必要なら `source ./bin/lib.sh`（共有関数 `log`/`notify`/`inject`/`wait_result`/`classify_stuck`）。
  新しい定数やパスは `config.sh` に集約し、スクリプトに直書きしない。
- **設定の入力は2層**: `config.sh` 冒頭が `loop.yaml`（箱レベルにマウント・非秘密設定・`yq` でパース）を読み、環境変数へ展開する。**優先順位は env（`.env`/compose）> `loop.yaml` > 既定**（`config.sh` の `${VAR:-...}`）。**秘密（GitHub App 秘密鍵 / `GH_TOKEN` / `SLACK_WEBHOOK_URL` / `NOTIFY_CMD` / `TZ`）は `.env` のまま**、それ以外の設定は `config/loop.yaml`（雛形 `config/loop.yaml.example`）。yaml はフラットな「環境変数名: 値」形式で、新キーを足しても loader 改修は不要。`config/loop.yaml` が無い/`yq` 不在ならフェイルセーフで `.env` だけで動く。**`config/` はディレクトリごとマウントする**（単一ファイル bind mount はエディタの atomic-replace で inode が変わりコンテナ側が stale/破損する＝yq が壊れた古い実体を読み全設定が既定に落ちる事故を踏んだため。所在は compose の `LOOP_CONFIG_YAML`）。session-keeper が config を source して tmux を起こすので claude セッションにも継承される。
- 通知は `notify()` 経由。`SLACK_WEBHOOK_URL` があれば Slack へ（`slack_post()` が Block Kit の attachment＝先頭絵文字から重大度→色のサイドバー＋本文＋repo/時刻のコンテキスト行でリッチ送信）、無ければログのみ。`NOTIFY_CMD` を直接定義すれば上書きでき（Discord 等）、その場合はリッチ整形を通さず生テキストを stdin で渡す。
- **このリポジトリ（LoopTrooper 本体）の `main` は直 push してよい。** ただし**保守対象プロジェクト**の `main` への push は禁止（loop/* ＋ PR のみ）。
