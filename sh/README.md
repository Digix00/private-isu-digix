# ISUCON 当日用ツール

ISUCON の改善ループ（変更 → 配布 → ベンチ → 集計 → 次の改善）を、短いコマンドで回すための Makefile と手順書です。
`sh/` ディレクトリごと、競技用のリポジトリへコピーして使えます。**当日のマニュアル・レギュレーションが、この手順より優先です。**

## 何度も使うコマンド

```bash
make help            # 一覧
make deploy          # アプリを手元でビルド → 配布 → 再起動（前のバイナリは .prev に残る）
make pre             # ベンチ前: ログを退避して、前回のベンチと混ざらないようにする
#   → ポータルなどでベンチを実行（ベンチ中に CPU を見たいなら make pprof）
make analyze         # ベンチ後: ログを回収して results/<実行名>/ に alp.txt と slow.txt を作る
$EDITOR results/<実行名>/memo.md   # スコアと変更内容を書く
```

| コマンド | 使う場面 |
| --- | --- |
| `make deploy` / `make rollback` / `make restart` | アプリの配布、直前のバイナリへの戻し、再起動 |
| `make pre` → ベンチ → `make analyze` | ベンチ1回分の計測と集計。実行名は `make pre RUN=index追加` のように付けられる（省略すると時刻になる） |
| `make pprof` / `make pprof-web` | ベンチ中に CPU プロファイルを取得し、上位の関数を `pprof.txt` に保存する / ブラウザで見る |
| `make deploy-nginx` / `make deploy-mysql` | `conf/` の設定を配置する。nginx は `nginx -t`、MySQL は `mysqld --validate-config` が通った場合だけ反映し、失敗したら元に戻す |
| `make slow-on` / `make slow-off` | スロークエリログの有効化・無効化（MySQL は再起動しない） |
| `make status` | 各ホストのサービスの active / enabled と、HTTP 応答の確認 |
| `make fetch-conf` / `make setup` | 最初に1回: サーバーの設定を `conf/` に取得する / サーバーに htop と sysstat を入れる |

実行前に中身を確認するには `make -n deploy` のようにします（コマンドを表示するだけで、実行しません）。

## 初期設定

```bash
cp env.example.mk env.mk       # 当日の構成（ホスト名・サービス名・パス）を書く。Git 管理外
$EDITOR env.mk                 # TODO(当日) の項目を埋める
make status                    # つながるか確認
```

- `~/.ssh/config` に各サーバーの Host を書き、パスワードなしで `ssh isu1` できるようにしておきます。
- サーバー上で `sudo` がパスワードなしで使えることを前提にしています。

## 必要なもの

| 場所 | 必要なもの | 導入例（macOS） |
| --- | --- | --- |
| 手元 | make、ssh、go（ビルドと pprof の解析） | 標準の make（3.81）で動きます |
| 手元 | [alp](https://github.com/tkuchiki/alp)、pt-query-digest | `brew install alp percona-toolkit` |
| サーバー（Ubuntu） | sudo、systemd、curl。あると良いもの: htop、sysstat | `make setup` |

集計（alp / pt-query-digest）は手元で行うので、サーバーには入れなくてかまいません。

## ファイル

```
Makefile           コマンドの本体（1ターゲット数行。読めば何をするか分かる）
env.example.mk     設定の例（env.mk にコピーして使う）
conf/              make fetch-conf で取得したサーバーの設定（サーバーと同じパスで置く。コミットする）
templates/         nginx の LTSV ログ形式、Go の pprof 組み込み例、エージェント向け指示の例
results/<実行名>/  memo.md alp.txt slow.txt pprof.txt（コミットしてよい）と、元ログ（Git 管理外）
docs/              first-hour.md（最初の1時間）/ analysis.md（結果の読み方）/ operations.md（配布・戻し・終了前）
```

## 設計の方針

- **繰り返す操作だけをコマンドにしています。** 構成の調査や再起動試験など、1回しか行わないものは docs にコマンドを書いています。
- **集計は既存のツールに任せています。** alp と pt-query-digest の出力は、それ自体が要約です。エージェントにもそのまま読ませます（docs/analysis.md）。
- **前回のベンチとログを混ぜない方法は「退避して開き直させる」です。** `make pre` は、ログを `<名前>.<時刻>` に rename してから `nginx -s reopen` / `FLUSH SLOW LOGS` を実行します。書き込み中のファイルを削除したり空にしたりはしません。
- **ベンチ中に配布しない、という約束はチームで守ります。** 仕組みでは止めないので、「ベンチ開始」「ベンチ終了」をチャットで宣言します。
