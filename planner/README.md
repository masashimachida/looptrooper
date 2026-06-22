# planner/ — 人間（プランナー役）の道具

ループに食わせる**入力（issue / spec）の質**を上げるための、**人間が対話的に使う** Claude ツール。
loop-task（executor＝無人）と対になる入力側で、**コンテナにも対象 repo にも自動配布されない**
（`container/app/`＝イメージ payload の外に置くのはこのため。`bin/loopctl` と同じ host/人間レイヤ）。

| 中身 | 用途 |
|---|---|
| `commands/draft-loop-issue.md` | `/draft-loop-issue`＝対象 repo に接地した精密な `loop`/`loop:proposed` issue を問い詰めて起票するスラッシュコマンド |
| `commands/draft-loop-spec.md` | `/draft-loop-spec`＝spec（`poll-spec` が食う `spec/`）を問い詰めて起草するスラッシュコマンド |

どちらも `grill-me` 方式で、人間を容赦なく問い詰めて曖昧さを潰す。
`/draft-loop-spec` が上流（spec 全体＝フェーズ群）、`/draft-loop-issue` が下流（1 issue＝1 PR）にあたる。

## 使い方（インストール）

人間が対象 repo を checkout したセッションで使う。グローバルに置くのが手軽:

```bash
cp planner/commands/draft-loop-issue.md ~/.claude/commands/
cp planner/commands/draft-loop-spec.md ~/.claude/commands/
```

または対象 repo の `.claude/` にコミットして共有する。
