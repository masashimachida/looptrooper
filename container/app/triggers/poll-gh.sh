#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# issue ポーリングのトリガ（LLM を呼ばない＝無課金）。
#   'loop' ラベルの open issue をタスク化する。冪等: 既処理はスキップ。
#   supervisor 配下の poller.sh が POLL_GH_INTERVAL 間隔で常駐実行する（cron 不要）。
#
# 曖昧タスクの確認フロー（再投入）:
#   bot が曖昧と判断 → issue に質問コメント（末尾に隠しマーカー AWAIT_MARKER）
#   → driver が issue-<N>.awaiting を立てる。ここでは「回答待ち」として投入しない。
#   人間が返信（=最新コメントがマーカー以外）したら .awaiting を消して再投入する。
#   ※判定はコメント本文の隠しマーカーで行う（現状）。当初は bot と人間が同一 PAT で
#     author 区別できなかったための方式。GitHub App 運用では bot は別 author なので
#     将来は author 判定に置換可能（マーカー撤去は未実施）。
# ─────────────────────────────────────────────────────────────
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
source ./config.sh
source ./bin/lib.sh
mkdir -p "$STATE_DIR"

command -v gh >/dev/null 2>&1 || { echo "gh not installed" >&2; exit 1; }

# cwd は /work/loop（ループ基盤側）なので gh の自動 repo 解決は使えない。
# 保守対象 repo(/work/repo) の remote から owner/repo を割り出して -R で明示する。
# slug 解決は lib.sh の target_slug() に集約（issue URL 生成と単一ソース）。
target_slug=$(target_slug)
[ -n "$target_slug" ] || { echo "ERROR: 対象 repo の slug を解決できません ($TARGET_REPO_DIR)" >&2; exit 1; }

# bot が質問コメントの末尾に必ず入れる隠しマーカー（loop-task と一致させること）
AWAIT_MARKER='<!-- loop:awaiting-reply -->'

