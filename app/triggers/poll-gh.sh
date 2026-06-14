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

# ── redo パス: 人間が 'loop:redo' を付けた issue を「もう一度やって」として再着手可能にする ──
#   ファイルを触らず GitHub のラベル1つ（iOS でもタップ可）で再投入できる。人間ゲートは維持。
#   既処理マーカー(.seen/.awaiting/.blocked)を消し、loop:redo を外して loop を付け直す
#   → 直後の本処理パスが通常どおり enqueue する（冪等: 1回で消費される）。
gh issue list -R "$target_slug" --label "loop:redo" --state open --json number 2>/dev/null \
| jq -r '.[].number' 2>/dev/null | while read -r n; do
    [ -n "$n" ] || continue
    rm -f "$STATE_DIR/issue-$n.seen" "$STATE_DIR/issue-$n.awaiting" "$STATE_DIR/issue-$n.blocked"
    gh issue edit "$n" -R "$target_slug" --remove-label "loop:redo" --add-label "loop" >/dev/null 2>&1 || true
    log redo "issue #$n: loop:redo により再着手可能化（state クリア）"
done

gh issue list -R "$target_slug" --label loop --state open --json number,title,createdAt,labels 2>/dev/null \
| jq -c '.[]' 2>/dev/null | while read -r row; do
    num=$(jq -r '.number' <<<"$row")
    title=$(jq -r '.title' <<<"$row")
    created=$(jq -r '.createdAt // ""' <<<"$row")
    labels=$(jq -r '[.labels[].name] | join(",")' <<<"$row")   # loop:long 等の属性ラベル判定に使う
    seen="$STATE_DIR/issue-$num.seen"
    awaiting="$STATE_DIR/issue-$num.awaiting"

    if [ -f "$awaiting" ]; then
      # 回答待ち。最新コメントが bot の質問マーカーのままなら、まだ未回答＝待機継続。
      last=$(gh issue view "$num" -R "$target_slug" --json comments \
             -q '.comments[-1].body // ""' 2>/dev/null || echo "")
      case "$last" in *"$AWAIT_MARKER"*) continue;; esac   # bot の質問が最新＝未回答
      rm -f "$awaiting"                                    # 人間が返信した → 再投入へ
    elif [ -f "$seen" ]; then
      continue                              # 既処理(done/処理中)。従来どおり再投函しない
    fi

    # ── 新規 issue の猶予（settle）─────────────────────────────
    # 作成直後の issue は依存(blocked_by)などの配線が未完のことがある。作成→ポーリング→
    # 依存登録の隙間に走ると未ブロックのまま着手してしまうため、ISSUE_SETTLE_SECS 以内の
    # issue は seen を立てず1周見送る（次 poll で配線完了後に再評価される）。
    # 既に seen/awaiting を抜けてきた＝初回評価対象のみが対象。日付解釈失敗時は従来どおり続行（fail-open）。
    if [ -n "$created" ]; then
      created_epoch=$(date -d "$created" +%s 2>/dev/null || echo 0)
      if [ "$created_epoch" -gt 0 ]; then
        age=$(( $(date +%s) - created_epoch ))
        if [ "$age" -lt "$ISSUE_SETTLE_SECS" ]; then
          log settle "issue #$num は作成 ${age}s（< ${ISSUE_SETTLE_SECS}s）＝配線待ちで今周は見送り"
          continue
        fi
      fi
    fi

    # ── 依存（blocked by）チェック ──────────────────────────────
    # GitHub ネイティブの issue dependencies を REST で参照し、ブロック元が
    # 未完了なら着手しない。未完了 = ブロック元が open、または closed でも not_planned。
    # ブロック中は seen を立てず continue＝依存が解けた周回で自動的に再評価される。
    blocked="$STATE_DIR/issue-$num.blocked"
    unmet=$(gh api "repos/$target_slug/issues/$num/dependencies/blocked_by" \
            --jq '[.[] | select(.state=="open" or .state_reason=="not_planned")] | length' \
            2>/dev/null || true)
    [ -n "$unmet" ] || { log warn "blocked_by 取得失敗 issue #$num（依存無視で続行）"; unmet=0; }
    if [ "$unmet" -gt 0 ]; then
      if [ ! -f "$blocked" ]; then          # 通知はブロック開始時の1回だけ（毎周回鳴らさない）
        : > "$blocked"
        notify "⛔ blocked: issue #$num は未完了の依存 ${unmet} 件待ち${title:+「$title」} | $(issue_url "$num")"
        log blocked "issue #$num blocked by $unmet open/not-planned dep(s)"
      fi
      continue
    fi
    rm -f "$blocked"                         # 依存解消 or 依存なし → ブロック解除

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
done
