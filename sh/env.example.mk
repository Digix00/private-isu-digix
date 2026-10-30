# 当日の構成に合わせた設定。cp env.example.mk env.mk して編集する（env.mk は Git 管理外）。
# make の書式なので、値の中の $ は $$ と書く。コマンドの引数で一時的に上書きもできる: make deploy APP_HOSTS=isu2
# パスワードなどの秘密情報は書かない（MySQL はサーバー上の sudo mysql で操作する）。

# ---- ホスト（~/.ssh/config の Host 名） ---------------------------------------
# TODO(当日): 構成に合わせる。複数台にアプリを置く場合は空白区切り
APP_HOSTS  := isu1
NGINX_HOST := isu1
DB_HOST    := isu1

# ---- アプリ ---------------------------------------------------------------
# TODO(当日): systemctl list-units --type=service で確認（private-isu の Go 実装は isu-go）
APP_SERVICE := isu-go
# TODO(当日): systemctl cat <サービス> の ExecStart が実行するバイナリ
APP_BIN     := /home/isucon/private_isu/webapp/golang/app
# 手元のソースの場所（sh/ からの相対か絶対パス）と、ビルドするパッケージ
APP_SRC     := ../webapp/golang
BUILD_PKG   := .
# TODO(当日): サーバーの uname -m が x86_64 なら amd64、aarch64 なら arm64
GOARCH      := amd64
# make status で確認するサービスと URL（サーバー上で curl する）
SERVICES    := $(APP_SERVICE) nginx mysql
CHECK_URL   := http://127.0.0.1/

# ---- 設定ファイル（サーバー上の絶対パス。手元では conf/ の下に同じパスで置く） ------
# make fetch-conf で conf/etc/nginx/... に取得し、編集して make deploy-nginx で戻す
# TODO(当日): sudo nginx -T | grep '# configuration file' で確認する
NGINX_FILES := /etc/nginx/nginx.conf /etc/nginx/sites-available/isucon.conf
MYSQL_FILES := /etc/mysql/mysql.conf.d/mysqld.cnf

# ---- ログと計測 -------------------------------------------------------------
ACCESS_LOG    := /var/log/nginx/access.log
SLOW_LOG      := /var/log/mysql/mysql-slow.log
# alp で ID を含む URL をまとめる正規表現（カンマ区切り。$ は $$）
# TODO(当日): アプリのルーティングを見て追加する（以下は private-isu の例）
ALP_MATCH     := ^/posts/[0-9]+$$,^/@[^/]+$$,^/image/[0-9]+\.(jpg|png|gif)$$
PPROF_URL     := http://127.0.0.1:6060
PPROF_SECONDS := 30
