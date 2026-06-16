#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# poll-ci ── main の GitHub Actions の結果を観測し、失敗していたら issue を自動起票する。LLM を呼ばない。
#   重いテスト（e2e 等）を自前 dind で再現するのをやめ、「マージを実際にゲートしてる正規環境」=
#   CI の結果をそのまま受け取る。サンドボックス由来の偽陽性が出ず、計算ゼロ・poll-outcome と同型の継続監視。
#   ガード:
#     ・CI_WORKFLOW が空なら何もしない（＝既定オフ。使うプロジェクトだけ .env で対象ワークフローを指定）
#     ・対象ブランチ（既定 main）の「最新の完了 run」だけを見る＝現在の main 健全性
#     ・run id ごとのマーカーで同じ失敗を再起票しない／隠しマーカー付き open issue があれば積み増さない
#   生ログは貼らない（GitHub の run にある＝漏えい面の最小化）。run への URL と失敗ジョブ名だけ添える。
#   ラベルは CI_ISSUE_LABEL（既定 loop:proposed＝人間承認後に着手）。
# ─────────────────────────────────────────────────────────────
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
source ./config.sh
source ./bin/lib.sh
mkdir -p "$STATE_DIR"

# ── 対象ワークフロー未指定なら無効（このプロジェクトでは使わない）──
[ -n "${CI_WORKFLOW:-}" ] || exit 0

command -v gh >/dev/null 2>&1 || { echo "gh not installed" >&2; exit 1; }
slug=$(target_slug)
[ -n "$slug" ] || { echo "ERROR: 対象 repo の slug を解決できません" >&2; exit 1; }
branch="${CI_BRANCH:-$DEFAULT_BRANCH}"

# ── 対象ブランチの「最新の完了 run」を1件取る ──
run=$(gh run list -R "$slug" --workflow "$CI_WORKFLOW" --branch "$branch" --status completed --limit 1 \
        --json databaseId,conclusion,headSha,displayTitle,url,workflowName 2>/dev/null \
      | jq -c '.[0] // empty' 2>/dev/null || true)
[ -n "$run" ] || { log ci "完了済み run なし（workflow=$CI_WORKFLOW branch=$branch）"; exit 0; }

conclusion=$(jq -r '.conclusion' <<<"$run")
runid=$(jq -r '.databaseId' <<<"$run")

# ── 失敗系のときだけ起票（success/skipped 等は何もしない＝main は健全）──
case "$conclusion" in
  failure|timed_out|startup_failure) ;;
  *) log ci "最新 run #$runid = $conclusion（起票なし）"; exit 0;;
esac

# ── この run を既に起票済みなら蒸し返さない ──
marker="$STATE_DIR/ci-$runid.filed"
[ -f "$marker" ] && exit 0

# ── 未対応の起票が既にあれば積み増さない（持続失敗の量産防止）。この run は処理済みにする ──
existing=$(gh issue list -R "$slug" --state open --json number,body \
             --jq 'map(select(.body | contains("<!-- loop:ci-failure -->"))) | .[0].number' 2>/dev/null || echo "")
if [ -n "$existing" ] && [ "$existing" != "null" ]; then
  : > "$marker"
  log ci "main CI 失敗 (run #$runid) だが既存起票 #$existing あり＝再起票しない"
  exit 0
fi

# ── 失敗ジョブ名（生ログは持ち帰らない。原因特定は run のログを人間/Fixer が見る）──
failed_jobs=$(gh run view "$runid" -R "$slug" --json jobs \
                --jq '[.jobs[] | select(.conclusion=="failure") | .name] | join(", ")' 2>/dev/null || echo "")

sha=$(jq -r '.headSha' <<<"$run"); title=$(jq -r '.displayTitle' <<<"$run")
url=$(jq -r '.url' <<<"$run"); wf=$(jq -r '.workflowName' <<<"$run")

body=$(cat <<EOF
🤖 \`$branch\` の CI が失敗しました（poll-ci.sh / GitHub Actions）。

- ワークフロー: $wf
- 結論: **$conclusion**
- 失敗 run: $url
- コミット: \`${sha:0:12}\` — $title
- 失敗ジョブ: ${failed_jobs:-（取得できず）}

**対応**: 上記 run のログで原因を特定し、最小差分で修正してから PR を開いてください（closes でこの issue に紐付け）。flaky（実行ごとに揺れる）と判断した場合は、安定化（リトライ/待機/前提の固定化）も検討。

<!-- loop:ci-failure -->
EOF
)

if gh issue create -R "$slug" --title "🤖 [auto] $branch の CI 失敗: $wf" --body "$body" --label "$CI_ISSUE_LABEL" >/dev/null 2>&1; then
  : > "$marker"
  notify "🔧 $branch の CI が失敗 → issue 起票（$CI_ISSUE_LABEL）— $wf"
  log ci "filed CI failure run=#$runid conclusion=$conclusion label=$CI_ISSUE_LABEL"
else
  log warn "gh issue create 失敗（CI failure run=#$runid / label=$CI_ISSUE_LABEL）"
fi
