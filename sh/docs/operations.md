# 運用手順（配布・反映・復旧・再起動試験・終了前の確認）

人が実際に行う操作と、そのときに実行するコマンドをまとめます。**当日のマニュアル・レギュレーションが優先です。**
初期化処理や再起動試験の条件は、当日のマニュアルで確認してください。

## 0. チームの約束

- **ベンチ中はデプロイ・設定変更・再起動をしない。** 結果が混ざり、何の効果か分からなくなります。
  - 計測中（`measure.sh start` から `stop` まで）は、対象ホストにロックがかかります。この間、`deploy/*.sh` は exit 3 で拒否されます。
  - ロックで防げるのは、このスクリプトを経由した操作だけです。手で `systemctl restart` や `vim /etc/nginx/...` をすると防げません。ベンチを始める前にチャットで「ベンチ開始」「ベンチ終了」と宣言します。
- **変更は1回に1つ。** アプリ・nginx・MySQL は入口を分けています。アプリを配布しても MySQL は再起動されません。
- **変更はまず Git にコミットしてから配布する。** `app.sh` は未コミットの差分があっても配布できますが、警告を出し、差分のハッシュを記録します。後から「どのコードで計測したか」を特定するためです。
- **戻すときは `git revert` → 再デプロイ が基本。** すぐに戻したい場合だけ、下の「復旧」の手段を使います。

## 1. アプリの配布（`scripts/deploy/app.sh`）

準備（初回だけ）:

```bash
cp config/hooks/build-app.sh.example config/hooks/build-app.sh
chmod +x config/hooks/build-app.sh
$EDITOR config/hooks/build-app.sh      # ビルド方法を当日のリポジトリに合わせる
$EDITOR config/isucon.conf             # ISU_APP_SRC_DIR, ISU_APP_REMOTE_BIN, ISU_APP_GOARCH など
```

配布:

```bash
scripts/deploy/app.sh --dry-run        # 対象ホストと手順の確認（ビルド・SSH は行わない）
scripts/deploy/app.sh                  # app 役の全ホストへ
scripts/deploy/app.sh --host isu1      # 1台だけ
scripts/verify.sh                      # 配布後の確認
```

`app.sh` は次の順に処理します。

1. 手元でビルドします。ビルドフックが失敗した場合や、成果物の形式（ELF / CPU）がサーバーと合わない場合は、ここで止まります。
2. ロックを取得します。計測中のホストが1台でもあれば、どのホストにも配布しません。
3. 転送して sha256 を照合し、今のバイナリを `<bin>.prev` に退避してから、rename で切り替えます。
4. `ISU_APP_SERVICE` だけを再起動し、`ISU_APP_CHECK_URL` が期待するステータスを返すまで確認します。

手元とサーバーの OS・CPU について:

| 手元 | サーバー | CGO | 対応 |
| --- | --- | --- | --- |
| macOS (arm64/amd64) | linux/amd64・arm64 | 0（使わない） | 対応（Go のクロスコンパイル） |
| linux/amd64 | linux/amd64 | 0 / 1 | 対応 |
| 手元とサーバーが別の OS・CPU | | 1（使う） | **非対応**（エラーで止まる）。サーバーと同じ OS・CPU の環境でビルドするか、CGO を使わない構成にする |

ビルドがサーバー上でしかできない構成（CGO が必須など）の場合は、`build-app.sh` を書き換えます。例えば、サーバーと同じ構成の作業用ホストで `ssh` を使ってビルドし、成果物を `$OUT` に取ってくるようにします。

### 復旧（アプリ）

```bash
scripts/deploy/app.sh --rollback --host isu1    # <bin>.prev に戻して再起動
```

`.prev` に残っているのは直前の1世代だけです。それより前に戻す場合は `git revert` してから再配布します。
配布したコミットは、対象ホストの `/var/tmp/isu-prep/deployed-app.env` に記録されています（`cat` で確認できます）。

## 2. nginx 設定の配布（`scripts/deploy/nginx.sh`）

**管理するファイルは、`ISU_NGINX_FILES` に書いたものだけです。** 既存の `/etc/nginx` 全体は上書きしません。

最初に、今の設定をリポジトリに取り込みます。

```bash
ssh isu1 'sudo cat /etc/nginx/sites-available/isucon.conf' > config/nginx/isucon.conf   # 例（当日の構成に合わせる）
git add config/nginx && git commit -m "nginx: 初期設定を取り込み"
```

