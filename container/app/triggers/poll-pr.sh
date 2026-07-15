#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# poll-pr ── ループが開いた PR(loop/*) に「人間の changes-requested レビュー」が
#   付いたら、その指摘に対応する修正タスクを投函する（LLM を呼ばない＝無課金）。
#   入力源は issue/PR に限定。これは PR 側のトリガ（poll-gh.sh が issue 側）。
#
#   GitHub App 運用前提: bot は別 author になるので、レビューを `user.type=="User"`
#   （＝人間）で判定する。issue の needs_info と違い隠しマーカーは不要。
#
#   冪等: 対応済みのレビュー id を state/pr-<N>.review に記録し、同じ指摘は再投函しない。
#     人間が新しい changes-requested を出す（＝新しい review id）と再投函される。
# ─────────────────────────────────────────────────────────────
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
source ./config.sh
source ./bin/lib.sh
mkdir -p "$STATE_DIR"

command -v gh >/dev/null 2>&1 || { echo "gh not installed" >&2; exit 1; }
slug=$(target_slug)
[ -n "$slug" ] || { echo "ERROR: 対象 repo の slug を解決できません" >&2; exit 1; }

gh pr list -R "$slug" --state open --json number,headRefName,url --limit 50 2>/dev/null \
| jq -c '.[]' 2>/dev/null | while read -r row; do
    num=$(jq -r '.number' <<<"$row")
    branch=$(jq -r '.headRefName' <<<"$row")
    url=$(jq -r '.url' <<<"$row")
    case "$branch" in loop/*) ;; *) continue;; esac     # ループが作った PR のみ対象

    # 人間かつ信頼できる author（TRUSTED_ASSOCIATIONS＝リポジトリに招待された人間）の
    # 最新 changes-requested レビュー id を取る。
    #   ※bot 自身のレビューは無いが、type 判定なら App の login 表記揺れにも影響されない。
    #   ※type だけだと「人間なら誰でも」＝公開 repo では第三者のレビュー本文を指示として
    #     実行してしまうため、author_association で招待済みの人間に限定する。
    rid=$(gh api "repos/$slug/pulls/$num/reviews" 2>/dev/null \
          | jq -r --argjson t "$(trusted_assoc_jq)" '
              [.[] | select(.state=="CHANGES_REQUESTED" and .user.type=="User"
                            and ((.author_association // "") as $a | $t | index($a)))]
              | sort_by(.submitted_at) | last | .id // empty' 2>/dev/null || true)
    [ -n "$rid" ] || continue                            # 人間の changes-requested 無し

    marker="$STATE_DIR/pr-$num.review"
    [ -f "$marker" ] && [ "$(cat "$marker" 2>/dev/null)" = "$rid" ] && continue  # 対応済みの指摘

    LOOP_SOURCE=pr-review ./bin/enqueue.sh "PR #$num review fixes" - <<EOF
# PR #$num のレビュー指摘に対応

PR #$num（ブランチ \`$branch\`）に**人間から changes-requested レビュー**が付きました。
指摘に対応し、**新規 PR を作らず既存ブランチ \`$branch\` に push** して PR を更新してください。
（これは PR レビュー往復タスク。loop-task の「PR レビュー指摘への対応モード」に従うこと）

pr_number: $num
pr_branch: $branch
pr_url: $url

指摘の取得:
  gh pr view $num -R $slug --comments
  gh api repos/$slug/pulls/$num/reviews --jq '.[] | select(.state=="CHANGES_REQUESTED")'
  gh api repos/$slug/pulls/$num/comments    # インライン指摘(path/line/body)
EOF
    echo "$rid" > "$marker"
done
