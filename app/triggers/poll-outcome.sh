#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# poll-outcome ── ループが「出した」結果の“その後”を観測してメモリに返す（LLM を呼ばない）。
#   「テスト緑」という代理指標ではなく、現実のアウトカムをループに突き返すのが狙い。
#   検出する負のアウトカム:
#     (a) revert        … マージ済み loop PR が後から revert された（出した変更が悪かった）
#     (b) issue 再オープン … loop が直して閉じた issue がまた開いた（直っていなかった）
#   検出したら .loop/memory/outcomes.md に1行追記し ⚠️ 通知。冪等（OUTCOMES_DIR のマーカーで二重記録を防ぐ）。
#   ※pollers は supervisor 配下の素 bash＝Claude セッションの権限プロファイルには縛られない。
# ─────────────────────────────────────────────────────────────
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
source ./config.sh
source ./bin/lib.sh
mkdir -p "$OUTCOMES_DIR" "$MEMORY_DIR"

command -v gh >/dev/null 2>&1 || { echo "gh not installed" >&2; exit 1; }
slug=$(target_slug)
[ -n "$slug" ] || { echo "ERROR: 対象 repo の slug を解決できません" >&2; exit 1; }

# revert 検出のため main を最新化（失敗しても続行）
git -C "$TARGET_REPO_DIR" fetch -q origin "$DEFAULT_BRANCH" 2>/dev/null || true

record() { printf -- '- [%s] %s\n' "$(date +%F)" "$1" >> "$MEMORY_DIR/outcomes.md"; }

# 直近のマージ済み loop PR を観測対象にする（古いものは window 外に流れて自然に対象外）。
gh pr list -R "$slug" --state merged --limit 30 \
   --json number,headRefName,title,url,mergeCommit,closingIssuesReferences 2>/dev/null \
| jq -c '.[] | select(.headRefName | startswith("loop/"))' 2>/dev/null | while read -r row; do
    m=$(jq -r '.number' <<<"$row")
    title=$(jq -r '.title' <<<"$row")
    url=$(jq -r '.url' <<<"$row")
    sha=$(jq -r '.mergeCommit.oid // ""' <<<"$row")

    : > "$OUTCOMES_DIR/pr-$m.seen"   # 出荷台帳（観測対象として記録）

    # ── (a) revert 検出 ──────────────────────────────
    rev="$OUTCOMES_DIR/pr-$m.reverted"
    if [ ! -f "$rev" ] && [ -n "$sha" ]; then
      if git -C "$TARGET_REPO_DIR" log "origin/$DEFAULT_BRANCH" \
           --grep "This reverts commit $sha" --format=%H 2>/dev/null | grep -q .; then
        : > "$rev"
        record "PR #$m「$title」はマージ後に **revert** された。出した変更が悪かった可能性が高い。次に同種の箇所を触るときはテスト/影響範囲の見落としを疑う。"
        notify "⚠️ outcome: PR #$m がマージ後に revert されました（$title）| $url"
        log outcome "PR #$m reverted"
      fi
    fi

    # ── (b) クローズした issue の再オープン検出 ──────────
    for n in $(jq -r '.closingIssuesReferences[]?.number // empty' <<<"$row"); do
      ro="$OUTCOMES_DIR/issue-$n.reopened"
      [ -f "$ro" ] && continue
      st=$(gh issue view "$n" -R "$slug" --json state -q '.state' 2>/dev/null || echo "")
      if [ "$st" = "OPEN" ]; then
        : > "$ro"
        record "issue #$n は loop の修正(PR #$m)後に **再オープン** された。前回の対応では不十分。再対応時は前回の差分と何が足りなかったかを踏まえる。"
        notify "⚠️ outcome: issue #$n が loop 修正後に再オープン（PR #$m）。再着手させるなら issue に \`loop:redo\` ラベルを付けてください | $url"
        log outcome "issue #$n reopened after PR #$m"
      fi
    done
done