`config/isucon.conf` の `ISU_NGINX_FILES` に `"config/nginx/isucon.conf:/etc/nginx/sites-available/isucon.conf"` を追加します。アクセスログの形式を変えるには `templates/nginx/00-isucon-log.conf` も追加します（初期値で入っています）。

```bash
scripts/deploy/nginx.sh --dry-run
scripts/deploy/nginx.sh
```

`nginx.sh` は次の順に処理します。

1. 既存のファイルを `/var/tmp/isu-prep/backup/nginx-<時刻>/` に退避し、差分を表示してから配置します。
2. **新しいファイルを置いた状態で** `nginx -t` を実行します。nginx は include も含めて、実際に読み込む設定一式を検証します。失敗した場合はファイルを元に戻し、reload しません。
3. `nginx -T` に管理するファイルが現れるか（= include されているか）を確認します。現れなければ元に戻します。`sites-available` に置いただけで、`sites-enabled` へのリンクがない場合などがこれに当たります。
4. `systemctl reload` を実行し、HTTP 応答を確認します。

### 復旧（nginx）

検証に失敗した場合は自動で戻ります。reload した後で問題に気づいた場合は、`git revert` してから再配布します。急ぐ場合は、退避したファイルを手で戻します。

```bash
ssh isu1 'ls /var/tmp/isu-prep/backup/'                       # 退避した世代
ssh isu1 'cat /var/tmp/isu-prep/backup/nginx-<時刻>/MAP'       # ファイル名と配置先の対応（present=元からあった）
ssh isu1 'sudo cp -p /var/tmp/isu-prep/backup/nginx-<時刻>/f1 /etc/nginx/conf.d/00-isucon-log.conf && sudo nginx -t && sudo systemctl reload nginx'
```

## 3. MySQL 設定の配布（`scripts/deploy/mysql.sh`）

管理するファイルは `ISU_MYSQL_FILES` に書いたものだけです。初期値は `/etc/mysql/mysql.conf.d/99-isucon-slowlog.cnf` です。
Ubuntu の MySQL は `/etc/mysql/my.cnf` から `mysql.conf.d/*.cnf` を名前順に読み、後に読んだ値が優先されます。読み込み順は次のコマンドで確認します。

```bash
ssh isu3 "mysqld --verbose --help | grep -A1 'Default options'"
```

反映方法は、明示的に選びます。

```bash
scripts/deploy/mysql.sh                  # ファイルを置いて検証するだけ（稼働中の値は変えない）
scripts/deploy/mysql.sh --apply-dynamic  # 動的に変えられる変数だけ SET GLOBAL で反映（再起動しない）
scripts/deploy/mysql.sh --restart        # 再起動して反映（innodb_buffer_pool_size など静的な変数）
```

- 検証には `mysqld --validate-config` を使います。MySQL 8.0.16 以上が必要です。それより古い場合や MariaDB の場合は、配置を戻して中止します。
- 結果は変数ごとに、次の3つの列で表示されます。
  - **ファイル**: 配置したファイルの値
  - **稼働中**: `SELECT @@GLOBAL.x` の値
  - **再起動後**: `my_print_defaults mysqld` の値。後から読まれる別のファイルで上書きされていないかが分かる
- `SET GLOBAL` は**既存の接続のセッション値を変えません。** アプリの接続プールが張りっぱなしの接続は、古い `long_query_time` のままです。反映後にアプリを再起動するか（`deploy/app.sh` で再配布する、または `ssh isu1 sudo systemctl restart <app>`）、再接続されるまで待ちます。

### スキーマ・インデックスの変更（設定配布とは別に行う）

`mysql.sh` は、スキーマ変更・データ削除・初期化を行いません。インデックスの追加は、次の手順で人が行います。

1. **SQL をファイルにしてコミットする**: `sql/001-add-index-comments.sql`（例）
   ```sql
   ALTER TABLE comments ADD INDEX idx_post_id_created_at (post_id, created_at);
   ```
2. **初期化処理との整合を確認する**: ベンチの初期化（例: `POST /initialize`）がテーブルを作り直す場合、追加したインデックスは消えます。次のどちらかで対応します。
   - 初期化処理の中で、インデックスが存在しなければ作成する
   - 初期データの SQL（スキーマ定義）自体にインデックスを含める

   初期化の制限時間内に終わるかも確認します。
