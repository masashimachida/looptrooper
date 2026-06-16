#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# poll-test ── 重いテストを1日1回だけ回し、落ちたら issue を自動起票する。LLM を呼ばない。
#   毎タスクの Verifier では重すぎて回せない e2e 等を定期実行し、失敗を起票して loop に拾わせる。
#   「軽いテストは毎タスクの Verifier で / 重いテストは1日1回ここで」という補完関係。
#   ガード:
#     ・HEAVY_TEST_CMD が空なら何もしない（＝既定オフ。使うプロジェクトだけ .env で埋める）
#     ・HEAVY_TEST_INTERVAL（既定24h）で自己スロットル（lastrun は .loop/state＝永続）
#     ・隠しマーカー付きの open issue が既にあれば再起票しない（持続失敗の量産を防ぐ）
#     ・issue 本文に貼るのは失敗ログの末尾 HEAVY_TEST_TAIL 行だけ（漏えい面・肥大化を抑える）
#   ラベルは HEAVY_TEST_LABEL（既定 loop:proposed＝人間承認後に着手）。
# ─────────────────────────────────────────────────────────────
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
source ./config.sh
source ./bin/lib.sh
mkdir -p "$STATE_DIR"

# ── コマンド未設定なら無効（このプロジェクトでは使わない）──
[ -n "${HEAVY_TEST_CMD:-}" ] || exit 0

command -v gh >/dev/null 2>&1 || { echo "gh not installed" >&2; exit 1; }
slug=$(target_slug)
[ -n "$slug" ] || { echo "ERROR: 対象 repo の slug を解決できません" >&2; exit 1; }

# ── 自己スロットル（1日1回相当）。lastrun は実行前に更新＝
#    途中失敗で毎周回 重いテストを回し直すのを防ぐ（重い処理なので特に重要）──
lastrun_file="$STATE_DIR/heavy-test.lastrun"
now=$(date +%s)
last=$(cat "$lastrun_file" 2>/dev/null || echo 0)
[ $((now - last)) -ge "$HEAVY_TEST_INTERVAL" ] || exit 0   # まだ間隔内
echo "$now" > "$lastrun_file"

# ── 重いテストを実行（対象 repo で。失敗時 exit!=0 を握る）──
log test "重いテスト実行: $HEAVY_TEST_CMD"
set +e
out=$(cd "$TARGET_REPO_DIR" && eval "$HEAVY_TEST_CMD" 2>&1)
rc=$?
set -e

if [ "$rc" -eq 0 ]; then
  log test "重いテスト PASS（起票なし）"
  exit 0
fi

# ── 既に未対応の起票があれば蒸し返さない（持続失敗の量産防止）──
#   隠しマーカー <!-- loop:heavy-test --> を本文に持つ open issue を探す。
marker='<!-- loop:heavy-test -->'
existing=$(gh issue list -R "$slug" --state open --json number,body \
             --jq "map(select(.body | contains(\"$marker\"))) | .[0].number" 2>/dev/null || echo "")
if [ -n "$existing" ] && [ "$existing" != "null" ]; then
  log test "重いテスト FAIL（rc=$rc）だが既存の起票 #$existing があるので再起票しない"
  exit 0
fi

# ── 失敗ログの末尾だけ抜粋（生ログ全体は貼らない）──
total_lines=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
excerpt=$(printf '%s\n' "$out" | tail -n "$HEAVY_TEST_TAIL")
trunc_note=""
[ "$total_lines" -gt "$HEAVY_TEST_TAIL" ] && trunc_note="（全 ${total_lines} 行中、末尾 ${HEAVY_TEST_TAIL} 行を抜粋）"

body=$(cat <<EOF
🤖 定期実行している重いテストが失敗しました（poll-test.sh）。

- コマンド: \`$HEAVY_TEST_CMD\`
- 終了コード: **$rc**
- 実行日時: $(date +%FT%T%z)

**対応**: 失敗の原因を特定し、最小差分で修正してから \`\$BUILD_CMD\` / \`\$TEST_CMD\` を通して PR を開いてください（closes でこの issue に紐付け）。flaky（実行ごとに揺れる）と判断した場合は、安定化（リトライ/待機/前提の固定化）も検討。

<details><summary>失敗ログ抜粋 $trunc_note</summary>

\`\`\`
$excerpt
\`\`\`

</details>

$marker
EOF
)

if gh issue create -R "$slug" --title "🤖 [auto] 重いテストが失敗 (exit $rc)" --body "$body" --label "$HEAVY_TEST_LABEL" >/dev/null 2>&1; then
  notify "🔧 重いテストが失敗 → issue 起票（$HEAVY_TEST_LABEL）"
  log test "filed heavy-test failure (rc=$rc) label=$HEAVY_TEST_LABEL"
else
  log warn "gh issue create 失敗（重いテスト failure / label=$HEAVY_TEST_LABEL）"
fi
