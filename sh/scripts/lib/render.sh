# shellcheck shell=bash
# agent-context.sh / evidence.sh / compare.sh が共有する jq の定義と表示処理。
# 出力は bounded.sh の行形式（H/I/M/F + TAB）で作り、bounded_output で上限内に収める。
# 文字列の切り詰めは jq の .[0:n]（文字単位）で行うので、UTF-8 を途中で壊さない。

# shellcheck disable=SC2016 # jq のプログラム
JQ_DEFS='
def r3: if type == "number" then (. * 1000 | round) / 1000 else . end;
def ms: if type == "number" then "\((. * 1000 | round))ms" else "-" end;
def s3: if type == "number" then "\(r3)s" else "-" end;
def head($n): if type == "string" and length > $n then .[0:$n] + "..." else . end;
def nv: if . == null then "null" else tostring end;
def delta($b; $t): if ($b | type) == "number" and ($t | type) == "number" then ($t - $b) | r3 else null end;
def ratio($b; $t): if ($b | type) == "number" and ($t | type) == "number" and $b > 0 then "\((($t / $b) * 100 | round) / 100)x" else "比率なし(基準が0か欠測)" end;
def api_line: "\(.id)\t\(.method) \(.group | head(80))\tcount=\(.count) total=\(.total_time | s3) avg=\(.avg_time | ms) max=\(.max_time | ms) 4xx=\(.status["4xx"]) 5xx=\(.status["5xx"])";
def sql_line: "\(.id)\tcount=\(.count) total=\(.total_time | s3) avg=\(.avg_time | ms) rows_examined/回=\(if .count > 0 then (.rows_examined / .count | round) else 0 end)\t\(.fingerprint_head | head(120))";
'

