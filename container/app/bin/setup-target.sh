#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# setup-target ── 対象リポジトリを clone し、ループ設定と認証を流し込む。
#   冪等: 起動のたびに走らせてよい（clone済みなら skip、認証配線は毎回再適用）。
#   supervisor が起動時に自動実行する。
# ─────────────────────────────────────────────────────────────
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
source ./config.sh

[ -n "$TARGET_REPO_URL" ] || { echo "ERROR: config.sh の TARGET_REPO_URL を先に埋めてください" >&2; exit 1; }

# ── 1) 認証を先に配線（private repo の clone にも必要なので clone より前）──
#   GitHub App / 静的 GH_TOKEN のどちらでも bin/gh-token.sh が有効なトークンを供給する。
#   git は credential helper 経由、gh は PATH 上のラッパー(/usr/local/bin/gh)経由で
#   毎回フレッシュなトークンを使う（App の短命トークン失効を吸収）。
if "$LOOP_DIR/bin/gh-token.sh" >/dev/null 2>&1; then
  git config --global credential.https://github.com.username x-access-token
  git config --global "credential.https://github.com.helper" "!$LOOP_DIR/bin/gh-token.sh --git"
  if [ -n "${GITHUB_APP_ID:-}" ]; then echo "✅ GitHub 認証: App モード (app_id=$GITHUB_APP_ID)"
  else echo "✅ GitHub 認証: 静的トークンモード (GH_TOKEN)"; fi
else
  echo "⚠️ GitHub 認証トークンを取得できません。.env に GITHUB_APP_ID(+秘密鍵) か GH_TOKEN を設定してください。" >&2
fi

# ── 2) clone（無ければ）──
if [ ! -d "$TARGET_REPO_DIR/.git" ]; then
  echo "cloning $TARGET_REPO_URL -> $TARGET_REPO_DIR"
  git clone "$TARGET_REPO_URL" "$TARGET_REPO_DIR"
fi

# ── 3) git identity（未設定だと git commit が失敗する）──
git -C "$TARGET_REPO_DIR" config user.name  "$GIT_USER_NAME"
git -C "$TARGET_REPO_DIR" config user.email "$GIT_USER_EMAIL"

# ── 4) 権限とスキルを対象 repo の .claude/ に設置（Claude セッションがここを読む）──
#   再実行で loop-task/loop-task と入れ子になるのを防ぐため一旦消してから cp（冪等）
mkdir -p "$TARGET_REPO_DIR/.claude/skills"
cp "$LOOP_DIR/.claude/settings.json" "$TARGET_REPO_DIR/.claude/settings.json"
rm -rf "$TARGET_REPO_DIR/.claude/skills/loop-task"
cp -r "$LOOP_DIR/.claude/skills/loop-task" "$TARGET_REPO_DIR/.claude/skills/"
# loop-decompose = 仕様フェーズの分解タスク用スキル（poll-spec が投函・loop-task が委譲）。executor 側なので配布する。
if [ -d "$LOOP_DIR/.claude/skills/loop-decompose" ]; then
  rm -rf "$TARGET_REPO_DIR/.claude/skills/loop-decompose"
  cp -r "$LOOP_DIR/.claude/skills/loop-decompose" "$TARGET_REPO_DIR/.claude/skills/"
fi
# サブエージェント（research=Haiku 読み取り専用 等）も配布。Fixer が調査を委譲して使う。
if [ -d "$LOOP_DIR/.claude/agents" ]; then
  rm -rf "$TARGET_REPO_DIR/.claude/agents"
  cp -r "$LOOP_DIR/.claude/agents" "$TARGET_REPO_DIR/.claude/"
fi

# ── 4.2) ラベルを用意（冪等）──
#   loop      = ループの駆動対象（issue にこれを付けると拾われる）
#   loop:redo = 人間が「もう一度やって」を指示するジェスチャ（poll-gh が1回で消費）。
#               ファイルを触らず GitHub 上のラベル1つ（iOS でもタップ可）で再着手できる。
#   loop:long = 「このissueは時間がかかる」属性。付くと driver のチェックポイントが長め
#               （TASK_TIMEOUT_LONG）になる。タイムアウト中断→再開時の再中断を避ける用途。
#   loop:plan = プランモード。付くと bot は issue を見に来て方針/設計をコメントで議論するが
#               コードには一切触れない。実装に移すときは外して loop に付け替える。
_slug=$(printf '%s' "$TARGET_REPO_URL" | sed -E 's#.*github\.com[:/]##; s#\.git$##')
if [ -n "$_slug" ]; then
  gh label create loop          -R "$_slug" --color BFD4F2 --description "ループの駆動対象" 2>/dev/null || true
  gh label create loop:redo     -R "$_slug" --color D93F0B --description "人間が再着手を指示（1回で消費）" 2>/dev/null || true
  gh label create loop:long     -R "$_slug" --color FBCA04 --description "時間がかかる issue（チェックポイントを長めに）" 2>/dev/null || true
  gh label create loop:plan     -R "$_slug" --color 0E8A16 --description "プランモード（コードに触れず方針を議論）" 2>/dev/null || true
  gh label create loop:proposed -R "$_slug" --color C5DEF5 --description "提案（人間が loop を付けて承認したら着手）" 2>/dev/null || true
fi

# ── 4.5) ループ用メモリを seed（冪等。既にあれば触らない＝蓄積を消さない）──
#   ループが規約・レビュー嗜好・失敗を溜めて次のタスクに効かせる知識ベース。
#   対象 repo の外（.loop 配下）に置く＝PR に混入しない・バインドマウントで永続。
mkdir -p "$MEMORY_DIR" "$OUTCOMES_DIR"
[ -f "$MEMORY_DIR/MEMORY.md" ] || cat > "$MEMORY_DIR/MEMORY.md" <<'EOF'
# ループのメモリ索引

ここはループが**タスクを跨いで蓄積する知識**。タスク開始時にこの索引を読み、
関連するカテゴリファイルを参照してから実装/対応する。終了時に“次に効く”学びだけ追記する。
（一過性の事実や既知のことは書かない。重複は統合し、誤りは消す。）

- conventions.md — コードベースの規約・ビルド/テストの癖・どこに何があるか
- review-prefs.md — レビューで繰り返し求められること（PR の changes-requested から学ぶ）
- pitfalls.md — 頻出する失敗と回避法
- outcomes.md — マージ後の現実のアウトカム（revert / issue 再オープン）。poll-outcome.sh が自動記録。タスクで関連を見たら教訓を pitfalls/review-prefs に昇格する
EOF
for f in conventions review-prefs pitfalls outcomes; do
  [ -f "$MEMORY_DIR/$f.md" ] || printf '# %s\n\n（まだ無し。タスクで学んだら追記する）\n' "$f" > "$MEMORY_DIR/$f.md"
done

# ── 5) loop-report を PATH へ（Claude がどの cwd からでも叩けるように）──
ln -sf "$LOOP_DIR/bin/loop-report" /usr/local/bin/loop-report 2>/dev/null \
  || echo "note: /usr/local/bin に symlink できず。PATH に $LOOP_DIR/bin を通してください。"

echo "✅ target ready at $TARGET_REPO_DIR"