3. **適用する**（ベンチ中は行わない。大きなテーブルではロックや時間に注意）
   ```bash
   ssh isu3 'sudo mysql isuconp' < sql/001-add-index-comments.sql
   ```
4. **確認する**
   ```bash
   ssh isu3 "sudo mysql isuconp -e 'SHOW INDEX FROM comments'"
   ssh isu3 "sudo mysql isuconp -e 'EXPLAIN SELECT * FROM comments WHERE post_id = 1 ORDER BY created_at DESC LIMIT 3'"
   ```
5. **戻す**（逆の SQL も一緒にコミットしておく）
   ```sql
   ALTER TABLE comments DROP INDEX idx_post_id_created_at;
   ```

## 4. 異常終了したとき・ロックが残ったとき

デプロイや計測の途中で手元のコマンドが強制終了すると、対象ホストにロックが残ることがあります。

```bash
scripts/lock.sh status                       # 全ホストのロック（種類・実行ID・誰が・いつから）
```

- `kind=deploy` が残っている場合: そのデプロイを実行した人に、止まっていることを確認します。確認できたら解除します。
- `kind=measure` が残っている場合: 先に `scripts/measure.sh status <run-id>` で記録用プロセスの状態を確認します。可能なら `measure.sh stop` で回収してロックを解放します。
- 解除は、ロックIDが一致する場合だけ行えます（古いロックを無条件に消す機能はありません）。
  ```bash
  scripts/lock.sh release --host isu1 --lock-id <status に表示された id>
  ```

ロックの仕組みと保証範囲:

- ロックは対象ホスト上の `mkdir` による排他です。複数の手元 PC から操作しても、同じホストでロックを取れるのは1つだけです。
- 複数ホストへのデプロイでは、全ホストのロックを取れた場合だけ処理を始めます。取れなかった場合は、取得済みのロックを解除して中止します。
- このスクリプトを経由しない操作（手作業の `systemctl` や手でのファイル編集）は防げません。

## 5. 再起動試験の前に確認すること

多くの ISUCON では、競技終了後にサーバーを再起動してから動作確認が行われます。当日のマニュアルで条件を確認してください。

```bash
scripts/verify.sh                         # active / enabled（自動起動）/ ポート / HTTP
```

- [ ] 使うサービスがすべて `enabled`（自動起動）になっている。使わなくなったサービスを `disable` する場合は、マニュアルで許されているか確認する
- [ ] 実際に再起動してから `verify.sh` が通る（`ssh isu1 sudo reboot` → 数分待つ → `scripts/verify.sh`）
- [ ] 再起動後もデータが残っている（ベンチの後に投稿したデータが表示される）
- [ ] DB の変更（インデックスなど）と初期化処理が整合している（上の「スキーマ・インデックスの変更」を参照）
- [ ] オンメモリのキャッシュを使っている場合、起動時または初期化時に再構築される
- [ ] 再起動した後に、もう一度ベンチを実行して通る

## 6. 計測をやめて元に戻す（終了前の確認）

計測のために有効にしたログやプロファイラーは負荷になります。最終ベンチの前に止めます。

| 対象 | 戻し方 | 確認 |
| --- | --- | --- |
| nginx アクセスログ | `templates/nginx/00-isucon-log.conf` の `access_log` を `access_log off;` にして、`scripts/deploy/nginx.sh` | `ssh isu1 "sudo nginx -T \| grep access_log"` |
| MySQL スロークエリログ | `templates/mysql/99-isucon-slowlog.cnf` を `slow_query_log = OFF` にして、`scripts/deploy/mysql.sh --apply-dynamic` | 表示される表で「稼働中」「再起動後」が両方 OFF（0） |
| pprof | systemd の環境変数から `ISU_PPROF` を外し、アプリを再起動（`deploy/app.sh`） | `ssh isu1 'ss -tln \| grep 6060'` で何も出ない |
| 計測ロック | `scripts/lock.sh status` で何も残っていない | |

テンプレートを直接書き換えず、`config/` にコピーして `ISU_*_FILES` の手元のパスを差し替えてもかまいません。

最終確認:

- [ ] 計測をやめた状態でベンチを1回実行し、スコアとエラーを記録した
- [ ] `git status` が clean で、配布したコミットが `deployed-app.env` の値と一致する
- [ ] 再起動試験のチェック（上の5）が終わっている
- [ ] 当日のマニュアルにある「終了前の注意事項」を読み直した