# 実行の概要（context.md と evidence.sh summary で共通）。N は各一覧の件数。
# render_overview RUN N
render_overview() {
  local run="$1" n="$2" d
  d="$(run_dir "$run")"
  jq -r -n --arg run "$run" --argjson n "$n" --slurpfile m "$d/manifest.json" --slurpfile x "$d/metrics.json" \
    --arg src "${ISU_APP_SRC_DIR:-}" --arg now_commit "$(git -C "${ISU_APP_SRC_DIR:-/nonexistent}" rev-parse HEAD 2>/dev/null || true)" \
    --arg now_dirty "$( [[ -n "$(git -C "${ISU_APP_SRC_DIR:-/nonexistent}" status --porcelain 2>/dev/null)" ]] && echo true || echo false)" \
    "$JQ_DEFS"'
    $m[0] as $M | $x[0] as $X |
    def H: "H\t" + .; def I: "I\t" + .; def F: "F\t" + .;
    ("# 実行 \($run) の概要（自動生成。観測した事実だけを載せる）" | H),
    ("- 収集状態: \($M.status)  開始: \($M.started_at)  終了: \($M.stopped_at // "-")  基準: \($M.baseline_run_id // "なし")" | H),
    ("- 集計: \($M.analysis.analyzer) / URL グルーピング \($M.analysis.api_grouping.version) (\($M.analysis.api_grouping.rules_sha256[0:12])) / SQL 正規化 \($M.analysis.sql_normalizer_version)" | H),
    ("## 収集の不足・エラー（重大なものから。全 \($M.issues | length) 件）" | H),
    (if ($M.issues | length) == 0 then "- なし" | H else
      ($M.issues[0:10][] | "- [\(.severity)] \(.host) \(.artifact): \(.message | head(160))" | H),
      (if ($M.issues | length) > 10 then "- 他 \(($M.issues | length) - 10) 件: jq .issues results/\($run)/manifest.json" | H else empty end) end),
    ("## ベンチ結果（利用者が measure.sh result で記録した値）" | I),
    ("- pass: \($M.bench.pass | nv)  score: \($M.bench.score | nv)  errors: \($M.bench.errors | nv)  message: \($M.bench.message // "-" | head(120))" | I),
    ("## 変更内容（計測開始時のメモ）" | I),
    ("- \($M.note // "（なし）" | head(200))" | I),
    ("## コード（計測時）" | I),
    ("- 手元: commit \($M.code.local_at_start.commit // "不明" | .[0:12]) dirty=\($M.code.local_at_start.dirty | nv)  配布済みとの一致: \($M.code.consistency)" | I),
    ($M.code.consistency_notes[0:5][] | "  - \(. | head(150))" | I),
    ("- 現在の手元ソース: " + (if $now_commit == "" or $M.code.local_at_start.commit == null then "不明"
        elif $now_commit == $M.code.local_at_start.commit and $now_dirty == "false" and $M.code.local_at_start.dirty == false then "計測時と同じ"
        else "計測時と違う（git -C <src> diff \($M.code.local_at_start.commit[0:12])）" end) | I),
    ("## 全体" | I),
    ("- requests=\($X.totals.requests) request_time=\($X.totals.request_time | s3) 4xx=\($X.totals["4xx"]) 5xx=\($X.totals["5xx"]) / queries=\($X.totals.queries) query_time=\($X.totals.query_time | s3) rows_examined=\($X.totals.rows_examined)" | I),
    ("## 主要 API（合計時間順 上位 \([$n, ($X.api | length)] | min) / 全 \($X.api | length) 種。ID\tAPI\t統計）" | I),
    ($X.api[0:$n][] | "- " + api_line | I),
    ("## エラーを返した API（5xx → 4xx の多い順）" | I),
    ([$X.api[] | select(.status["5xx"] + .status["4xx"] > 0)] | sort_by(-.status["5xx"], -.status["4xx"], .id) |
      if length == 0 then "- なし" | I else .[0:5][] | "- " + api_line | I end),
    ("## 主要 SQL（合計時間順 上位 \([$n, ($X.sql | length)] | min) / 全 \($X.sql | length) 種。ID\t統計\t正規化 SQL の先頭）" | I),
    ($X.sql[0:$n][] | "- " + sql_line | I),
    ("## リソース（記録期間全体の平均。待ち時間を含む。busy_peak は 10 秒ごとの平均の最大）" | I),
    ($X.resources.cpu[] | "- \(.host): us=\(.us) sy=\(.sy) wa=\(.wa) idle=\(.idle) busy_peak_10s=\(.busy_peak_10s) (\(.samples) samples)" | I),
    ($X.resources.processes | group_by(.host)[] | "  - \(.[0].host) の CPU 上位: " + ([.[0:3][] | "\(.command | head(30)) avg=\(.avg_cpu)% max=\(.max_cpu)%"] | join(", ")) | I),
    ($X.resources.disks[] | select(.max_util > 0) | "  - \(.host) \(.device): util avg=\(.avg_util)% max=\(.max_util)%" | I),
    ("## 次に取得する情報" | F),
    ("- scripts/evidence.sh api \($run) --limit 20 / sql \($run) --sort total-time / sql-detail \($run) --id QUERY_ID" | F),
    ("- scripts/evidence.sh logs \($run) --api API_ID --errors / resources \($run) --host HOST / pprof \($run)" | F),
    (if $M.baseline_run_id then "- scripts/compare.sh \($M.baseline_run_id) \($run)" | F else empty end),
    ("- 仮説・判断はこのファイルに書かない（再生成で上書きされる）。experiments/<id>.md に実行ID・対象ID・根拠を添えて書く" | F)
  '
}

# 一覧の共通メタデータ行
list_meta() {
  local run="$1" what="$2" sort="$3" filter="$4" total="$5" off="$6" lim="$7"
  printf 'H\t# %s run=%s sort=%s filter=%s total=%s (集計は対象データ全体) offset=%s limit=%s data=%s\n' \
    "$what" "$run" "$sort" "$filter" "$total" "$off" "$lim" "$(sha256_file "$(run_dir "$run")/metrics.json" | cut -c1-12)"
}
