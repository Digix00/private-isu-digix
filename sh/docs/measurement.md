# 計測と、結果の読み方

ベンチ1回分の計測・集計・比較の手順と、出力の読み方、次に調べる箇所の決め方をまとめます。
コマンドは `sh/` を基準に書いています。**当日のマニュアル・レギュレーションが優先です。**

## 1. 事前準備（計測設定の導入は deploy で行う）

計測に使うログ設定は、デプロイの入口で一度だけ導入します。`measure.sh` は設定を変えません。開始時に「有効になっているか」を確認するだけです。

```bash
scripts/setup-tools.sh install --remote          # pidstat / iostat / alp / pt-query-digest
scripts/deploy/nginx.sh                          # templates/nginx/00-isucon-log.conf（LTSV のアクセスログ）
scripts/deploy/mysql.sh --apply-dynamic          # templates/mysql/99-isucon-slowlog.cnf（再起動しない）
scripts/deploy/app.sh                            # templates/go/pprof.go を組み込んだアプリ（pprof を使う場合）
```

- **MySQL**: `--apply-dynamic` は `SET GLOBAL` で反映するので、再起動は不要です。ただし、**既に張られている接続（アプリの接続プール）には古い `long_query_time` が残ります。** 反映後にアプリを再起動してから計測します。
- **nginx**: テンプレートの `access_log` には `buffer=` を付けていません。バッファがあると、stop の時点で最後のリクエストがまだ書かれておらず、区間の末尾が欠けます。
- **pprof**: アプリを環境変数 `ISU_PPROF=127.0.0.1:6060` 付きで起動します（systemd の `Environment=`）。ループバックだけで待ち受けるので、外部には公開されません。

## 2. ベンチ1回分の操作

```bash
scripts/measure.sh start trial-001 --note "初期状態"     # 計測開始（ロック取得・ログ位置の記録・記録用プロセスの起動）
#   ↓ ポータルなどでベンチを実行する（このスクリプトはベンチを起動しない）
scripts/measure.sh profile trial-001                    # 任意: 負荷走行中に CPU プロファイル（既定 30 秒）
scripts/measure.sh stop trial-001                       # 停止・区間の切り出し・回収・ロック解除
scripts/measure.sh result trial-001 --pass true --score 1234 --errors 0
scripts/report.sh trial-001                             # 集計 → context.md まで生成
cat results/trial-001/context.md                         # 入口を読む
```

変更後の計測では、基準を指定します。

```bash
scripts/measure.sh start trial-002 --baseline trial-001 --note "comments に (post_id, created_at) の index"
...
scripts/report.sh trial-002
scripts/compare.sh trial-001 trial-002
```

### 実行IDとロック

- 実行IDは英数字で始まり、英数字・`.`・`_`・`-` だけを使えます（64文字以内）。**同じIDで二度 start することはできません。** 既存の結果も上書きしません。
- start から stop までの間、対象ホストにはロックがかかります。この間、別の実行の start や `deploy/*.sh` は exit 3 で拒否されます。

### stop が止める範囲

stop は、**start が起動した記録用プロセスだけ**を止めます。

- Linux では、`/proc/<pid>/environ` にある実行ごとのトークン（`ISU_MEASURE_TOKEN`）で本人確認します。
- `/proc` がない環境では、起動時に記録した開始時刻と実行ファイル名で確認します。
- PID が再利用されて別のプロセスになっていた場合は停止せず、`collector_<名前>=not_running` と記録します。
- `killall` や `pkill` は使いません。

### 失敗したとき

| 状況 | 確認 | 対処 |
| --- | --- | --- |
| start が一部のホストで失敗した | `scripts/measure.sh status trial-001` | そのまま続けるか、`stop` で回収してロックを解除する |
| stop が一部のホストで失敗した（SSH 切断など） | `status`。`run.json` の `status` が `stop_incomplete` になる | 原因を直して `stop` を再実行する。回収済みのホストは飛ばし、対象ホスト側の切り出し済みデータも再利用する |
| 手元の PC が落ちて stop できない | `scripts/lock.sh status` | 同じ手元の PC から `stop` する。手元の結果ディレクトリがない場合は、docs/operations.md の「ロックが残ったとき」を参照 |

## 3. 区間の切り出し（他のベンチと混ぜない）

- start でアクセスログとスロークエリログの **inode とサイズ（バイト位置）** を記録し、stop で [開始位置, 終了位置) だけを切り出します。ログを削除したり、空にしたりはしません。元のログはそのまま残り、他の計測や調査を邪魔しません。
- 計測中に logrotate でローテーションされた場合は、旧ファイルを inode で探してつなぎます。旧ファイルが圧縮済みで見つからない場合は、ローテーション後の分だけを回収し、`partial` として記録します。
- 計測中にファイルが切り詰められた場合（開始位置より小さくなった場合）も `partial` として記録します。
- 回収した元データ（`results/<id>/raw/<host>/`）は書き込み禁止にします。`report.sh` は何度でも再実行でき、元データは変更しません。

