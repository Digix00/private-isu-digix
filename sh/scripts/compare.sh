#!/usr/bin/env bash
#? 使い方: scripts/compare.sh BASE_RUN_ID TARGET_RUN_ID [--limit N] [--offset N] [--max-bytes N]
#?
#? 基準の実行と対象の実行を比較する（差分の計算はすべてプログラムで行う）。
#?   1. 比較の前提: 収集状態、集計方法（URL グルーピング・SQL 正規化）、計測条件、ホスト構成、
#?      負荷走行の長さ、コードの違いを確認し、比較できない項目と理由を先に表示する
#?   2. ベンチの成否・スコア・エラー、全体の回数と時間
#?   3. API・SQL ごとの回数・合計時間・平均時間（合計時間の差が大きい順。--limit / --offset でページ送り）
#?   4. リソースの概要
#? 基準が 0 や欠測の場合は比率を出さない。合計時間の増減だけで改善・悪化を断定しないこと
#? （速くなると処理できる回数が増え、合計時間も増えることがある）。
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$ISU_LIB_DIR/config.sh"
source "$ISU_LIB_DIR/results.sh"
source "$ISU_LIB_DIR/bounded.sh"
source "$ISU_LIB_DIR/render.sh"

[[ "${1:-}" == -h || "${1:-}" == --help ]] && { print_help; exit 0; }
[[ $# -ge 2 ]] || usage_error "BASE_RUN_ID と TARGET_RUN_ID を指定してください"
base="$1" run="$2"
validate_run_id "$base"
validate_run_id "$run"
shift 2
limit="" offset=0 max=""
while (($#)); do
  case "$1" in
    --limit) [[ "${2:-}" =~ ^[0-9]+$ ]] && (($2 >= 1 && $2 <= 500)) || usage_error "--limit は 1〜500 です"; limit="$2"; shift 2 ;;
    --offset) [[ "${2:-}" =~ ^[0-9]+$ ]] || usage_error "--offset は0以上の整数です"; offset="$2"; shift 2 ;;
    --max-bytes) [[ $# -ge 2 ]] || usage_error "--max-bytes に値が必要です"; max="$2"; shift 2 ;;
    -h | --help) print_help; exit 0 ;;
    *) usage_error "不明な引数: $1" ;;
  esac
done
require_cmd jq awk
load_config
max="$(resolve_max "$max" "$ISU_OUTPUT_MAX_BYTES")"
limit="${limit:-$ISU_LIST_LIMIT}"
for r in "$base" "$run"; do
  [[ -f "$(run_dir "$r")/metrics.json" ]] || die "実行 $r の集計結果がありません（scripts/report.sh $r）" "$EX_USAGE"
done
b="$(run_dir "$base")" t="$(run_dir "$run")"

jq -r -n --slurpfile bm "$b/manifest.json" --slurpfile bx "$b/metrics.json" --slurpfile tm "$t/manifest.json" \
  --slurpfile tx "$t/metrics.json" --arg base "$base" --arg run "$run" --argjson o "$offset" --argjson l "$limit" "$JQ_DEFS"'
  $bm[0] as $BM | $bx[0] as $BX | $tm[0] as $TM | $tx[0] as $TX |
  def H: "H\t" + .; def I: "I\t" + .; def F: "F\t" + .;
  def secs: if type == "string" and length >= 19 then (.[0:19] | strptime("%Y-%m-%dT%H:%M:%S") | mktime) else null end;
  def window($X): if ($X.access_log.first // "") != "" then (($X.access_log.last | secs) - ($X.access_log.first | secs)) else null end;
  def chk($ok; $label; $why): if $ok then "OK  \($label)" else "NG  \($label): \($why)" end;
  def side($k; $B; $T): [($B | map({key: .id, value: .}) | from_entries), ($T | map({key: .id, value: .}) | from_entries)] as [$bb, $tt] |
    ([$bb, $tt] | map(keys) | add | unique) | map({id: ., b: $bb[.], t: $tt[.]}) |
    map(. + {d: delta(.b.total_time // 0; .t.total_time // 0)}) | sort_by(-((.d // 0) | fabs), .id);
  (window($BX)) as $wb | (window($TX)) as $wt |
  ("# compare base=\($base) target=\($run) offset=\($o) limit=\($l)（差 = target - base）" | H),
  ("## 比較の前提（NG の項目は比較結果をそのまま信用しない）" | H),
  (chk($BM.status == "complete" and $TM.status == "complete"; "収集状態"; "base=\($BM.status) target=\($TM.status)（不足のある実行を含む）") | H),
  (chk($BM.analysis.api_grouping.rules_sha256 == $TM.analysis.api_grouping.rules_sha256 and $BM.analysis.api_grouping.version == $TM.analysis.api_grouping.version;
     "URL グルーピング"; "規則が違う（API_ID が対応しない。report.sh --regroup でそろえる）") | H),
  (chk($BM.analysis.sql_normalizer_version == $TM.analysis.sql_normalizer_version; "SQL 正規化"; "版が違う（QUERY_ID が対応しない）") | H),
  (chk($BM.measurement.collectors == $TM.measurement.collectors and $BM.measurement.interval_sec == $TM.measurement.interval_sec; "記録ツール"; "collectors / interval が違う") | H),
  (chk($BM.measurement.mysql == $TM.measurement.mysql; "MySQL の計測設定"; "slow_query_log / long_query_time が違う（記録される SQL の範囲と負荷が違う）") | H),
  (chk(($BM.measurement.profiles | map(.type) | sort) == ($TM.measurement.profiles | map(.type) | sort); "pprof の取得"; "取得したプロファイルが違う（CPU プロファイル中は負荷が増える）") | H),
  (chk(($BM.hosts | map({name, roles})) == ($TM.hosts | map({name, roles})); "ホスト構成"; "ホストや役割が違う") | H),
  (chk(($wb != null and $wt != null and $wb > 0 and ((($wt - $wb) | fabs) / $wb) <= 0.1); "負荷走行の長さ";
     "アクセスログの期間 base=\($wb // "不明")s target=\($wt // "不明")s（10% を超える差、または不明）") | H),
  ("    コード: base=\($BM.code.local_at_start.commit // "不明" | .[0:12])(\($BM.code.consistency)) target=\($TM.code.local_at_start.commit // "不明" | .[0:12])(\($TM.code.consistency))" | H),
  ("## ベンチ" | I),
  ("- pass: \($BM.bench.pass | nv) → \($TM.bench.pass | nv)  errors: \($BM.bench.errors | nv) → \($TM.bench.errors | nv)" | I),
  ("- score: \($BM.bench.score | nv) → \($TM.bench.score | nv)  差 \(delta($BM.bench.score; $TM.bench.score) | nv)  \(ratio($BM.bench.score; $TM.bench.score))" | I),
  ("## 全体" | I),
  (["requests", "request_time", "5xx", "4xx", "queries", "query_time", "rows_examined"][] as $k |
    "- \($k): \($BX.totals[$k] | r3) → \($TX.totals[$k] | r3)  差 \(delta($BX.totals[$k]; $TX.totals[$k]) | nv)  \(ratio($BX.totals[$k]; $TX.totals[$k]))" | I),
  ("- 平均 request_time/回: \(if $BX.totals.requests > 0 then ($BX.totals.request_time / $BX.totals.requests | ms) else "-" end) → \(if $TX.totals.requests > 0 then ($TX.totals.request_time / $TX.totals.requests | ms) else "-" end)" | I),
  ("## リソース（CPU busy = 100 - idle の平均 / 10秒ごとの最大）" | I),
  (([$BX.resources.cpu[], $TX.resources.cpu[]] | map(.host) | unique)[] as $h |
    ([$BX.resources.cpu[] | select(.host == $h)][0]) as $x | ([$TX.resources.cpu[] | select(.host == $h)][0]) as $y |
    "- \($h): busy \(if $x then (100 - $x.idle | r3) else "-" end) → \(if $y then (100 - $y.idle | r3) else "-" end)  peak \($x.busy_peak_10s // "-") → \($y.busy_peak_10s // "-")" | I),
  (side("api"; $BX.api; $TX.api) as $A |
    ("## API（合計時間の差が大きい順。全 \($A | length) 種、\($o + 1) 件目から）" | I),
    ($A[$o:$o + $l][] | "- \(.id)\t\((.t // .b) | "\(.method) \(.group | head(70))")\tcount \(.b.count // "なし") → \(.t.count // "なし")  avg \(.b.avg_time | ms) → \(.t.avg_time | ms)  total \(.b.total_time | s3) → \(.t.total_time | s3) (差 \(.d | nv)s)" | I)),
  (side("sql"; $BX.sql; $TX.sql) as $S |
    ("## SQL（合計時間の差が大きい順。全 \($S | length) 種、\($o + 1) 件目から）" | I),
    ($S[$o:$o + $l][] | "- \(.id)\tcount \(.b.count // "なし") → \(.t.count // "なし")  avg \(.b.avg_time | ms) → \(.t.avg_time | ms)  total \(.b.total_time | s3) → \(.t.total_time | s3) (差 \(.d | nv)s)\t\((.t // .b).fingerprint_head | head(80))" | I)),
  (if ([side("api"; $BX.api; $TX.api), side("sql"; $BX.sql; $TX.sql)] | map(length) | max) > $o + $l then "M\tmore" else empty end),
  ("## 読み方" | F),
  ("- 合計時間の増減だけで改善と判断しない。回数（処理量）と平均時間を合わせて見る。「なし」はその実行で観測されなかった" | F)
' | bounded_output "$max" "$offset" "scripts/compare.sh $base $run --limit $limit" "$limit"