# issue-<N>.awaiting を消す＝もう回答待ちではない。route_result(move_awaiting) が刻んだ
# awaiting_issue タグを頼りに、AWAITING_DIR に残った当該 issue のタスク md（再投函済みで
# 誰にも読まれない残骸）を刈る。マーカーを消す全パス（redo / plan2impl / 返信再投函）で呼ぶ。
purge_awaiting() {
  local n="$1" f
  for f in "$AWAITING_DIR"/*.md; do
    [ -f "$f" ] || continue
    grep -qxF "awaiting_issue: $n" "$f" && rm -f "$f"
  done
}

# ── redo パス: 人間が 'loop:redo' を付けた issue を「もう一度やって」として再着手可能にする ──
#   ファイルを触らず GitHub のラベル1つ（iOS でもタップ可）で再投入できる。人間ゲートは維持。
#   既処理マーカー(.seen/.awaiting/.blocked)を消し、loop:redo を外して loop を付け直す
#   → 直後の本処理パスが通常どおり enqueue する（冪等: 1回で消費される）。
gh issue list -R "$target_slug" --label "loop:redo" --state open --json number --limit "$POLL_GH_LIMIT" 2>/dev/null \
| jq -r '.[].number' 2>/dev/null | while read -r n; do
    [ -n "$n" ] || continue
    # 処理中/キュー内に同じ issue のタスクがあれば redo を今回は見送る（ラベルは残す＝次周回で
    # 再評価）。ここで state を消して再 enqueue すると、進行中の分と合わせて同一 issue のタスクが
    # 2本並行し、別ブランチ・PR が2つできてしまう（inprogress 中も md は queue に残るので queue を見る）。
    if grep -lE "issue #$n([^0-9]|\$)" "$QUEUE_DIR"/*.md >/dev/null 2>&1; then
      log redo "issue #$n: 処理中/キュー内のタスクがあるため redo を保留（次周回で再評価）"
      continue
    fi
    rm -f "$STATE_DIR/issue-$n.seen" "$STATE_DIR/issue-$n.awaiting" "$STATE_DIR/issue-$n.blocked"
    purge_awaiting "$n"
    gh issue edit "$n" -R "$target_slug" --remove-label "loop:redo" --add-label "loop" >/dev/null 2>&1 || true
    log redo "issue #$n: loop:redo により再着手可能化（state クリア）"
done

# ── 1 issue のトリアージ（implement / plan 共通） ────────────────────
#   mode=implement … 'loop' ラベル。曖昧でなければ実装〜PR まで自走する（従来の挙動）。
#   mode=plan      … 'loop:plan' ラベル。コードに触れず issue にコメントで議論するだけ。
#     awaiting/seen 判定は両モード共通（議論の往復も needs_info と同じ配管を再利用）。
triage_issue() {
  local row="$1" mode="$2"
  local num title labels seen awaiting fromplan blocked long_line unmet replied
  num=$(jq -r '.number' <<<"$row")
  title=$(jq -r '.title' <<<"$row")
  labels=$(jq -r '[.labels[].name] | join(",")' <<<"$row")   # loop:long / loop:plan 等の判定に使う
  seen="$STATE_DIR/issue-$num.seen"
  awaiting="$STATE_DIR/issue-$num.awaiting"
  fromplan="$STATE_DIR/issue-$num.fromplan"

  if [ "$mode" = "implement" ]; then
    # loop:plan が付いている間はプランモードが所有＝実装しない（plan パスが処理する）。
    case ",$labels," in *",loop:plan,"*) return;; esac
    # プランモードからの昇格: 人間が loop:plan を外し loop だけにした＝「議論は済んだ、実装して」。
    # プラン中の待機 state（awaiting/seen）を捨てて、最新の議論を踏まえた新規実装として走らせる
    # （awaiting マーカーが最新コメントでも待たない＝ラベル切替そのものが実装の合図）。
    if [ -f "$fromplan" ]; then
      rm -f "$fromplan" "$awaiting" "$seen"
      purge_awaiting "$num"
      log plan2impl "issue #$num: loop:plan 解除 → 実装フローへ昇格（プラン state クリア）"
    fi
  fi

  # ── awaiting / seen 判定（両モード共通） ──────────────────────
  if [ -f "$awaiting" ]; then
    # 回答待ち。bot の質問/プラン応答（最後のマーカーコメント）より**後**に、信頼できる
    # author（TRUSTED_ASSOCIATIONS＝リポジトリに招待された人間）の返信が付いたときだけ再投入する。
    # 第三者や別 bot（dependabot 等）のコメントは「再投入もしない・待機の邪魔もしない」＝無視。
    # 公開 repo では誰でもコメントできるため、「最新コメントがマーカー以外なら回答」では
    # 第三者が bot を再駆動でき、その内容が要件として混入してしまう。
    # 取得失敗（ネットワーク等）は 0 扱い＝待機継続（fail-closed）。
    replied=$(gh issue view "$num" -R "$target_slug" --json comments 2>/dev/null \
      | jq -r --arg m "$AWAIT_MARKER" --argjson t "$(trusted_assoc_jq)" '
          .comments
          | ((map((.body // "") | contains($m)) | rindex(true)) // -1) as $i
          | .[$i+1:]
          | map(select((.authorAssociation // "") as $a | $t | index($a)))
          | length' 2>/dev/null || echo 0)
    [ "${replied:-0}" -gt 0 ] || return                # 信頼できる返信なし＝待機継続
    rm -f "$awaiting"                                  # 人間が返信した → 再投入へ
    purge_awaiting "$num"                              # 再投函済みの残骸 md を刈る
  elif [ -f "$seen" ]; then
    return                                # 既処理(done/処理中)。従来どおり再投函しない
  fi

  if [ "$mode" = "plan" ]; then
    # プランモード: コードに触れず、方針/設計を検討して issue にコメントで応答するタスクを投函。
    # 議論はゲートしない＝依存(blocked_by)/loop:long は適用しない。
    LOOP_SOURCE=issue ./bin/enqueue.sh "issue #$num (plan): $title" - <<EOF
GitHub issue #$num「$title」について、**コードは一切変更せず**、方針・設計を検討して issue にコメントで応答してください。
mode: plan
loop-task の「プランモード」に従うこと（worktree・実装・PR は作らない＝読むのとコメントのみ）。
issue 本文と全コメントを読み、最新の人間コメントに応答し、末尾に awaiting マーカーを付けて
loop-report --status plan で報告してください。
EOF
    : > "$seen"
    : > "$fromplan"   # 後で loop に切替えられた時に「プランからの昇格」を検知するためのマーカー
    log plan "issue #$num: プランモードで投函（コード変更なし・議論）"
    return
  fi

  # ── 以下 implement モード専用 ─────────────────────────────────
  # 新規 issue の settle（配線待ち猶予）は廃止。`loop` ラベルを「作成→依存配線が済んだ合図」
  # として最後に付ける運用（自動: loop-decompose/loop-issue、人間: 手起票も同様）に統一したため、
  # ラベルが見えた時点で依存は揃っている＝隙間レースは原理的に起きない。

  # ── 依存（blocked by）チェック ──────────────────────────────
  # GitHub ネイティブの issue dependencies を REST で参照し、ブロック元が
  # 未完了なら着手しない。未完了 = ブロック元が open、または closed でも not_planned。
  # ブロック中は seen を立てず return＝依存が解けた周回で自動的に再評価される。
  blocked="$STATE_DIR/issue-$num.blocked"
  unmet=$(gh api "repos/$target_slug/issues/$num/dependencies/blocked_by" \
          --jq '[.[] | select(.state=="open" or .state_reason=="not_planned")] | length' \
          2>/dev/null || true)
  [ -n "$unmet" ] || { log warn "blocked_by 取得失敗 issue #$num（依存無視で続行）"; unmet=0; }
  if [ "$unmet" -gt 0 ]; then
    if [ ! -f "$blocked" ]; then            # 通知はブロック開始時の1回だけ（毎周回鳴らさない）
      : > "$blocked"
      notify "⛔ blocked: issue #$num は未完了の依存 ${unmet} 件待ち${title:+「$title」} | $(issue_url "$num")"
      log blocked "issue #$num blocked by $unmet open/not-planned dep(s)"
    fi
    return
  fi
  rm -f "$blocked"                          # 依存解消 or 依存なし → ブロック解除

  # loop:long が付いていれば driver のチェックポイントを長め（TASK_TIMEOUT_LONG）にする。
  # （人間が「これは時間がかかる」とトリアージ済みの issue。task 本文に書いて driver が読む）
  long_line=""
  case ",$labels," in
    *",loop:long,"*) long_line="task_timeout: $TASK_TIMEOUT_LONG"
                     log long "issue #$num: loop:long → task_timeout=${TASK_TIMEOUT_LONG}s";;
  esac

  LOOP_SOURCE=issue ./bin/enqueue.sh "issue #$num: $title" - <<EOF
GitHub issue #$num「$title」に対応してください。
feature ブランチ loop/<id> で実装し、テストを通して PR を開いてください。
要件が曖昧で実装方針を確定できない場合は、実装せず issue にコメントで質問すること（loop-task 手順参照）。
$long_line
EOF
  : > "$seen"
}

# ── 実装モード（loop ラベル）─ 従来の主入力。曖昧でなければ実装〜PR まで自走 ──
gh issue list -R "$target_slug" --label loop --state open --json number,title,labels --limit "$POLL_GH_LIMIT" 2>/dev/null \
| jq -c '.[]' 2>/dev/null | while read -r row; do triage_issue "$row" implement; done

# ── プランモード（loop:plan ラベル）─ コードに触れず議論。loop 無しでも拾う ──
#   「issue を見に来て会話するが実装はしない」中間状態。実装したくなったら人間が
#   loop:plan を外して loop に付け替える（plan2impl で昇格）。
gh issue list -R "$target_slug" --label "loop:plan" --state open --json number,title,labels --limit "$POLL_GH_LIMIT" 2>/dev/null \
| jq -c '.[]' 2>/dev/null | while read -r row; do triage_issue "$row" plan; done
