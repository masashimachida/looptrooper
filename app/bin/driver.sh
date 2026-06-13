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
mkdir -p "$QUEUE_DIR" "$PROCESSED_DIR" "$BLOCKED_DIR" "$RESULTS_DIR" "$DONE_DIR" "$LOGS_DIR" "$STATE_DIR" "$AWAITING_DIR" "$RUNNING_DIR"

# 起動時復旧: in-progress のまま残ったタスク＝中断された → queue に残して再処理
recover_inflight() {
  local f id
  for f in "$STATE_DIR"/*.inprogress; do
    [ -e "$f" ] || continue
    id=$(basename "$f" .inprogress)
    log recover "interrupted task requeued: $id"
    rm -f "$f" "$RESULTS_DIR/$id.json"
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

route_result() {
  local id="$1" status pr issue iurl
  status=$(result_field "$id" status)
  # 紐づく issue を解決（result の issue を優先、無ければタスク本文から）→ 通知に URL を添える。
  issue=$(result_field "$id" issue); [ -n "$issue" ] || issue=$(task_issue "$id")
  iurl=$(issue_url "$issue")
  case "$status" in
    done)
      pr=$(result_field "$id" pr_url)
      notify "✅ レビュー待ちの PR ができました: ${pr:-<URLなし>} ($id)${iurl:+ | issue: $iurl}"
      log done "$id -> $pr"
      mv "$QUEUE_DIR/$id.md" "$PROCESSED_DIR/" 2>/dev/null || true
      ;;
    skipped)
      log skip "nothing to do: $id${iurl:+ ($iurl)}"   # 空振り。通知せずログのみ（安く静かに保つ）
      mv "$QUEUE_DIR/$id.md" "$PROCESSED_DIR/" 2>/dev/null || true
      ;;
    needs_info)
      # 曖昧で issue に質問を投稿済み。人間の回答待ち＝再投函しない。
      # issue-<N>.awaiting を立て、poll-gh が回答検知で再投入する。
      [ -n "$issue" ] && : > "$STATE_DIR/issue-$issue.awaiting"
      notify "❓ 確認待ち: issue #${issue:-?} に質問を投稿しました ($id)${iurl:+ | $iurl}"
      log needs_info "$id -> issue #${issue:-?} (awaiting human reply)"
      mv "$QUEUE_DIR/$id.md" "$AWAITING_DIR/" 2>/dev/null || true
      ;;
    failed|blocked)
      notify "⚠️ 要対応 [$status]: $id${iurl:+ | issue: $iurl}"
      comment_outcome "$id" "$status" "$issue"   # 結末を issue に残す（分離環境でも読める）
      mv "$QUEUE_DIR/$id.md" "$BLOCKED_DIR/" 2>/dev/null || true
      ;;
    *)
      notify "⚠️ result が壊れている/欠落: $id（要レビュー扱い）${iurl:+ | issue: $iurl}"
      comment_outcome "$id" "needs-review" "$issue" "result が壊れている/欠落（loop-report が正常に書けていない可能性）。"
      mv "$QUEUE_DIR/$id.md" "$BLOCKED_DIR/" 2>/dev/null || true
      ;;
  esac
}

process_one() {
  local id="$1" iurl issue
  issue=$(task_issue "$id")
  iurl=$(issue_url "$issue")   # 着手/タイムアウト/詰まり通知に issue URL を添える
  rm -f "$RESULTS_DIR/$id.json"
  : > "$STATE_DIR/$id.inprogress"

  is_idle || log warn "pane not idle before injecting $id"
  inject "次のタスクを処理して: $QUEUE_DIR/$id.md"

  # トリアージ猶予: この間に skipped(や即 done) で結果が来たら着手通知を出さずにルーティング。
  # 空振りに 🚀 を飛ばさない＝「skip しなかった時だけ着手通知」を満たす。
  if wait_result "$id" "$TRIAGE_GRACE"; then
    rm -f "$STATE_DIR/$id.inprogress"; route_result "$id"; return
  fi

  # 猶予を超えてまだ処理中＝実作業中。ここで初めて着手を通知する。
  notify "🚀 タスク着手: $id${iurl:+ | issue: $iurl}"

  if wait_result "$id" "$(( TASK_TIMEOUT > TRIAGE_GRACE ? TASK_TIMEOUT - TRIAGE_GRACE : TASK_TIMEOUT ))"; then
    rm -f "$STATE_DIR/$id.inprogress"; route_result "$id"; return
  fi

  # タイムアウト ── 詰まりを分類して、盲目に次を投げない。
  # working の間は見限らない: システム側はタイムアウトでも Claude のセッションは
  # まだそのタスクを走らせている。延長を繰り返し、本当に詰まれば（hung/crashed/
  # modal に転じれば）下の分岐で処理する。延長上限を超えてもなお working なら、
  # 再注入による混線を避けるため detach し（RUNNING_DIR へ退避）、完走時は
  # reap_detached が遅延ルーティングする。
  local extends=0
  while true; do
    case "$(classify_stuck)" in
      working)
        if [ "$extends" -ge "$TASK_EXTEND_MAX" ]; then
          # 見限らず detach: セッションは走り続ける。完走したら reaper が拾う。
          log slow "still working after $extends extensions; detaching: $id"
          notify "⏳ 実行継続中につき detach: $id${iurl:+ | issue: $iurl}（完走したら reaper が拾います）"
          mv "$QUEUE_DIR/$id.md" "$RUNNING_DIR/" 2>/dev/null || true
          break
        fi
        extends=$((extends+1))
        log slow "still working, extend wait ($extends/$TASK_EXTEND_MAX): $id"
        if wait_result "$id" "$TASK_TIMEOUT"; then
          rm -f "$STATE_DIR/$id.inprogress"; route_result "$id"; return
        fi
        continue   # まだ working か再判定。working なら再延長、転べば該当分岐へ。
        ;;
      limit)
        sleep_until_reset
        rm -f "$STATE_DIR/$id.inprogress"; return   # タスクは queue に残し、次周回で再試行
        ;;
      modal)
        tmux send-keys -t "$TMUX_SESSION" Escape 2>/dev/null || true
        notify "⚠️ 権限モーダルで停止: $id${iurl:+ | issue: $iurl}"
        comment_outcome "$id" "blocked" "$issue" "許可モーダルで停止（権限要求）。loop の settings 許可リスト（許可されていない操作）を確認のこと。"
        mv "$QUEUE_DIR/$id.md" "$BLOCKED_DIR/" 2>/dev/null || true
        break
        ;;
      crashed|hung)
        tmux send-keys -t "$TMUX_SESSION" Escape 2>/dev/null || true
        notify "⚠️ セッションが停止/クラッシュ: $id（keeper が再起動し再キューします）${iurl:+ | issue: $iurl}"
        # タスクは queue に残す＝再処理。keeper が claude を立て直す。
        break
        ;;
    esac
  done
  rm -f "$STATE_DIR/$id.inprogress"
}

# 遅延回収（reaper）: システム側はタイムアウトしたが Claude が走り続け、後から
# result を書いたタスクを拾ってルーティングする。process_one が見ている
# （queue 待ち / .inprogress）ものには触らない＝二重処理を避ける。
reap_detached() {
  local f id
  for f in "$RESULTS_DIR"/*.json; do
    [ -e "$f" ] || continue
    id=$(basename "$f" .json)
    [ -f "$STATE_DIR/$id.inprogress" ] && continue   # アクティブ処理中
    [ -f "$QUEUE_DIR/$id.md" ] && continue            # キュー待ち（次に process_one が拾う）
    [ -f "$RUNNING_DIR/$id.md" ] || continue          # detach 中のものだけが対象
    log reap "detached task finished, routing late result: $id"
    mv "$RUNNING_DIR/$id.md" "$QUEUE_DIR/$id.md" 2>/dev/null || true  # route_result は QUEUE_DIR から移動する
    route_result "$id"
  done
}

log info "driver started (loop_dir=$LOOP_DIR session=$TMUX_SESSION)"
recover_inflight
while true; do
  reap_detached   # detach して走り続けたタスクが完走していれば先に拾う
  task=$(ls -1 "$QUEUE_DIR" 2>/dev/null | grep '\.md$' | head -1)
  if [ -z "${task:-}" ]; then sleep "$POLL_INTERVAL"; continue; fi  # 仕事ゼロ＝無課金
  process_one "${task%.md}"
done
