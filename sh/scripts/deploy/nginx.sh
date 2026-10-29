#!/usr/bin/env bash
#? 使い方: scripts/deploy/nginx.sh [--host HOST]... [--dry-run]
#?
#? ISU_NGINX_FILES に書いたファイルだけを nginx 役のホストへ配置する（それ以外の既存設定には触れない）。
#?   1. 対象ホストのロックを取得（計測中・他のデプロイ中なら中止）
#?   2. 既存ファイルを退避し、差分を表示してから配置
#?   3. 新しい設定一式で nginx -t（include も含めて実際に読まれる設定を検証）
#?   4. 管理するファイルが nginx -T に現れる（= include されている）ことを確認
#?   5. 成功した場合だけ systemctl reload。失敗したら配置前のファイルに戻し、reload しない
#?
#?   --host HOST  対象を nginx 役のホストの一部に絞る（複数可）
#?   --dry-run    転送・配置・reload を行わず、予定だけを表示する（SSH 接続もしない）
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
source "$ISU_LIB_DIR/config.sh"
source "$ISU_LIB_DIR/remote.sh"
source "$ISU_LIB_DIR/lock.sh"
source "$ISU_LIB_DIR/files.sh"

hosts=()
while (($#)); do
  case "$1" in
    --host) [[ $# -ge 2 ]] || usage_error "--host に値が必要です"; hosts+=("$2"); shift 2 ;;
    --dry-run) export ISU_DRY_RUN=1; shift ;;
    -h | --help) print_help; exit 0 ;;
    *) usage_error "不明な引数: $1" ;;
  esac
done
require_cmd ssh tar
load_config
cfg_require ISU_NGINX_SERVICE ISU_NGINX_FILES
: "${ISU_NGINX_CHECK_URL:=}" "${ISU_NGINX_CHECK_STATUS:=200}"
cfg_no_todo ISU_NGINX_CHECK_URL
targets="$(hosts_for_role nginx "${hosts[@]}")"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
make_bundle "$workdir/nginx.tgz" "${ISU_NGINX_FILES[@]}"

lock_id="$(new_lock_id)"
# shellcheck disable=SC2086 # ホスト名は検証済みで空白を含まない
lock_acquire_all "$lock_id" deploy nginx $targets || exit $?
trap 'lock_release_all "$lock_id"; rm -rf "$workdir"' EXIT

backup="nginx-$(date +%Y%m%d-%H%M%S)"
statuses=()
for h in $targets; do
  echo "### $h"
  rc=0
  bundle="$ISU_REMOTE_STATE_DIR/upload/$backup.tgz"
  { remote_upload "$h" "$workdir/nginx.tgz" "$bundle" &&
    remote_mut "$h" "_files.sh deploy-nginx.sh" "BUNDLE=$bundle" "BACKUP_NAME=$backup" \
      "SERVICE=$ISU_NGINX_SERVICE" "CHECK_URL=$ISU_NGINX_CHECK_URL" "CHECK_STATUS=$ISU_NGINX_CHECK_STATUS"; } || rc=$?
  statuses+=("$h=$rc")
done
report_hosts "deploy nginx" "${statuses[@]}"
