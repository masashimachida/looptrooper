#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# poll-deps ── 環境からゴールを生成する観測者（その1: 依存の脆弱性）。LLM を呼ばない。
#   対象 repo を監査し、high/critical かつ修正版がある脆弱性を「issue」として自動起票する。
#   ・非メジャー修正 → `loop` ラベル（=自動で実装→PR まで走る。マージは人間ゲート）
#   ・メジャー（破壊的）修正 → `loop:proposed`（人間が `loop` を付けて承認したら着手）
#   ガード: 修正版があるものだけ / 重複起票しない（advisory ごとにマーカー）/ 1回の上限 /
#           夜間1回に自己スロットル。検証(Verifier)が通らなければ PR は出ない（既存フロー）。
#   ※監査は AUDIT_CMD（既定 npm audit --json）。パースは npm audit JSON 形式を仮定。
# ─────────────────────────────────────────────────────────────
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
source ./config.sh
source ./bin/lib.sh
mkdir -p "$STATE_DIR"

command -v gh >/dev/null 2>&1 || { echo "gh not installed" >&2; exit 1; }
slug=$(target_slug)
[ -n "$slug" ] || { echo "ERROR: 対象 repo の slug を解決できません" >&2; exit 1; }

# ── 自己スロットル（夜間1回相当）。lastrun は .loop/state（バインドマウントで永続）──
lastrun_file="$STATE_DIR/deps.lastrun"
now=$(date +%s)
last=$(cat "$lastrun_file" 2>/dev/null || echo 0)
[ $((now - last)) -ge "$DEPS_INTERVAL" ] || exit 0   # まだ間隔内
echo "$now" > "$lastrun_file"

# ── 監査（対象 repo で実行。脆弱性ありだと exit!=0 なので握る）──
audit_json=$(cd "$TARGET_REPO_DIR" && eval "$AUDIT_CMD" 2>/dev/null || true)
[ -n "$audit_json" ] || { log deps "監査出力なし（対象が npm でない or 監査不可）"; exit 0; }

# high/critical かつ fixAvailable のものを1行JSONで抽出
filtered=$(jq -c '
  (.vulnerabilities // {}) | to_entries[]
  | .key as $pkg | .value as $v
  | select($v.severity=="high" or $v.severity=="critical")
  | select($v.fixAvailable != false)
  | ([$v.via[]? | select(type=="object")] | first) as $adv
  | {
      pkg: $pkg,
      severity: $v.severity,
      major: ($v.fixAvailable | if type=="object" then (.isSemVerMajor // false) else false end),
      fixver: ($v.fixAvailable | if type=="object" then (.version // "") else "" end),
      advid: ($adv.source // 0),
      title: ($adv.title // "既知の脆弱性"),
      url: ($adv.url // "")
    }
' <<<"$audit_json" 2>/dev/null || true)
[ -n "$filtered" ] || { log deps "high/critical かつ修正可能な脆弱性なし"; exit 0; }

count=0
while read -r v; do
  [ -n "$v" ] || continue
  pkg=$(jq -r '.pkg' <<<"$v"); sev=$(jq -r '.severity' <<<"$v")
  major=$(jq -r '.major' <<<"$v"); fixver=$(jq -r '.fixver' <<<"$v")
  advid=$(jq -r '.advid' <<<"$v"); title=$(jq -r '.title' <<<"$v"); aurl=$(jq -r '.url' <<<"$v")

  sig="$advid"; [ "$sig" = "0" ] && sig="pkg-$pkg"      # advisory id が無ければ pkg 名で代用
  marker="$STATE_DIR/dep-$sig.filed"
  [ -f "$marker" ] && continue                          # 既に起票済み（却下されても蒸し返さない）
  [ "$count" -ge "$DEPS_MAX_PER_RUN" ] && continue      # 上限。マーカーは立てず次回へ回す

  if [ "$major" = "true" ]; then
    label="loop:proposed"; kind="メジャー（破壊的変更の可能性。人間承認後に着手）"
  else
    label="loop"; kind="マイナー/パッチ"
  fi

  body=$(cat <<EOF
🤖 自動検出した依存の脆弱性です（poll-deps.sh）。

- パッケージ: \`$pkg\`
- 深刻度: **$sev**
- 脆弱性: $title
- 詳細: $aurl
- 推奨修正版: ${fixver:-（バージョン範囲内の更新で解消）}（$kind）

**対応**: 当該依存を安全な版へ更新し、\`\$BUILD_CMD\` / \`\$TEST_CMD\` を通してから PR を開いてください。
破壊的変更があればテストで検出し、必要な追従修正も最小差分で行うこと（closes でこの issue に紐付け）。

<!-- loop:dep advisory=$sig -->
EOF
)

  if gh issue create -R "$slug" --title "🤖 [auto] 依存の脆弱性: $pkg ($sev)" --body "$body" --label "$label" >/dev/null 2>&1; then
    : > "$marker"
    count=$((count + 1))
    notify "🔧 dep: $pkg の脆弱性($sev)を起票（$label）— $title"
    log deps "filed $pkg advisory=$sig label=$label"
  else
    log warn "gh issue create 失敗: $pkg（advisory=$sig）"
  fi
done < <(printf '%s\n' "$filtered")
