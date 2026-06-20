# 用語集

LoopTrooper 特有の用語（コンポーネント名・役割名）。**使い方は [README](../README.md)**、**設計は [architecture.md](./architecture.md) / [mechanism.md](./mechanism.md)** を参照。
一般的な CS / git / Docker / tmux の語彙はそのまま使う。

| 用語 | 意味 |
|---|---|
| **ループ** | この自律保守サイクル全体。「実装→検証→PR 提案」を無人で回す仕組みそのもの。 |
| **トリガ** | 外部の出来事（issue が立った・PR にレビューが付いた等）を検知してタスクを起こす bash スクリプト群。`triggers/poll-*.sh`。 |
| **poller（ポーラー）** | トリガを定期実行する常駐プロセス。 |
| **ドライバ（driver）** | キューを1件ずつ直列に消化し、tmux 内の Claude にタスクを渡す**単一の常駐プロセス**。Claude の画面を触る唯一の存在。 |
| **注入（inject）** | ドライバが Claude の画面に**短い固定フレーズだけ**送り込む操作（タスク本文はファイル側に置く）。 |
| **番人（watchdog 群）** | プロセスの生存・進捗を監視し、落ちたら立て直す層状の仕組み。下記 supervisor / session-keeper など。 |
| **supervisor** | 番人の親。session-keeper＋driver＋poller を起こし、1つでも死ねば全部畳んで再起動に委ねる。 |
| **session-keeper** | Claude 対話セッション（tmux）の生存番人。落ちたら再起動、crash-loop は遮断する。 |
| **Fixer / Verifier** | タスク内の役割分担。実装する係（Fixer）と検証する係（Verifier）を別サブエージェントに分ける。Verifier が `BUILD/TEST/LINT_CMD` と `/code-review` を回す。 |
| **loop-report** | Claude がタスクの最後に1回だけ叩く報告コマンド。結果を `.loop/results/<id>.json` に書く。 |
| **dind（Docker in Docker）** | コンテナの中でもう1つの Docker を動かす方式。対象 repo の Docker 検証をコンテナ内で完結させ、ホストの docker は触らせない。 |
