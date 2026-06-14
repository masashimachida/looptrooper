#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# status ── ループの状態を一括表示する人間用ダッシュボード（読み取り専用・LLM 非依存）。
#   使い方: docker compose exec loop ./bin/status.sh
#   ログを個別に追わなくても、番人/認証/タスク/GitHub/メモリ/アウトカム/直近通知が一目で分かる。
# ─────────────────────────────────────────────────────────────
set -uo pipefail   # -e は付けない（1項目の失敗で全体を止めない＝ダッシュボードは頑健に）
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
source ./config.sh
source ./bin/lib.sh 2>/dev/null || true

cnt() { ls $1 2>/dev/null | wc -l | tr -d ' '; }
age() { local s=$1; if [ "$s" -lt 60 ]; then echo "${s}s"; elif [ "$s" -lt 3600 ]; then echo "$((s/60))m$((s%60))s"; else echo "$((s/3600))h$((s%3600/60))m"; fi; }
hr()  { printf '─%.0s' $(seq 1 52); echo; }

hr; echo " loop status — $(date '+%F %T %Z')"; hr

# ── 番人 ──
echo; echo "■ 番人"
for p in session-keeper driver poller; do
  if pgrep -f "bin/$p.sh" >/dev/null 2>&1; then s="✅ up"; else s="❌ DOWN"; fi
  printf "  %-16s %s\n" "$p" "$s"
done
if [ -f "$STATE_DIR/poller.heartbeat" ]; then
  hb=$(cat "$STATE_DIR/poller.heartbeat" 2>/dev/null || echo 0)
  printf "  %-16s 最終巡回 %s 前（間隔 %ss）\n" "poller cycle" "$(age $(( $(date +%s) - hb )))" "$POLL_GH_INTERVAL"
fi

# ── 認証 ──
echo; echo "■ 認証"
if [ -n "${GITHUB_APP_ID:-}" ]; then echo "  モード: GitHub App (app_id=$GITHUB_APP_ID)"; else echo "  モード: 静的 GH_TOKEN"; fi
echo "  APIレート残: $(gh api rate_limit --jq '.rate | "\(.remaining)/\(.limit)"' 2>/dev/null || echo '取得失敗（認証/障害?）')"

# ── タスク（ファイル＝状態機械）──
echo; echo "■ タスク"
printf "  queue:%s  処理中:%s  blocked:%s  awaiting:%s  processed:%s\n" \
  "$(cnt "$QUEUE_DIR/*.md")" "$(cnt "$STATE_DIR/*.inprogress")" "$(cnt "$BLOCKED_DIR/*.md")" "$(cnt "$AWAITING_DIR/*.md")" "$(cnt "$PROCESSED_DIR/*.md")"
for f in "$STATE_DIR"/*.inprogress; do [ -e "$f" ] && echo "   ▶ 処理中: $(basename "$f" .inprogress)"; done
for f in "$BLOCKED_DIR"/*.md;        do [ -e "$f" ] && echo "   ⚠ blocked: $(basename "$f" .md)"; done
for f in "$AWAITING_DIR"/*.md;       do [ -e "$f" ] && echo "   ❓ awaiting: $(basename "$f" .md)"; done

# ── GitHub 側 ──
echo; echo "■ GitHub"
slug=$(target_slug 2>/dev/null || true)
if [ -n "$slug" ]; then
  echo "  repo: $slug"
  echo "  open loop issue: $(gh issue list -R "$slug" --label loop --state open --json number --jq 'length' 2>/dev/null || echo '?')  /  open PR: $(gh pr list -R "$slug" --state open --json number --jq 'length' 2>/dev/null || echo '?')  /  提案(loop:proposed): $(gh issue list -R "$slug" --label 'loop:proposed' --state open --json number --jq 'length' 2>/dev/null || echo '?')"
fi
blk=$(cnt "$STATE_DIR/issue-*.blocked"); [ "$blk" != "0" ] && echo "  依存待ち(blocked) issue: $blk"

# ── メモリ（蓄積）──
echo; echo "■ メモリ（蓄積知識）"
for f in conventions review-prefs pitfalls outcomes; do
  p="$MEMORY_DIR/$f.md"; [ -f "$p" ] || continue
  if grep -q '（まだ無し' "$p" 2>/dev/null; then st="空"; else st="$(grep -c . "$p" 2>/dev/null) 行"; fi
  printf "  %-13s %-7s (更新 %s)\n" "$f" "$st" "$(stat -c %y "$p" 2>/dev/null | cut -d. -f1)"
done

# ── 最近のアウトカム ──
if [ -s "$MEMORY_DIR/outcomes.md" ] && grep -q '^- ' "$MEMORY_DIR/outcomes.md" 2>/dev/null; then
  echo; echo "■ 最近のアウトカム"
  grep '^- ' "$MEMORY_DIR/outcomes.md" 2>/dev/null | tail -3 | sed 's/^/  /'
fi

# ── 直近の通知・警告 ──
echo; echo "■ 直近の通知・警告（driver.log）"
grep -aE '\[(notify|warn|outcome|deps|redo)\]' "$LOGS_DIR/driver.log" 2>/dev/null | tail -6 | sed 's/^/  /' || true
hr
