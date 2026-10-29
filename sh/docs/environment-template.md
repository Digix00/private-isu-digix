# 当日の構成メモ（雛形）

競技開始後に埋めていく記録用の雛形です。コピーして使い、チームで共有します。
秘密情報（パスワード・トークン）は書かないでください。

```bash
cp docs/environment-template.md docs/environment.md   # 当日の記録
```

`config/isucon.conf` には、このメモで確定した値を転記します。

## 0. 前提の確認（マニュアル・レギュレーション）

当日のマニュアル・レギュレーションが、このリポジトリの手順より優先です。

- [ ] 当日のマニュアルを読んだ（URL: ）
- [ ] 禁止事項（例: 外部サービスの利用、ベンチマーカーへの干渉、サーバーの追加）:
- [ ] 再起動試験の有無と条件（ベンチ後にサーバーを再起動してもデータが残っていること、など）:
- [ ] ベンチの実行方法（ポータル / コマンド）と、同時に実行できる数:
- [ ] 初期化エンドポイント（例: `POST /initialize`）と、その制限時間:
- [ ] スコアの計算方法と、失格・減点の条件:
- [ ] 競技終了時刻と、最終ベンチの扱い:

## 1. ホスト

| SSH Host 名 | IP（グローバル / プライベート） | 役割 (app/nginx/mysql) | CPU / メモリ | 備考 |
| --- | --- | --- | --- | --- |
| isu1 | | | | |
| isu2 | | | | |
| isu3 | | | | |

確認するコマンド: `scripts/inspect.sh`（結果は `results/inspect/` に保存されます）

## 2. サービス

| 役割 | systemd のユニット名 | 待ち受けポート | 自動起動 (enabled) |
| --- | --- | --- | --- |
| app | | | |
| nginx | nginx | 80 / 443 | |
| mysql | mysql | 3306 | |
| その他（memcached など） | | | |

確認するコマンド: `systemctl list-units --type=service --state=running` と、`inspect.sh` の「listening」の出力

## 3. アプリケーション

| 項目 | 値 |
| --- | --- |
| 実装言語・フレームワーク | Go / |
| ソースの場所（サーバー） | |
| 実行ファイルの場所（サーバー） | |
| ビルド方法（Makefile など） | |
| 起動コマンド（systemd の ExecStart） | |
| 環境変数ファイル（EnvironmentFile） | |
| サーバーの OS / CPU アーキテクチャ | linux / amd64・arm64 |
| CGO の要否 | |

確認するコマンド: `systemctl cat <ユニット名>`（`inspect.sh` が値を伏せて表示します）

## 4. nginx

| 項目 | 値 |
| --- | --- |
| バージョン | |
| メインの設定 | /etc/nginx/nginx.conf |
| サイトの設定（include されるもの） | |
| access_log の場所・形式 | |
| 静的ファイルの root | |
| upstream（アプリへの転送先） | |

確認するコマンド: `sudo nginx -T | grep -E '^# configuration file|access_log|include'`

## 5. MySQL

| 項目 | 値 |
| --- | --- |
| バージョン | |
| 設定ファイルの読み込み順 | `mysqld --verbose --help \| grep -A1 'Default options'` |
| 追加の設定を置くディレクトリ | 例: /etc/mysql/mysql.conf.d/ |
| データベース名 | |
| 接続方法（手元から sudo mysql で入れるか） | |
| slow_query_log の初期値 | |
| テーブル・インデックスの一覧 | `results/<run-id>/snapshots/` に保存 |

## 6. ログの場所

| 種類 | パス | ローテーション設定 |
| --- | --- | --- |
| nginx access_log | | /etc/logrotate.d/nginx |
| nginx error_log | | |
| MySQL slow log | | |
| MySQL error log | | |
| アプリ（journald） | `journalctl -u <ユニット名>` | |

## 7. 初期状態の記録

- [ ] 初期状態のベンチ結果（スコア・エラー）:
- [ ] 初期状態の設定のスナップショットを保存した（`inspect.sh` の結果、nginx/MySQL の設定のコピー）
- [ ] 初期状態のソースを Git にコミットした（コミット: ）

## 8. メモ

- 気づいたこと、マニュアルから読み取った注意点など
