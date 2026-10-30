# 配布・戻し・再起動試験・終了前の確認

コマンドは `sh/` で実行します。**当日のマニュアルが優先です。**

## チームの約束

- **ベンチ中は配布・設定変更・再起動をしない。** ベンチを回す人が「ベンチ開始」「終了」を宣言します。
- **変更は1回に1つ。** コミットしてから `make deploy` します。memo.md の「配布したコード」に、コミットと未コミットの変更の有無が入ります。
- **戻すときは `git revert` → `make deploy` が基本です。** 急ぐときは `make rollback` で、直前のバイナリ（`.prev`）に戻せます。戻せるのは1世代だけです。

## アプリ

```bash
make -n deploy      # 実行するコマンドの確認
make deploy         # ビルド → 配布 → 再起動 → active の確認
make status         # HTTP 応答も確認
make rollback       # 直前のバイナリに戻す
```

- ビルドは手元で `GOOS=linux GOARCH=$(GOARCH) CGO_ENABLED=0` を指定して行います。**CGO が必要な構成（sqlite など）には対応していません。** その場合はサーバー上でビルドするよう、`deploy` を書き換えます。
- 失敗したときは `ssh isu1 journalctl -u isu-go -n 50 --no-pager` で原因を見ます。

## nginx・MySQL の設定

```bash
make fetch-conf                       # 最初に1回: サーバーの設定を conf/etc/... に取得してコミット
$EDITOR conf/etc/nginx/nginx.conf
make deploy-nginx                     # nginx -t が通ったら reload。失敗したら元に戻す
$EDITOR conf/etc/mysql/mysql.conf.d/mysqld.cnf
make deploy-mysql                     # mysqld --validate-config が通ったら MySQL を再起動（ベンチ中は使わない）
```

- 管理するファイルは `env.mk` の `NGINX_FILES` / `MYSQL_FILES` に書いたものだけです。それ以外の設定には触れません。
- 配置前のファイルは、サーバーの `/tmp/isu-bak-<ファイル名>` に1世代だけ残ります。
- `mysqld --validate-config` は MySQL 8.0.16 以降で使えます。MariaDB などで使えない場合は、Makefile の該当行を書き換えます。
- スロークエリログは `make slow-on` / `make slow-off` で切り替えます（再起動しない）。`SET GLOBAL` は**既存の接続には効かない**ので、切り替えた後に `make restart` でアプリを再起動します。

## スキーマ・インデックスの変更

設定の配布とは分けて、SQL ファイルで行います。

1. SQL をファイルにしてコミットします。
   ```sql
   -- sql/001-comments-index.sql
   ALTER TABLE comments ADD INDEX idx_post_id_created_at (post_id, created_at);
   ```
2. **初期化処理との整合を確認します。** ベンチの初期化（`/initialize`）がテーブルを作り直す場合、追加したインデックスは消えます。初期化の処理か初期データの SQL に入れておきます。初期化が制限時間内に終わるかも確認します。
3. 適用して確認します（ベンチ中は行わない）。
   ```bash
   ssh isu1 'sudo mysql isuconp' < sql/001-comments-index.sql
   ssh isu1 "sudo mysql isuconp -e 'SHOW INDEX FROM comments'"
   ```
4. 戻すときの SQL も用意しておきます: `ALTER TABLE comments DROP INDEX idx_post_id_created_at;`

## 再起動試験の前に

多くの ISUCON では、競技後にサーバーを再起動してから動作確認が行われます。条件はマニュアルで確認します。

- [ ] `make status` で、使うサービスがすべて `active` と `enabled`（自動起動）になっている
- [ ] 実際に再起動して確認した（`ssh isu1 sudo reboot` → 数分待つ → `make status`）
- [ ] 再起動後も、ベンチで書き込んだデータが残っている
- [ ] DB の変更（インデックスなど）と初期化処理が整合している
- [ ] オンメモリのキャッシュを使っている場合、起動時または初期化時に作り直される
- [ ] 再起動後にベンチを実行して通る

## 終了前（計測をやめて元に戻す）

| 対象 | 戻し方 |
| --- | --- |
| スロークエリログ | `make slow-off` → `make restart` |
| アクセスログ | `conf/etc/nginx/nginx.conf` の `access_log` を `off;` にして `make deploy-nginx` |
| pprof | systemd の環境変数から `ISU_PPROF` を外し、アプリを再起動する |
| 退避したログ | ディスクを圧迫していれば、`ssh isu1 'ls -lh /var/log/nginx/ /var/log/mysql/'` で `make pre` が退避した `<名前>.<月日-時刻>` のファイルを確認し、それだけを `sudo rm` で消す（logrotate の `.1` や `.gz` と間違えない） |

- [ ] 計測をやめた状態でベンチを実行し、スコアを記録した
- [ ] `git status` が clean で、最後に配布したコミットが memo.md の記録と一致している
- [ ] 再起動試験のチェックが終わっている
- [ ] マニュアルの「終了前の注意事項」を読み直した
