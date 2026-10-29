#!/usr/bin/env bash
#? 使い方: scripts/deploy/mysql.sh [--host HOST]... [--dry-run] [--apply-dynamic | --restart]
#?
#? ISU_MYSQL_FILES に書いた設定ファイルだけを mysql 役のホストへ配置する。
#?   1. 対象ホストのロックを取得（計測中・他のデプロイ中なら中止）
#?   2. 既存ファイルを退避して配置し、mysqld --validate-config（MySQL 8.0.16+）で検証
#?      失敗したら配置前に戻す
#?   3. 反映方法は明示的に選ぶ:
#?        (指定なし)       ファイルの配置だけ。稼働中の値は変えない
#?        --apply-dynamic  ISU_MYSQL_DYNAMIC_VARS に含まれる変数だけ SET GLOBAL で稼働中に反映
#?        --restart        MySQL を再起動する（ベンチ中・計測中には行わないこと）
#?   4. 変数ごとに「ファイル」「稼働中」「再起動後に読まれる値」を表示する
#? スキーマ・インデックスの変更やデータの削除・初期化は行わない（docs/operations.md を参照）。
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
source "$ISU_LIB_DIR/config.sh"
source "$ISU_LIB_DIR/remote.sh"
source "$ISU_LIB_DIR/lock.sh"
source "$ISU_LIB_DIR/files.sh"

hosts=() mode=file
while (($#)); do
  case "$1" in
    --host) [[ $# -ge 2 ]] || usage_error "--host に値が必要です"; hosts+=("$2"); shift 2 ;;
    --dry-run) export ISU_DRY_RUN=1; shift ;;
    --apply-dynamic) [[ "$mode" == file ]] || usage_error "--apply-dynamic と --restart は同時に指定できません"; mode=dynamic; shift ;;
    --restart) [[ "$mode" == file ]] || usage_error "--apply-dynamic と --restart は同時に指定できません"; mode=restart; shift ;;
    -h | --help) print_help; exit 0 ;;
    *) usage_error "不明な引数: $1" ;;
  esac
done
require_cmd ssh tar
load_config
cfg_require ISU_MYSQL_SERVICE ISU_MYSQL_FILES
: "${ISU_MYSQL_CLI:=sudo -n mysql}"
: "${ISU_MYSQL_DYNAMIC_VARS:=slow_query_log slow_query_log_file long_query_time log_output log_queries_not_using_indexes min_examined_row_limit log_slow_extra}"
targets="$(hosts_for_role mysql "${hosts[@]}")"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
make_bundle "$workdir/mysql.tgz" "${ISU_MYSQL_FILES[@]}"

lock_id="$(new_lock_id)"
# shellcheck disable=SC2086 # ホスト名は検証済みで空白を含まない
lock_acquire_all "$lock_id" deploy mysql $targets || exit $?
trap 'lock_release_all "$lock_id"; rm -rf "$workdir"' EXIT

backup="mysql-$(date +%Y%m%d-%H%M%S)"
statuses=()
for h in $targets; do
  echo "### $h (反映方法: $mode)"
  rc=0
  bundle="$ISU_REMOTE_STATE_DIR/upload/$backup.tgz"
  { remote_upload "$h" "$workdir/mysql.tgz" "$bundle" &&
    remote_mut "$h" "_files.sh deploy-mysql.sh" "BUNDLE=$bundle" "BACKUP_NAME=$backup" \
      "SERVICE=$ISU_MYSQL_SERVICE" "MODE=$mode" "DYNAMIC_VARS=$ISU_MYSQL_DYNAMIC_VARS" "MYSQL_CLI=$ISU_MYSQL_CLI"; } || rc=$?
  statuses+=("$h=$rc")
done
report_hosts "deploy mysql" "${statuses[@]}"
