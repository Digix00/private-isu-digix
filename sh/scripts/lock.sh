#!/usr/bin/env bash
#? 使い方:
#?   scripts/lock.sh status [--host HOST]...
#?   scripts/lock.sh release --host HOST --lock-id ID
#?
#? 対象ホスト上の実行状態ロック（deploy / measure が使う）を確認・解除する。
#? 異常終了などでロックが残った場合に使う。解除はロックIDが一致する場合だけ行う。
#? 古いロックを無条件に消す機能はない。解除の前に、計測やデプロイが本当に止まっていることを
#? status と docs/operations.md の手順で確認すること。
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$ISU_LIB_DIR/config.sh"
source "$ISU_LIB_DIR/remote.sh"

action="${1:-}"
[[ "$action" == -h || "$action" == --help ]] && { print_help; exit 0; }
[[ "$action" == status || "$action" == release ]] || usage_error "サブコマンドは status または release です"
shift
hosts=() id=""
while (($#)); do
  case "$1" in
    --host) [[ $# -ge 2 ]] || usage_error "--host に値が必要です"; hosts+=("$2"); shift 2 ;;
    --lock-id) [[ $# -ge 2 ]] || usage_error "--lock-id に値が必要です"; id="$2"; shift 2 ;;
    -h | --help) print_help; exit 0 ;;
    *) usage_error "不明な引数: $1" ;;
  esac
done
require_cmd ssh
load_config

if [[ "$action" == status ]]; then
  statuses=()
  targets="$(select_hosts "${hosts[@]}")"
  for h in $targets; do
    echo "### $h"
    rc=0; remote_run "$h" lock.sh ACTION=status || rc=$?
    statuses+=("$h=$rc")
  done
  report_hosts "lock status" "${statuses[@]}"
else
  ((${#hosts[@]} == 1)) || usage_error "release では --host を1つ指定してください"
  [[ -n "$id" ]] || usage_error "release には --lock-id が必要です（status で確認できます）"
  select_hosts "${hosts[@]}" >/dev/null
  remote_run "${hosts[0]}" lock.sh ACTION=release "LOCK_ID=$id"
  log "${hosts[0]} のロック $id を解除しました"
fi
