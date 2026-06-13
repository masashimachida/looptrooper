# LOOP_STATE — ループの状態ボード

> 人間が見る用。基本は **⚠️ Needs attention** だけ見ればよい。
> 詳細ログは `.loop/logs/`（driver.log / session.log）。

## ⚠️ Needs attention
（blocked / failed / crash-loop / usage-pause がここに上がる）

- なし

## In progress
- なし

## Recently done
- なし

---

## セットアップ状況
- 対象リポジトリ: **未定** — `config.sh` の `TARGET_REPO_URL` / `TARGET_REPO_DIR` を埋める
- スタックコマンド: **未設定** — `config.sh` の `BUILD_CMD` / `TEST_CMD` / `LINT_CMD`
- GitHub branch protection（main）: **未設定** — リモート側で PR必須・force/削除禁止を有効化
- 認証情報: **GitHub App**（`GITHUB_APP_ID`＋秘密鍵）を推奨／代替で repo単位 PAT（`GH_TOKEN`）。供給は `bin/gh-token.sh` に一元化
