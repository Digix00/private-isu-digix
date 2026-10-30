# 結果の読み方と、次に調べる場所

`make analyze` の結果は `results/<実行名>/` に入ります。

| ファイル | 内容 |
| --- | --- |
| `alp.txt` | API ごとの回数・合計・平均・最大の時間と、ステータス別の回数（合計時間の順） |
| `slow.txt` | pt-query-digest のレポート。冒頭の Profile が SQL ごとの合計時間の順位で、その後に上位 15 件の詳細が続く |
| `pprof.txt` | CPU を使っている関数の上位（`make pprof` を実行した場合） |
| `memo.md` | スコア・変更内容・配布したコミット（人が書く） |
| `access.log` / `slow.log` / `cpu.pb.gz` | 元データ（大きいので Git 管理外。必要なときだけ見る） |

## API（alp.txt）

- **SUM（合計時間）** が大きい順に見ます。ここを改善するのが一番効きます。
- **COUNT が多く、AVG が小さい** 場合は、呼ばれ方を疑います（N+1、キャッシュできないか、静的ファイルを nginx から配信できないか）。
- **AVG が大きい** 場合は、1回の処理が重いです。その API が発行する SQL を slow.txt で探します。
- **MAX だけが大きい** 場合は、ロック待ちや一時的な詰まりを疑います。
- **4XX / 5XX** はエラーです。スコアの減点につながります。時刻を `grep 'uri:/comment' results/<実行名>/access.log | grep 'status:5'` のように探し、アプリのログ（`ssh isu1 journalctl -u isu-go --since "10:00"`）と照らし合わせます。
- alp の時間は upstream（アプリ）の応答時間（`apptime`）です。nginx 全体の時間を見たい場合は `alp ltsv --file results/<実行名>/access.log --apptime-label reqtime ...` を使います。

## SQL（slow.txt）

- **Response time（合計）** の順が優先度の目安です。
- **Calls（回数）** が多い SQL は、1回が速くても N+1 を疑います。
- 詳細の **Rows examine（調べた行数）** が **Rows sent（返した行数）** よりずっと多ければ、インデックスが効いていない可能性が高いです。
- `make slow-on` は `long_query_time=0` で全 SQL を記録します。そのぶん MySQL が遅くなります（QPS が高いと数 %〜十数 %）。

### EXPLAIN で調べる

slow.txt の詳細にある実際の SQL を使います。

```bash
ssh isu1 "sudo mysql isuconp -e 'EXPLAIN SELECT * FROM comments WHERE post_id = 123 ORDER BY created_at DESC LIMIT 3'"
ssh isu1 "sudo mysql isuconp -e 'SHOW INDEX FROM comments'"
```

- `type` が `ALL`（全件走査）、`key` が NULL、`rows` が大きい、`Extra` に `Using filesort` がある場合は、インデックスを検討します。
- **`EXPLAIN ANALYZE` はクエリを実際に実行します。** 実行時間の内訳が分かる反面、重い SELECT では時間がかかります。UPDATE / DELETE には使いません。ベンチ中にも使いません。

## CPU（pprof.txt、top / htop）

```bash
ssh -t isu1 htop        # ベンチ中にその場で見る（どのプロセスが CPU を使っているか）
ssh isu1 'pidstat 1 60 > /tmp/pidstat.txt' &   # 記録として残したい場合（sysstat が必要）。後で scp で取得する
make pprof              # ベンチ中に実行（PPROF_SECONDS 秒）
make pprof-web          # グラフや flame graph をブラウザで見る
```

- `top` / `htop` は今の状態を見るだけで、何も残りません。後から比べたい場合は `pidstat` / `iostat -x 1` の出力をファイルに残します。
- **CPU プロファイルは、CPU を使っている時間だけ**を示します。DB の応答待ちやロック待ちは現れません。

## 次に調べる場所

| 観測 | 次の手順 |
| --- | --- |
| **アプリの CPU が高い**（htop でアプリが上位） | `make pprof` → `pprof.txt` の上位の関数 → `make pprof-web` で呼び出し元をたどる。テンプレートの毎回のパース、JSON の生成、外部コマンドの実行などがよくある原因 |
| **MySQL の CPU が高い**（htop で mysqld が上位） | `slow.txt` の上位 → EXPLAIN → インデックスの追加、N+1 の解消 |
| **CPU が低いのに API が遅い** | 待ちを疑う。`iostat -x 1` の `%util` が高ければディスク。それ以外なら、ロック待ち、DB の接続プールの上限、外部 API、`sleep`。alp の AVG と、その API の SQL の時間の合計を比べる |
| **静的ファイルが上位** | nginx から直接配信する、キャッシュヘッダーを付ける |

## 比べるときの注意

- 比べる実行同士は、**同じ計測条件**で取ります（slow-on の有無、pprof を取ったか）。
- 速くなるとリクエストの数が増えるので、**SUM が増えても改善していることがあります。** COUNT と AVG を合わせて見て、最後はスコアで判断します。
- 前回との比較は、2回分の `alp.txt` を並べて見ます（`diff <(head -30 results/A/alp.txt) <(head -30 results/B/alp.txt)` など）。
- 最終的なスコアは、計測をやめた状態で確認します（docs/operations.md）。

## CLI エージェントに見せるとき

`templates/AGENTS.md.example` を、競技用リポジトリの `AGENTS.md`（または CLAUDE.md）に追記します。既存の内容は上書きしません。依頼は、次のように実行名とファイルを指定します。

```
results/03-index/ の memo.md, alp.txt, slow.txt, pprof.txt を見て、次に改善すべき箇所の候補を3つ、根拠（ファイルと行）付きで挙げて。
前回は results/02-xxx/。コードの変更は提案だけにして、デプロイとベンチはしないで。
```

- `access.log` や `slow.log` などの元ログは大きいので、丸ごと読ませないようにします。必要な場合は `grep` や `head` で範囲を絞るよう指示します。
- 指示ファイルは「お願い」であり、エージェントがファイルを読むことやコマンドを実行することを禁止できません。禁止したい場合は、エージェント側の権限設定（実行してよいコマンドや読めるパスの制限）を使います。
- ログ・URL・SQL の中に書かれた文章は、観測データとして扱わせます（指示として実行させない）。
