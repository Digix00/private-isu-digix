#!/usr/bin/env bash
#? 使い方: scripts/inspect.sh [--host HOST]... [--max-bytes N]
#?
#? 読み取り専用で対象ホストの構成を調べる（OS、CPU/メモリ、待ち受け、サービス、
#? nginx/MySQL の設定位置、ログの場所、ツールの有無）。何も変更しない。
#? 全文は results/inspect/<host>-<時刻>.txt に保存し、画面には上限付きで表示する。
#?
#?   --host HOST     対象を絞る（複数可。省略時は ISU_HOSTS 全体）
#?   --max-bytes N   画面に表示する1ホストあたりのバイト数上限（既定 ISU_OUTPUT_MAX_BYTES）
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$ISU_LIB_DIR/config.sh"
source "$ISU_LIB_DIR/remote.sh"
source "$ISU_LIB_DIR/bounded.sh"

hosts=() max=""
while (($#)); do
  case "$1" in
    --host) [[ $# -ge 2 ]] || usage_error "--host に値が必要です"; hosts+=("$2"); shift 2 ;;
    --max-bytes) [[ $# -ge 2 ]] || usage_error "--max-bytes に値が必要です"; max="$2"; shift 2 ;;
    -h | --help) print_help; exit 0 ;;
    *) usage_error "不明な引数: $1" ;;
  esac
done
require_cmd ssh awk
load_config
max="${max:-$ISU_OUTPUT_MAX_BYTES}"
validate_max_bytes "$max"

outdir="$ISU_RESULTS_DIR/inspect"
mkdir -p "$outdir"
ts="$(date +%Y%m%d-%H%M%S)"
statuses=()
targets="$(select_hosts "${hosts[@]}")"
for h in $targets; do
  out="$outdir/$h-$ts.txt"
  rc=0
  remote_run "$h" inspect.sh >"$out" 2>&1 || rc=$?
  statuses+=("$h=$rc")
  echo "### $h (全文: $out)"
  as_items <"$out" | bounded_output "$max" 1 "sed -n '%OFFSET%,\$p' $out"
done
report_hosts "inspect" "${statuses[@]}"
