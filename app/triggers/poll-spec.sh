#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# poll-spec ── 環境からゴールを生成する観測者（その2: 仕様書）。LLM はここでは呼ばない。
#   対象 repo の SPEC_DIR（既定 spec/）を入力に、フェーズ単位で issue 群を自律分解する。
#     入力 = 00-overview.md（全体像・共通制約）＋ NN-slug.md（フェーズ1枚。意味の単位）。
#     フェーズ = GitHub マイルストーン「NN: slug」（完了検知＝open_issues==0 かつ closed>0）。
#   遅延分解: 前フェーズが完了してから次フェーズを分解する（前フェーズのマージ済み実物を読んで割る＝drift 補正）。
#   承認ゲートは PR マージに移動（issue 再承認はしない＝spec を人間が承認済み）。マージは必ず人間なので
#   フェーズ進行＝人間がそのフェーズの PR をマージすること＝全自動でも main に勝手に入らない。
#
#   ここ(bash)がやるのは「次に分解すべきフェーズの検知」と「マイルストーン作成（＝冪等マーカー）」だけ。
#   実際の issue 分解は分解タスク（loop-decompose スキル）に委譲する＝LLM はそこだけ。
#   冪等: マイルストーンの存在が「分解済み/分解中」の唯一の印（自前 state 台帳が不要）。
#     - マイルストーン無し          → 未分解
#     - マイルストーン有り & 未完了  → 分解中 or 進行中（再分解しない）
#     - マイルストーン有り & 完了    → 次フェーズへ進める
#   失敗時（分解タスクが空マイルストーンを残して落ちた）は driver が ⚠️ 通知＝人間が GitHub でその
#   マイルストーンを削除すれば次 poll で再分解される（GitHub を唯一の共有面に）。
# ─────────────────────────────────────────────────────────────
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
source ./config.sh
source ./bin/lib.sh
mkdir -p "$STATE_DIR"

command -v gh >/dev/null 2>&1 || { echo "gh not installed" >&2; exit 1; }
slug=$(target_slug)
[ -n "$slug" ] || { echo "ERROR: 対象 repo の slug を解決できません" >&2; exit 1; }

spec_path="$TARGET_REPO_DIR/$SPEC_DIR"
[ -d "$spec_path" ] || { log spec "対象に $SPEC_DIR/ が無い（仕様書駆動は無効）"; exit 0; }

# フェーズファイル一覧: NN-slug.md（NN>=01。00-overview.md は全体像なのでフェーズ扱いしない）。番号順。
mapfile -t phases < <(cd "$spec_path" && ls -1 [0-9][0-9]-*.md 2>/dev/null | grep -v '^00-' | sort)
[ "${#phases[@]}" -gt 0 ] || { log spec "$SPEC_DIR/ にフェーズ(NN-slug.md)が無い"; exit 0; }

# マイルストーン一覧（open/closed 両方）。title→「番号 open数 closed数 状態」を引く。
ms_json=$(gh api "repos/$slug/milestones?state=all&per_page=100" --paginate 2>/dev/null | jq -s 'add // []' 2>/dev/null || echo "[]")
get_ms() { jq -r --arg t "$1" 'map(select(.title==$t)) | first | if . == null then "" else "\(.number) \(.open_issues) \(.closed_issues) \(.state)" end' <<<"$ms_json"; }

prev_complete=true   # 先頭フェーズには先行が無いので「前は完了」とみなす
for f in "${phases[@]}"; do
  nn="${f%%-*}"            # 例 "01"
  base="${f%.md}"          # 例 "01-auth"
  slugname="${base#*-}"    # 例 "auth"
  mtitle="$nn: $slugname"  # マイルストーン名「01: auth」

  info=$(get_ms "$mtitle")
  if [ -n "$info" ]; then
    read -r _mnum mopen mclosed _mstate <<<"$info"
    if [ "$mopen" -eq 0 ] && [ "$mclosed" -gt 0 ]; then
      prev_complete=true; continue                     # このフェーズは完了 → 次へ
    fi
    # 分解済みだが未完了（分解タスク実行待ち / issue 進行中 / 失敗で空のまま）→ 何もしない
    log spec "フェーズ '$mtitle' 進行中 (open=$mopen closed=$mclosed) — 次フェーズ分解は保留"
    exit 0
  fi

  # ここはマイルストーン未作成＝未分解フェーズ
  if [ "$prev_complete" != true ]; then
    log spec "前フェーズ未完了のため '$mtitle' は分解しない（遅延分解）"
    exit 0
  fi

  # ── 分解の番（前フェーズ完了 & このフェーズ未分解）──
  # 1) マイルストーンを bash で作る（＝冪等マーカー。これ以降 get_ms がヒットし二重分解を防ぐ）
  mnum=$(gh api "repos/$slug/milestones" -f title="$mtitle" \
           -f description="spec/$f より自動分解（poll-spec）" --jq '.number' 2>/dev/null) \
    || { log warn "マイルストーン作成失敗: $mtitle（次周回で再試行）"; exit 1; }
  log spec "マイルストーン作成: '$mtitle' (#$mnum) — 分解タスクを投函"

  # 2) 分解タスクを投函（LLM はここで初めて働く）。issue は付かない＝task_timeout は長めに取る。
  overview_rel="$SPEC_DIR/00-overview.md"
  [ -f "$spec_path/00-overview.md" ] || overview_rel="(なし)"
  LOOP_SOURCE=spec ./bin/enqueue.sh "仕様分解 $mtitle" - <<EOF
これは**仕様書駆動の分解タスク**です。通常の実装フローではなく、\`loop-decompose\` スキルの手順に従ってください
（このフェーズを 1 PR 単位の issue 群に分解して起票する。コード実装・PR は作りません）。

spec_phase: $nn
spec_slug: $slugname
milestone: $mtitle
milestone_number: $mnum
spec_overview: $overview_rel
spec_file: $SPEC_DIR/$f
task_timeout: $TASK_TIMEOUT_LONG

要点（詳細は loop-decompose スキル）:
- 全体像 \`$overview_rel\`（共通制約・用語）と このフェーズ \`$SPEC_DIR/$f\` を読む。
- 先行フェーズがあればマージ済みの実物（コード）を読んで接地する（spec と実装の drift を補正）。
- このフェーズを **1 PR 単位（目安 ~10分で完了見込み）** の issue に割る（フェーズ内の issue 数は無制限）。
- マイルストーン「$mtitle」は**作成済み**。各 issue は \`--milestone "$mtitle"\` で必ずこのフェーズに紐付ける。
- フェーズ内の順序は GitHub の issue dependencies（blocked_by）で配線する。
- **ラベル \`loop\` は最後に付ける**（作成 → 依存配線 → ラベルの順＝poll-gh が拾う時に依存が揃っている）。
EOF

  notify "🧩 spec: フェーズ「$mtitle」の分解タスクを投函しました（issue 群を自動起票します）"
  exit 0
done

log spec "全フェーズが分解済み/完了（やることなし）"
