#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# 単一常駐ドライバ(A)。pane を触る唯一のプロセス。
#   キュー消化 → 固定フレーズ注入 → result(sentinel) 待ち
#   → タイムアウトは classify_stuck で分類 → ルーティング
# ※雛形（未テスト）。
# ─────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
source ./config.sh
source ./bin/lib.sh
mkdir -p "$QUEUE_DIR" "$PROCESSED_DIR" "$BLOCKED_DIR" "$RESULTS_DIR" "$DONE_DIR" "$LOGS_DIR" "$STATE_DIR" "$AWAITING_DIR"

# 起動時復旧: in-progress のまま残ったタスク＝中断された → queue に残して再処理
recover_inflight() {
  local f id
  for f in "$STATE_DIR"/*.inprogress; do
    [ -e "$f" ] || continue
    id=$(basename "$f" .inprogress)
    log recover "interrupted task requeued: $id"
    rm -f "$f" "$RESULTS_DIR/$id.json"
    # worktree/ブランチ残骸の掃除は process_one が注入前に必ず行う（requeue 安全性を
    # 1点に集約＝crash/hung/limit/中断無応答/driver 再起動の全再キュー経路をそこでカバー）。
  done
}

# result file から status を読む（簡易パーサ。jq があれば jq 推奨）
result_field() {
  local id="$1" key="$2"
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg k "$key" '.[$k] // ""' "$RESULTS_DIR/$id.json" 2>/dev/null
  else
    grep -o "\"$key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$RESULTS_DIR/$id.json" \
      | head -1 | sed 's/.*"\([^"]*\)"$/\1/'
  fi
}

# 失敗/blocked の「結末」を issue コメントとして残す。
# 狙い: ループ基盤と起票セッションが別マシンに分離していても、プランナーは
#   gh issue view <N> --comments で「なぜ失敗したか・検証はどこで落ちたか・
#   次の一手」を読める。GitHub を唯一の共有面に使う＝追加インフラ不要、生ログは
#   出さない（result の人間可読サマリと検証フラグだけ＝漏えい面の最小化）。
# 隠しマーカー <!-- loop:outcome --> で識別。result json が無い詰まり系（modal/
# crashed 等）は第4引数 override で理由を直接渡す。
comment_outcome() {
  local id="$1" status="$2" issue="$3" override="${4:-}" slug summary reason verify next body
  slug=$(target_slug)
  [ -n "$issue" ] && [ -n "$slug" ] || return 0   # 紐づく issue / slug が無ければ何もしない
  if [ -f "$RESULTS_DIR/$id.json" ]; then
    summary=$(result_field "$id" summary)
    reason=$(result_field "$id" blocked_reason)
    next=$(result_field "$id" next)
    if command -v jq >/dev/null 2>&1; then
      verify=$(jq -r '.verification // {} | to_entries | map("\(.key)=\(.value)") | join(" ")' \
               "$RESULTS_DIR/$id.json" 2>/dev/null)
    fi
  fi
  [ -n "$override" ] && reason="$override"
  body=$(cat <<MD
🤖 loop-bot: このタスクは **${status}** で終了しました（task \`${id}\`）。

- 結果: ${summary:-（要約なし）}
- 理由: ${reason:-（理由なし）}
- 検証: ${verify:-（なし）}
- 次の一手: ${next:-（なし）}

詳細な生ログはループ基盤側の \`.loop/logs\` にあります（このコメントは結末サマリ）。再着手するなら issue に \`loop:redo\` ラベルを付けてください。
<!-- loop:outcome -->
MD
)
  gh issue comment "$issue" -R "$slug" --body "$body" >/dev/null 2>&1 \
    && log outcome "posted outcome to issue #$issue ($id/$status)" \
    || log warn "failed to post outcome comment to issue #$issue ($id)"
}

# awaiting 行きのタスク md を退避する際、解決済み issue 番号を本文末尾に刻んでから移す。
# poll-gh が再投函（＝もう awaiting でない）時に、この刻印を頼りに残骸 md を確実に刈れるようにする
# ＝ファイル→issue を一意に辿る唯一の手掛かり（pr レビュー往復のように本文へ issue 番号が出ない
# タスクでも、route_result は result から issue を解決済みなのでここで刻める）。
move_awaiting() {
  local id="$1" issue="$2"
  [ -n "$issue" ] && printf '\nawaiting_issue: %s\n' "$issue" >> "$QUEUE_DIR/$id.md" 2>/dev/null
  mv "$QUEUE_DIR/$id.md" "$AWAITING_DIR/" 2>/dev/null || true
}

route_result() {
  local id="$1" status pr issue iurl title
  status=$(result_field "$id" status)
  # 紐づく issue を解決（result の issue を優先、無ければタスク本文から）→ 通知に URL を添える。
  issue=$(result_field "$id" issue); [ -n "$issue" ] || issue=$(task_issue "$id")
  iurl=$(issue_url "$issue")
  title=$(task_title "$id")   # 通知に issue タイトルを添える
  case "$status" in
    done)
      pr=$(result_field "$id" pr_url)
      if grep -q '^spec_phase:' "$QUEUE_DIR/$id.md" 2>/dev/null; then
        # 仕様分解タスク＝PR ではなく issue 群を起票して完了（見えるが止めない）。
        local sm; sm=$(result_field "$id" summary)
        notify "🧩 仕様フェーズを分解しました${title:+: $title}: ${sm:-issue を起票} ($id)"
        log done "$id -> decompose: ${sm:-(no summary)}"
      else
        notify "✅ レビュー待ちの PR ができました${title:+: $title}: ${pr:-<URLなし>} ($id)${iurl:+ | issue: $iurl}"
        log done "$id -> $pr"
      fi
      clean_stale_worktree "$id"   # PR は remote に push 済み＝ローカル worktree/ブランチ残骸を掃除（リーク防止）
      mv "$QUEUE_DIR/$id.md" "$PROCESSED_DIR/" 2>/dev/null || true
      ;;
    skipped)
      log skip "nothing to do: $id${iurl:+ ($iurl)}"   # 空振り。通知せずログのみ（安く静かに保つ）
      clean_stale_worktree "$id"
      mv "$QUEUE_DIR/$id.md" "$PROCESSED_DIR/" 2>/dev/null || true
      ;;
    needs_info)
      # 曖昧で issue に質問を投稿済み。人間の回答待ち＝再投函しない。
      # issue-<N>.awaiting を立て、poll-gh が回答検知で再投入する。
      [ -n "$issue" ] && : > "$STATE_DIR/issue-$issue.awaiting"
      notify "❓ 確認待ち: issue #${issue:-?}${title:+「$title」} に質問を投稿しました ($id)${iurl:+ | $iurl}"
      log needs_info "$id -> issue #${issue:-?} (awaiting human reply)"
      move_awaiting "$id" "$issue"
      ;;
    plan)
      # プランモード: コードに触れず issue にコメントで方針/設計を応答済み。人間の返信待ち（議論継続）。
      # needs_info と同じく .awaiting で待機＝人間が返信すれば poll-gh が再投函しまた応答する。
      # 実装に移すときは人間が loop:plan を外して loop に付け替える（poll-gh が plan2impl で昇格）。
      [ -n "$issue" ] && : > "$STATE_DIR/issue-$issue.awaiting"
      notify "💬 プラン応答: issue #${issue:-?}${title:+「$title」} にコメントしました ($id) — 実装するなら loop:plan を外して loop に${iurl:+ | $iurl}"
      log plan "$id -> issue #${issue:-?} (plan reply, awaiting human)"
      move_awaiting "$id" "$issue"
      ;;
    timeout)
      # 規定時間超過で bot が中断・自己申告済み（issue に経過/理由/方針をコメント済み）。
      # 人間トリアージ待ち＝needs_info と同じく .awaiting で待機。人間は redo / タスク分割 / loop:long で再開する。
      [ -n "$issue" ] && : > "$STATE_DIR/issue-$issue.awaiting"
      notify "⏸ 時間超過で中断: issue #${issue:-?}${title:+「$title」} に経過を報告しました ($id) — redo / 分割 / loop:long で再開${iurl:+ | $iurl}"
      log timeout "$id -> issue #${issue:-?} (checkpoint, awaiting human triage)"
      clean_stale_worktree "$id"   # 中断時の worktree/ブランチ残骸を掃除（move_awaiting で md が queue を離れる前に＝task_field が pr_branch を読める）
      move_awaiting "$id" "$issue"
      ;;
    failed|blocked)
      notify "⚠️ 要対応 [$status]${title:+: $title}: $id${iurl:+ | issue: $iurl}"
      comment_outcome "$id" "$status" "$issue"   # 結末を issue に残す（分離環境でも読める）
      clean_stale_worktree "$id"   # 終端（人間トリアージへ）＝残骸を掃除。redo 時は新しい worktree でやり直す設計
      mv "$QUEUE_DIR/$id.md" "$BLOCKED_DIR/" 2>/dev/null || true
      ;;
    *)
      notify "⚠️ result が壊れている/欠落${title:+: $title}: $id（要レビュー扱い）${iurl:+ | issue: $iurl}"
      comment_outcome "$id" "needs-review" "$issue" "result が壊れている/欠落（loop-report が正常に書けていない可能性）。"
      clean_stale_worktree "$id"
      mv "$QUEUE_DIR/$id.md" "$BLOCKED_DIR/" 2>/dev/null || true
      ;;
  esac
}

process_one() {
  local id="$1" iurl issue tmo title
  issue=$(task_issue "$id")
  iurl=$(issue_url "$issue")   # 着手/タイムアウト/詰まり通知に issue URL を添える
  title=$(task_title "$id")    # 通知に issue タイトルを添える
  tmo=$(task_timeout "$id")    # チェックポイントまでの待ち秒。loop:long なら長め（poll-gh が task に書く）
  rm -f "$RESULTS_DIR/$id.json"
  : > "$STATE_DIR/$id.inprogress"

  # 注入前に前回試行の worktree/ブランチ残骸を必ず掃除する（requeue 安全性の集約点）。
  #   同一 id が再キューされる全経路（crash/hung/limit/中断無応答/driver 再起動）で、前回
  #   作った `loop/<id>`（PR レビューは pr_branch）が残っていると SKILL の `git worktree add`
  #   が「already exists／already checked out」で決定的に失敗し、LLM が復旧にもがいて時間を
  #   溶かし→また殺される無限クラッシュループに陥る（cf0099b で踏んだ経路）。ここで構造的に
  #   断つ＝LLM の対処運に依存しない。新規タスクなら対象が無く no-op。
  clean_stale_worktree "$id"

  # 前タスクの会話文脈を捨ててから着手（コスト最適化。知識は .loop/memory 側にあるので安全）。
  #   前タスクは既に result を出して完了済み＝締め出力は使い捨て。clear_context が**待たず
  #   Escape で割って**確実に /clear を着地させ（内部で idle 化＋着地検証＋撃ち直し）、pane を
  #   プロンプトに戻す。旧来の「wait_idle で30s 待ってから clear」は締め出力が長いと待ち切れず
  #   /clear を生成中に撃ち込み飲まれていた（＝clear が効かない主因）ので廃止した。
  if [ "${CLEAR_BETWEEN_TASKS:-true}" = true ]; then
    clear_context || true
  else
    # clear 無効時は文脈を消さないので、せめて idle を待ってから注入する（従来挙動）。
    wait_idle "$CLEAR_IDLE_WAIT" || log warn "pane not idle within ${CLEAR_IDLE_WAIT}s before injecting $id"
  fi
  inject "次のタスクを処理して: $QUEUE_DIR/$id.md"

  # トリアージ猶予: この間に skipped(や即 done) で結果が来たら着手通知を出さずにルーティング。
  # 空振りに 🚀 を飛ばさない＝「skip しなかった時だけ着手通知」を満たす。
  if wait_result "$id" "$TRIAGE_GRACE"; then
    rm -f "$STATE_DIR/$id.inprogress"; route_result "$id"; return
  fi

  # 猶予を超えてまだ処理中＝実作業中。ここで初めて着手を通知する。
  notify "🚀 タスク着手${title:+: $title}: $id${iurl:+ | issue: $iurl}"

  if wait_result "$id" "$(( tmo > TRIAGE_GRACE ? tmo - TRIAGE_GRACE : tmo ))"; then
    rm -f "$STATE_DIR/$id.inprogress"; route_result "$id"; return
  fi

  # チェックポイント ── 規定時間を超過。詰まりを分類して扱いを変える。
  # 「10分(既定20分)で終わらないものは大抵終わらない」経験則に基づき、working でも
  # 延長して数時間溶かさず、中断して「経過・理由・方針」を自己申告させる＝人間トリアージへ。
  # 外から「遅いだけ」か「堂々巡り」かは判別できないので、本人(Claude)に申告させる。
  case "$(classify_stuck)" in
    limit)
      sleep_until_reset
      rm -f "$STATE_DIR/$id.inprogress"; return   # タスクは queue に残し、次周回で再試行
      ;;
    modal)
      tmux send-keys -t "$TMUX_SESSION" Escape 2>/dev/null || true
      notify "⚠️ 権限モーダルで停止${title:+: $title}: $id${iurl:+ | issue: $iurl}"
      comment_outcome "$id" "blocked" "$issue" "許可モーダルで停止（権限要求）。loop の settings 許可リスト（許可されていない操作）を確認のこと。"
      clean_stale_worktree "$id"   # 終端（blocked）＝worktree/ブランチ残骸を掃除（md が queue を離れる前に）
      mv "$QUEUE_DIR/$id.md" "$BLOCKED_DIR/" 2>/dev/null || true
      ;;
    working)
      # 規定時間超過 & まだ working。中断して自己申告を求める（延長しない）。
      log slow "checkpoint: timed out (${tmo}s) while working; interrupting for self-report: $id"
      tmux send-keys -t "$TMUX_SESSION" Escape 2>/dev/null || true   # 生成を中断してプロンプトへ戻す
      sleep 1
      inject "⏸ 規定時間（${tmo}秒）を超過しました。新たな実装はせず作業を中断し、SKILL の「中断報告モード」に従って issue #${issue:-?} に【ここまでの経過 / なぜ終わらないか / 今後の方針】をコメントし、loop-report --task $id --status timeout${issue:+ --issue $issue} で報告してください。"
      if wait_result "$id" "$CHECKPOINT_GRACE"; then
        rm -f "$STATE_DIR/$id.inprogress"; route_result "$id"; return   # timeout → awaiting（人間トリアージ）
      fi
      # 中断指示にも応答せず自己申告も来ない＝応答不能。crashed 扱いで再キュー（keeper が claude を立て直す）。
      tmux send-keys -t "$TMUX_SESSION" Escape 2>/dev/null || true
      notify "⚠️ 中断報告も無応答${title:+: $title}: $id（応答不能とみなし再キュー）${iurl:+ | issue: $iurl}"
      ;;
    crashed|hung)
      tmux send-keys -t "$TMUX_SESSION" Escape 2>/dev/null || true
      notify "⚠️ セッションが停止/クラッシュ${title:+: $title}: $id（keeper が再起動し再キューします）${iurl:+ | issue: $iurl}"
      # タスクは queue に残す＝再処理。keeper が claude を立て直す。
      ;;
  esac
  rm -f "$STATE_DIR/$id.inprogress"
}

log info "driver started (loop_dir=$LOOP_DIR session=$TMUX_SESSION)"
recover_inflight
while true; do
  task=$(ls -1 "$QUEUE_DIR" 2>/dev/null | grep '\.md$' | head -1)
  if [ -z "${task:-}" ]; then sleep "$POLL_INTERVAL"; continue; fi  # 仕事ゼロ＝無課金
  process_one "${task%.md}"
  run_between_tasks   # 設定された後始末フックを境界で必ず実行（成否/timeout/crash 問わず。中身は config 側）
  reap_task_procs     # claude が残した子孫プロセス（dev サーバ等）を境界で刈る（timeout で居座るのを断つ）
done
