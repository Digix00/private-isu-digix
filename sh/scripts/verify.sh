#!/usr/bin/env bash
#? 使い方: scripts/verify.sh [--host HOST]...
#?
#? 読み取り専用で、ホストの役割に応じたサービス状態（active / enabled）、待ち受けポート、
#? HTTP 応答を確認する。deploy の後や再起動試験の後に使う。1件でも NG なら終了コード 1。
#?
#? 確認内容は config/isucon.conf の ISU_*_SERVICE, ISU_VERIFY_PORTS, ISU_HTTP_CHECKS で決まる。
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$ISU_LIB_DIR/config.sh"
source "$ISU_LIB_DIR/remote.sh"

hosts=()
while (($#)); do
  case "$1" in
    --host) [[ $# -ge 2 ]] || usage_error "--host に値が必要です"; hosts+=("$2"); shift 2 ;;
    -h | --help) print_help; exit 0 ;;
    *) usage_error "不明な引数: $1" ;;
  esac
done
require_cmd ssh
load_config
cfg_require ISU_APP_SERVICE ISU_NGINX_SERVICE ISU_MYSQL_SERVICE ISU_VERIFY_PORTS ISU_HTTP_CHECKS

declare -A service_of=([app]="$ISU_APP_SERVICE" [nginx]="$ISU_NGINX_SERVICE" [mysql]="$ISU_MYSQL_SERVICE")
statuses=()
targets="$(select_hosts "${hosts[@]}")"
for h in $targets; do
  svcs="" ports="" urls=""
  for r in ${ISU_ROLES[$h]:-}; do
    svcs+="${service_of[$r]} "
    ports+="${ISU_VERIFY_PORTS[$r]:-} "
    for c in "${ISU_HTTP_CHECKS[@]}"; do
      [[ "${c%%|*}" == "$r" ]] && urls+="${c#*|} "
    done
  done
  echo "### $h (役割: ${ISU_ROLES[$h]:-なし})"
  rc=0
  remote_run "$h" verify.sh "VERIFY_SERVICES=$svcs" "VERIFY_PORTS=$ports" "VERIFY_URLS=$urls" || rc=$?
  statuses+=("$h=$rc")
done
report_hosts "verify" "${statuses[@]}"