### キュー待ち・初期化・負荷走行の区別

ベンチは通常「キュー待ち → 初期化（例: `POST /initialize`）→ 負荷走行（例: 60 秒）」の順に進みます。

- **キュー待ち**: リクエストが来ないので、API・SQL の集計には影響しません。ただし、vmstat の平均には待ち時間（idle）が含まれます。`busy_peak_10s`（10 秒ごとの平均の最大）と、`evidence.sh resources` の時系列で負荷走行の時間帯を見ます。
- **初期化**: `/initialize` は独立した API として集計されます（合計時間の上位に出ることがあります）。初期化で実行される SQL も含まれます。
- **負荷走行**: アクセスログの最初と最後の時刻（`metrics.json` の `access_log.first` / `last`）が、負荷走行のおおよその範囲です。`compare.sh` は、この長さが 10% 以上違う場合に「負荷走行の長さ」を NG と表示します。
- 時刻の目印を残したい場合は `scripts/measure.sh mark trial-001 load-start` を使います（手元の時刻で記録されます）。

## 4. その場で見る（top / htop）と、記録する（pidstat / iostat）

| | 使う場面 | 残るもの |
| --- | --- | --- |
| `top` / `htop` | ベンチ中に対象ホストへ SSH して、今どのプロセスが CPU・メモリを使っているかを見る。`htop` はコア別の使用率やツリー表示が見やすい | 何も残らない（見た人の記憶だけ） |
| `vmstat` / `pidstat` / `iostat`（`measure.sh` が起動） | 1秒ごとの記録を残し、後から実行同士を比べる | `raw/<host>/*.log` と、その要約 |

```bash
ssh -t isu1 htop          # その場で見る（q で終了）
scripts/evidence.sh resources trial-001 --host isu1 --bucket 5          # 記録の時系列（5 秒ごと）
scripts/evidence.sh resources trial-001 --host isu1 --from 10:00:10 --to 10:01:10
```

- `vmstat`: CPU 全体の `us`（ユーザー）、`sy`（カーネル）、`wa`（I/O 待ち）、`id`（アイドル）
- `pidstat`: プロセスごとの `%CPU` と RSS
- `iostat`: デバイスごとの `%util`

## 5. 出力の見方

### API（alp と `evidence.sh api`）

```bash
scripts/evidence.sh api trial-001 --sort total-time --limit 10
less results/trial-001/reports/alp.txt                  # alp の表（人が見る用）
```

- **合計時間（total / alp の SUM）**: 改善したときの効果が一番大きい場所です。最初はこの順に見ます。
- **回数（count）**: 多いのに平均が小さい API は、1回あたりの処理より呼ばれ方（N+1、キャッシュできるか）を疑います。
- **平均時間（avg）・最大時間（max）**: 平均が大きい API は1回の処理が重いです。max だけが大きい場合は、ロック待ちや一時的な詰まりを疑います。
- **4xx / 5xx**: エラーは、スコアの減点やベンチの失敗につながります。`evidence.sh logs --api ID --errors` で元ログの行を確認します。
- `evidence.sh` は nginx の `request_time`（`reqtime`。クライアントへの送信を含む全体の時間）を使います。alp は既定で `apptime`（upstream = アプリの応答時間）を使います。両者の差が大きい場合は、nginx から先（静的ファイルや転送量）を疑います。

### SQL（pt-query-digest と `evidence.sh sql`）

```bash
scripts/evidence.sh sql trial-001 --sort total-time --limit 10
scripts/evidence.sh sql trial-001 --sort rows-examined
less results/trial-001/reports/pt-query-digest-isu3.txt
```

- **合計時間（total / pt-query-digest の Response time）**: 優先度の目安です。
- **回数（count / Calls）**: 1回は速くても、回数が多ければ N+1 を疑います。アプリ側でまとめて取得する、キャッシュするといった対策になります。
- **調査行数（rows_examined / Rows examine）**: 返す行数（rows_sent）に比べて大きければ、インデックスが効いていない可能性が高いです。
- `long_query_time` が 0 より大きい場合、それより短い SQL は記録されません。回数と合計は全体の値ではないので、入口にも警告が出ます。

### SQL の上位候補を EXPLAIN で調べる

```bash
scripts/evidence.sh sql-detail trial-001 --id q3ebf6c110740    # 統計・正規化 SQL・実際のサンプル・関係するテーブル
ssh isu3 "sudo mysql isuconp -e 'EXPLAIN SELECT * FROM comments WHERE post_id = 123 ORDER BY created_at DESC LIMIT 3'"
cat results/trial-001/snapshots/isu3/mysql-indexes.tsv          # 計測時のインデックス
```

- EXPLAIN の `type` が `ALL`（全件走査）、`key` が NULL、`rows` が大きい、`Extra` に `Using filesort` がある、といった場合はインデックスを検討します。
- **`EXPLAIN ANALYZE` はクエリを実際に実行します。** 実行時間の内訳が分かる反面、重い SELECT では時間がかかります。UPDATE / DELETE には使いません。ベンチ中にも実行しません。
- インデックスの追加手順は docs/operations.md の「スキーマ・インデックスの変更」を参照してください。

