# ISUCON 準備用スクリプト

ISUCON 当日に「構成の把握 → 変更の反映 → 計測 → 集計・比較 → 調査」を繰り返すための小さなスクリプト群とドキュメントです。
Go アプリ・MySQL・nginx（Ubuntu + systemd のサーバー）を、手元の PC から SSH で操作することを想定しています。

- このディレクトリ（`sh/`）だけで完結しています。ディレクトリごと別のリポジトリへコピーしても動きます。スクリプトは自分の置き場所からパスを決めるので、どのディレクトリから実行してもかまいません。
- **当日のレギュレーション・マニュアルがこのリポジトリの手順より優先です。** 構成と利用できる操作は当日に確認してください。
- このリポジトリのスクリプトは、実行するまでサーバーに接続しません。また、設定の `__TODO__` を埋めるまで動きません。

## できること

| コマンド | 内容 | サーバーへの変更 |
| --- | --- | --- |
| `scripts/inspect.sh` | OS・CPU・メモリ・待ち受け・サービス・nginx/MySQL の設定位置・ログの場所を調べる | なし |
| `scripts/verify.sh` | サービスの active/enabled、待ち受けポート、HTTP 応答を確認する | なし |
| `scripts/setup-tools.sh check` | 手元とサーバーの計測ツールの有無・バージョンを確認する | なし |
| `scripts/setup-tools.sh install --remote` | サーバーに足りないツールだけを導入する（`--dry-run` あり） | あり |
| `scripts/deploy/app.sh` | 手元でビルドし、app 役のホストへ配布・再起動・HTTP 確認（`--rollback` あり） | あり |
| `scripts/deploy/nginx.sh` | 管理する nginx 設定だけを配置し、`nginx -t` が通った場合だけ reload | あり |
| `scripts/deploy/mysql.sh` | 管理する MySQL 設定だけを配置・検証し、反映方法（なし / SET GLOBAL / 再起動）を明示的に選ぶ | あり |
| `scripts/lock.sh` | 対象ホスト上の実行状態ロックの確認・解除（計測中のデプロイを防ぐ） | 解除のみ |
| `scripts/measure.sh` | ベンチ1回分の計測（start / profile / stop / result）。ログの区間切り出しと回収 | 記録用プロセスの起動・停止のみ |
| `scripts/report.sh` | 回収したデータの集計（metrics.json・manifest.json・reports/）と context.md の生成 | なし |
| `scripts/agent-context.sh` | 実行ごとの入口 context.md（8 KiB 以内）を固定テンプレートで生成 | なし |
| `scripts/evidence.sh` | 対象を絞った根拠の取得（summary / api / sql / sql-detail / logs / resources / pprof） | なし |
| `scripts/compare.sh` | 基準の実行との比較（比較できない項目と理由を先に表示） | なし |

よく使う操作は `make help` でも一覧できます（`Makefile` は上のスクリプトを呼ぶだけのメニューです）。

## 依存関係

| 場所 | 必要なもの | 備考 |
| --- | --- | --- |
| 手元PC (macOS / Linux) | **bash 4.4 以上**、ssh、awk、jq、git | macOS 標準の bash は 3.2 なので `brew install bash` が必要。スクリプトは `#!/usr/bin/env bash` で起動するので、PATH 上で新しい bash が先に見つかるようにする |
| 手元PC（あると良い） | go（pprof の解析）、alp、pt-query-digest、shellcheck（テスト） | `scripts/setup-tools.sh install --local` で Homebrew / apt から導入できる |
| サーバー (Ubuntu) | bash、sudo（`sudo -n` で使えること）、systemd、curl、ss | ツールは `setup-tools.sh` で導入する |

サーバーに導入するツールと入手先:

