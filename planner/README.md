# planner/ — 人間（プランナー役）の道具

ループに食わせる**入力（issue / spec）の質**を上げるための、**人間が対話的に使う** Claude ツール。
loop-task（executor＝無人）と対になる入力側で、**コンテナにも対象 repo にも自動配布されない**
（`container/app/`＝イメージ payload の外に置くのはこのため。`bin/loopctl` と同じ host/人間レイヤ）。

| 中身 | 用途 |
|---|---|
| `skills/draft-loop-issue/` | 対象 repo に接地した精密な `loop`/`loop:proposed` issue を起票する skill |
| `commands/draft-loop-spec.md` | `/draft-loop-spec`＝spec（`poll-spec` が食う `spec/`）を問い詰めて起草するスラッシュコマンド |

## 使い方（インストール）

人間が対象 repo を checkout したセッションで使う。グローバルに置くのが手軽:

```bash
cp -r planner/skills/draft-loop-issue ~/.claude/skills/
cp planner/commands/draft-loop-spec.md ~/.claude/commands/
```

または対象 repo の `.claude/` にコミットして共有する。
