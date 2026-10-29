#!/usr/bin/env bash
#? 使い方: scripts/agent-context.sh RUN_ID [--baseline RUN_ID] [--max-bytes N]
#?
#? 集計済みの結果から、最初に読む入口 results/RUN_ID/context.md を固定のテンプレートで生成する。
#? LLM による要約は使わない。観測した事実だけを載せ、仮説は experiments/ に書く運用にする。
#? 上限（既定 ISU_CONTEXT_MAX_BYTES = 8 KiB）を超える場合は、優先度の低い項目から省略する
#? （収集の不足・エラーは常に残す）。基準を指定すると、スコアと全体の差を載せる。
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$ISU_LIB_DIR/config.sh"
source "$ISU_LIB_DIR/results.sh"
source "$ISU_LIB_DIR/bounded.sh"
source "$ISU_LIB_DIR/render.sh"

run="${1:-}"
[[ "$run" == -h || "$run" == --help ]] && { print_help; exit 0; }
[[ -n "$run" ]] || usage_error "実行IDを指定してください"
validate_run_id "$run"
shift
base="" max=""
while (($#)); do
  case "$1" in
    --baseline) [[ $# -ge 2 ]] || usage_error "--baseline に値が必要です"; base="$2"; validate_run_id "$2"; shift 2 ;;
    --max-bytes) [[ $# -ge 2 ]] || usage_error "--max-bytes に値が必要です"; max="$2"; shift 2 ;;
    -h | --help) print_help; exit 0 ;;
    *) usage_error "不明な引数: $1" ;;
  esac
done
require_cmd jq awk
load_config
max="$(resolve_max "$max" "$ISU_CONTEXT_MAX_BYTES")"
d="$(run_dir "$run")"
[[ -f "$d/manifest.json" ]] || die "manifest.json がありません。先に scripts/report.sh $run を実行してください" "$EX_USAGE"
[[ -f "$d/metrics.json" ]] || die "metrics.json がありません (status: $(jq -r .status "$d/manifest.json"))。集計に失敗しています" "$EX_FAIL"
[[ -n "$base" ]] || base="$(jq -r '.baseline_run_id // empty' "$d/manifest.json")"

{
  render_overview "$run" 5
  if [[ -n "$base" ]]; then
    b="$(run_dir "$base")"
    if [[ -f "$b/metrics.json" && -f "$b/manifest.json" ]]; then
      jq -r -n --slurpfile bm "$b/manifest.json" --slurpfile bx "$b/metrics.json" --slurpfile tm "$d/manifest.json" \
        --slurpfile tx "$d/metrics.json" --arg base "$base" --arg run "$run" "$JQ_DEFS"'
        $bm[0] as $BM | $bx[0] as $BX | $tm[0] as $TM | $tx[0] as $TX |
        "I\t## 基準 \($base) との差（詳細: scripts/compare.sh \($base) \($run)）",
        "I\t- score: \($BM.bench.score | nv) → \($TM.bench.score | nv) (差 \(delta($BM.bench.score; $TM.bench.score) | nv), \(ratio($BM.bench.score; $TM.bench.score)))  pass: \($BM.bench.pass | nv) → \($TM.bench.pass | nv)",
        "I\t- requests: \($BX.totals.requests) → \($TX.totals.requests)  5xx: \($BX.totals["5xx"]) → \($TX.totals["5xx"])  query_time: \($BX.totals.query_time | s3) → \($TX.totals.query_time | s3)",
        (if $BM.analysis.api_grouping.rules_sha256 != $TM.analysis.api_grouping.rules_sha256 then "I\t- 注意: URL グルーピングが違うため API 単位の比較はできない" else empty end),
        (if $BM.status != "complete" or $TM.status != "complete" then "I\t- 注意: 収集状態が complete ではない実行を含む（\($BM.status) / \($TM.status)）" else empty end)'
    else
      printf 'I\t## 基準 %s との差\nI\t- 基準の集計結果がないため比較していない（scripts/report.sh %s）\n' "$base" "$base"
    fi
  fi
} | bounded_output "$max" 0 "" | atomic_write "$d/context.md"
log "context.md を生成しました: $d/context.md ($(LC_ALL=C wc -c <"$d/context.md" | tr -d ' ') bytes)"