| ツール | 入手先 | バージョン |
| --- | --- | --- |
| htop | Ubuntu の apt (`htop`) | ディストリビューションの版 |
| pidstat / iostat | Ubuntu の apt (`sysstat`) | 同上 |
| pt-query-digest | Ubuntu の apt (`percona-toolkit`) | 同上 |
| alp | [GitHub Releases](https://github.com/tkuchiki/alp/releases/tag/v1.0.22) | v1.0.22（sha256 を照合してから `/usr/local/bin` に配置） |

`apt upgrade` のようなシステム全体の更新や、curl で取得したスクリプトの実行は行いません。

## 初期設定

```bash
git clone <この fork>
cd private-isu-digix/sh                           # 以降のコマンドは sh/ を基準に書いています
cp config/isucon.conf.example config/isucon.conf   # Git 管理外
$EDITOR config/isucon.conf                         # __TODO__ を当日の構成に合わせて埋める
```

1. `~/.ssh/config` に各サーバーの Host を書き、`ssh isu1 true` がパスワードなしで通ることを確認します。
2. `config/isucon.conf` の `ISU_HOSTS`（SSH の Host 名）と `ISU_ROLES`（ホストごとの app / nginx / mysql）を設定します。
3. サービス名・ポート・確認する URL を設定します。分からない場合は、まず `inspect.sh` で調べてから埋めます。

## 最短の操作例

```bash
scripts/setup-tools.sh check            # 手元とサーバーのツールを確認
scripts/inspect.sh                      # 構成を調べる（全文は results/inspect/ に保存される）
scripts/verify.sh                       # サービス・ポート・HTTP の確認
scripts/setup-tools.sh install --remote --dry-run   # 導入予定の確認だけ
scripts/setup-tools.sh install --remote             # 実際に導入
scripts/deploy/app.sh --dry-run                  # 配布予定の確認（ビルド・SSH は行わない）
scripts/deploy/app.sh && scripts/verify.sh         # 配布して確認

# ベンチ1回分
scripts/measure.sh start trial-001 --note "初期状態"   # → ベンチを実行
scripts/measure.sh stop trial-001
scripts/measure.sh result trial-001 --pass true --score 1234
scripts/report.sh trial-001 && cat results/trial-001/context.md
scripts/evidence.sh sql trial-001 --limit 10
scripts/compare.sh trial-000 trial-001
```

当日の流れは [docs/environment-template.md](docs/environment-template.md) に構成を記録しながら進めます。
配布・復旧・再起動試験・終了前の確認は [docs/operations.md](docs/operations.md) を参照してください。

| ドキュメント | 内容 |
| --- | --- |
| [docs/first-hour.md](docs/first-hour.md) | 競技開始後の確認・初期ベンチ・計測導入 |
| [docs/environment-template.md](docs/environment-template.md) | 当日の構成を記録する雛形 |
| [docs/measurement.md](docs/measurement.md) | 計測方法、出力の見方、次に調べる箇所の決め方 |
| [docs/operations.md](docs/operations.md) | 配布・反映・復旧・初期化・再起動試験・終了前の確認 |
| [docs/agent-workflow.md](docs/agent-workflow.md) | CLI エージェントへの受け渡し・段階的な調査・実験比較・引き継ぎ |

## 設計と、その理由

- **設定は Bash 形式の 1 ファイル（`config/isucon.conf`）にしました。** YAML や JSON にすると、パーサーとして yq や jq の拡張機能が必要になります。Bash の配列・連想配列なら追加の依存がありません。一方で、設定ファイルは `source` されます。**信頼できる内容だけを書くファイル**として扱い、Git 管理外にしています。関数の中で読み込むため、`declare` には `-g` が必要です。`-g` を付け忘れた場合は検出してエラーにします。
- **集計は awk、JSON は jq で処理し、Python などには依存しません。** どの PC でも動くようにするためです。awk は POSIX の範囲だけを使い、macOS の awk と GNU awk の両方で動くようにしています。
- **リモートで実行する処理は `scripts/remote/*.sh` にまとめました。** 手元から `ssh HOST "env K='V' bash -s"` の標準入力として渡します。サーバー側にスクリプトを置く必要がなく、値はシングルクォートでクォートしてから渡します。`eval` は使いません。
- **SSH のホスト鍵検証は無効にしません。** `~/.ssh/config` と `known_hosts` をそのまま使います。
- **終了コードは 0=成功、1=処理失敗（一部のホストだけの失敗も含む）、2=引数・設定の誤り です。** 複数ホストを対象にした場合は、ホストごとの OK/FAIL を表示します。
- **デプロイは対象ごとに入口を分けました。** アプリを配布したついでに MySQL を再起動する、といったことが起きないようにするためです。どの入口も、扱うのは設定に書いたファイルとサービスだけです。
- **計測中のホストへの配布は拒否します。** 対象ホスト上のロック（`mkdir` による排他）を、deploy と measure で共有しています。複数の手元 PC から操作しても、ロックは対象ホスト側で判定されます。
- **出力量には上限があります。** 画面に出す調査結果は UTF-8 のバイト数で制限します（既定は 16 KiB、上限は 64 KiB。`--max-bytes` で変更可能）。省略した場合は、その旨と続きの取得方法を表示します。全文はファイルに保存します。
- **計測結果は、実行IDごとのローカルのディレクトリで受け渡します**（`results/<run-id>/`）。人と機械の入口（`context.md`）、機械処理用の集計（`metrics.json` / `manifest.json`）、元データ（`raw/`）を分けています。特定の AI サービスや MCP、LLM API には依存しません。入口は LLM の要約ではなく固定テンプレートで作るので、観測した事実だけが載ります。
- **集計は awk のストリーム処理で、対象データ全体に対して行います。** 表示の件数・バイト数の上限は、順位付けの母数に影響しません。巨大なログもメモリに展開しません。

## ディレクトリ

```
config/            設定例（isucon.conf.example）。実際の設定 isucon.conf は Git 管理外
config/hooks/      ビルド手順などの信頼するローカルフック（*.example をコピーして使う）
scripts/           手元で実行する入口
scripts/deploy/    app / nginx / mysql の配布
scripts/lib/       共通処理（設定読み込み・SSH・出力上限）
scripts/remote/    SSH 越しに対象ホストで実行される処理
templates/         nginx のログ形式、MySQL のスロークエリ設定、Go の pprof の組み込み例、AGENTS.md と実験メモの雛形
scripts/lib/awk/   集計（API・SQL・リソース）と ID 生成・URL グルーピング・SQL 正規化
experiments/       実験メモ（templates/experiment.md をコピーして作る）
Makefile           よく使う操作のメニュー
docs/              人向けの手順書
results/           調査・計測の結果（Git 管理外）
.gitignore         このディレクトリ用の除外設定（設定・結果・認証情報）
```

## テスト

テスト（`tests/`）はローカルで確認するためのもので、Git では管理していません（`.gitignore` で除外）。
モック（ssh・sudo・systemctl など）を使った確認であり、**実サーバーでの動作確認ではありません。**
