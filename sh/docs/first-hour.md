# 競技開始後の最初の1時間

コマンドは `sh/` で実行します。**最初に当日のマニュアルとレギュレーションを読みます。**

## 0〜10 分: マニュアルと接続

- [ ] マニュアルを読み、以下をメモする
  - 禁止事項
  - 再起動試験の有無
  - ベンチの実行方法
  - 初期化エンドポイント（例: `POST /initialize`）とその制限時間
  - 終了時刻
- [ ] `~/.ssh/config` に各サーバーを書き、`ssh isu1 true` が通る
- [ ] 役割を決める（例: アプリ担当 / インフラ・計測担当 / DB 担当）。**ベンチを回す人を1人に決め、「ベンチ開始」「ベンチ終了」を宣言する**

## 10〜25 分: 構成を調べて env.mk を埋める

1回しか使わないので、コマンドを直接打ちます。

```bash
ssh isu1 'uname -m; nproc; free -h; df -h /'                       # CPU アーキテクチャ（GOARCH）・コア数・メモリ・ディスク
ssh isu1 'systemctl list-units --type=service --state=running --no-pager | grep -v systemd'   # サービス名
ssh isu1 'sudo ss -tlnp'                                           # 待ち受けポートとプロセス
ssh isu1 'systemctl cat isu-go'                                    # ExecStart（バイナリの場所）・WorkingDirectory・環境変数
ssh isu1 "sudo nginx -T | grep -E '# configuration file|access_log|proxy_pass|root'"   # nginx の設定ファイルとログの場所
ssh isu1 "mysqld --version; mysqld --verbose --help | grep -A1 'Default options'"     # MySQL のバージョンと設定ファイルの読み込み順
ssh isu1 "sudo mysql -e 'SHOW DATABASES; SELECT @@slow_query_log_file'"
```

```bash
cp env.example.mk env.mk && $EDITOR env.mk     # 上の結果でホスト・サービス名・パス・GOARCH を埋める
make status
```

## 25〜35 分: 初期状態を残す

- [ ] 競技アプリのソースをサーバーから取得し、Git にコミットする（例: `scp -r isu1:/home/isucon/webapp ../webapp`）。**この時点のコミットを記録する**
- [ ] サーバーの設定を手元に取得してコミットする
  ```bash
  make fetch-conf && git add conf && git commit -m "初期設定"
  ```
- [ ] **初期状態のベンチを実行し、スコアを記録する**（計測の設定を入れる前の値）

## 35〜50 分: 計測の準備

```bash
make setup                     # サーバーに htop / sysstat（任意）
brew install alp percona-toolkit   # 手元（未導入なら）
```

- [ ] nginx: `templates/nginx-ltsv.conf` の `log_format` と `access_log` を、`conf/etc/nginx/nginx.conf` の `http { }` 内に貼る。server ブロックにある `access_log` も `ltsv` にそろえる → `make deploy-nginx`
- [ ] MySQL: `make slow-on` → `make restart`（アプリの既存の DB 接続に設定を効かせるため）
- [ ] pprof（使う場合）: `templates/pprof.go` をアプリに入れ、systemd の環境変数に `ISU_PPROF=127.0.0.1:6060` を設定する → `make deploy`
- [ ] `env.mk` の `ALP_MATCH` に、ID を含む URL のパターンを追加する（アプリのルーティングを見る）

## 50〜60 分: 計測ありのベースライン

```bash
make pre RUN=00-baseline
# ベンチを実行（ベンチ中に別のターミナルで make pprof）
make analyze
$EDITOR results/00-baseline/memo.md   # スコアを書く
```

- [ ] `alp.txt` と `slow.txt` に中身がある（空なら、ログの形式やスロークエリログの設定を確認）
- [ ] 計測あり・なしのスコア差を記録した（計測の負荷の目安）
- [ ] 合計時間の上位から、最初に取り組む候補を決めた

以降は「1つ変更 → コミット → `make deploy` → `make pre RUN=...` → ベンチ → `make analyze` → memo.md」を繰り返します。