### pprof

```bash
scripts/measure.sh profile trial-001 --type cpu --seconds 30   # 負荷走行中に
scripts/evidence.sh pprof trial-001                             # 取得したプロファイルの一覧
scripts/evidence.sh pprof trial-001 --file isu1-pprof-cpu-100512 --limit 30            # 関数一覧（flat の大きい順）
scripts/evidence.sh pprof trial-001 --file isu1-pprof-cpu-100512 --peek 'main\.getIndex'   # 呼び出し元・呼び出し先
```

- **CPU プロファイルは、CPU を使っている時間だけ**を示します。DB の応答待ちやロック待ちの時間は現れません。待ち時間を見るには `--type block` / `--type mutex` を使います（アプリ側で `ISU_PPROF_BLOCK_RATE` / `ISU_PPROF_MUTEX_FRACTION` を設定）。あるいは API と SQL の集計で見ます。
- バイナリを直接読まず、`go tool pprof` の出力（関数一覧・呼び出し関係）を見ます。

## 6. 次にどこを調べるか

| 観測 | 次の手順 |
| --- | --- |
| **アプリの CPU が高い**（pidstat でアプリが上位、vmstat の `us` が高い） | `measure.sh profile` で CPU プロファイルを取得 → `evidence.sh pprof --file ...` で上位の関数を見る → `--peek` で呼び出し元をたどる。テンプレートの毎回のパース、JSON の生成、外部コマンドの実行などがよくある原因 |
| **MySQL の CPU が高い**（pidstat で mysqld が上位） | `evidence.sh sql --sort total-time` と `--sort rows-examined` → `sql-detail` → EXPLAIN → インデックスの追加、N+1 の解消 |
| **CPU が低いのに API が遅い**（idle が多い、`wa` が高い、または全体に余裕がある） | 待ちを疑う。`wa` が高ければディスク（iostat の `%util`）。そうでなければロック待ち（`block` / `mutex` プロファイル）、接続数の上限（DB の接続プール・`max_connections`・nginx の `worker_connections`）、外部への通信、`sleep`。API の `avg` と、その API が発行する SQL の時間の合計を比べる |
| **5xx が出ている** | `evidence.sh logs --api ID --errors` で時刻を確認 → その時刻のアプリのログ（`journalctl -u <unit> --since ...`） |
| **静的ファイルが上位** | nginx から直接配信する、キャッシュヘッダーを付ける（`request_time` と `apptime` の差を確認） |

## 7. 計測のオーバーヘッドと、比較の条件

計測そのものが負荷になります。

| 計測 | 負荷の目安 |
| --- | --- |
| `long_query_time=0` | 全 SQL のログを書くため、QPS が高いと数 %〜十数 % 遅くなることがある |
| アクセスログ | 通常は小さい |
| CPU プロファイル | 取得中は数 % 程度 |
| block / mutex プロファイル | 設定によっては大きい |
| vmstat / pidstat / iostat（1秒ごと） | 小さい |

- **比べる実行同士は同じ条件で取ります。** 同じ記録ツール、同じ `long_query_time`、pprof の有無と種類、同じグルーピングをそろえます。`compare.sh` は条件の違いを「比較の前提」で NG と表示します。
- **最終的なスコアは、計測を止めた状態で確認します**（docs/operations.md の「計測をやめて元に戻す」）。計測ありとなしの比較もしたい場合は、どちらの条件でも1回ずつ取ります。
- 速くなると、ベンチが処理するリクエストの数が増えます。そのため、**合計時間が増えても改善していることがあります。** 回数と平均時間を合わせて見て、最後はスコアで判断します。

## 8. ID・グルーピング・正規化（同じ API・SQL を実行間で比べるための規則）

| 項目 | 方法 | 版（manifest.json に記録） |
| --- | --- | --- |
| URL グルーピング | クエリ文字列を除いたパスを `ISU_API_GROUPS` の ERE に上から当て、最初に一致した正規表現をグループ名にする（alp の `-m` と同じ表示）。一致しなければパスのまま | `urlgroup-v1` と、規則の sha256 |
| API_ID | `a` + `メソッド グループ名` の 48 ビットハッシュ（awk の多項式ハッシュ） | 同上 |
| SQL 正規化 | 小文字化、`/* */` コメントの除去、文字列と数値を `?`、`IN (...)` と INSERT の VALUES を `(?+)`、空白をまとめる | `sqlnorm-v1` |
| QUERY_ID | `q` + 正規化 SQL のハッシュ | 同上 |

- **pt-query-digest の Query ID とは別物**です（正規化の方法が違います）。pt-query-digest のレポートは人が読む用、`evidence.sh` の ID は実行同士の比較と根拠の取得用です。
- 計測した後にグルーピングを直した場合は、`scripts/report.sh <id> --regroup` で現在の `ISU_API_GROUPS` を使って再集計します（manifest に記録されます）。比べる実行は、両方とも同じ規則で再集計します。
