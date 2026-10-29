#!/usr/bin/env bash
# shellcheck disable=SC2016 # jq のプログラムは意図してシングルクォートで書く
#? 使い方: scripts/report.sh RUN_ID [--regroup]
#?
#? 回収済みの元データ（results/RUN_ID/raw/）を集計し、次を生成する（何度でも再実行できる）。
#?   reports/       api.tsv sql.tsv resources-*.tsv、alp / pt-query-digest / pprof の詳細（ツールがあれば）
#?   metrics.json   対象データ全体から算出した集計（API・SQL・リソース）
#?   manifest.json  識別情報・計測条件・収集状態・不足/エラー・コードの一致・成果物への参照
#?   context.md     最初に読む入口（agent-context.sh を呼ぶ）
#? 元データは書き換えない。集計結果は一時ディレクトリで作ってから置き換える。
#? 解析できるデータが何もない場合は status=failed として終了コード 1 を返し、成功レポートは作らない。
#?
#?   --regroup  URL グルーピングに計測時の設定ではなく現在の ISU_API_GROUPS を使う（manifest に記録される）
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$ISU_LIB_DIR/config.sh"
source "$ISU_LIB_DIR/results.sh"

run="${1:-}"
[[ "$run" == -h || "$run" == --help ]] && { print_help; exit 0; }
[[ -n "$run" ]] || usage_error "実行IDを指定してください"
validate_run_id "$run"
shift
regroup=0
while (($#)); do
  case "$1" in
    --regroup) regroup=1; shift ;;
    -h | --help) print_help; exit 0 ;;
    *) usage_error "不明な引数: $1" ;;
  esac
done
require_cmd jq awk
load_config
require_run "$run"
dir="$(run_dir "$run")"
st="$(jq -r .status "$dir/run.json")"
[[ "$st" == collected || "$st" == stop_incomplete ]] ||
  die "実行ID '$run' はまだ回収されていません (status: $st)。先に scripts/measure.sh stop $run を実行してください" "$EX_USAGE"

tmp="$(mktemp -d "$dir/.report.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/reports/pprof"
R="$tmp/reports"
: >"$tmp/issues.tsv"
issue() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >>"$tmp/issues.tsv"; }
envget() { sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -1; }

# ---- グルーピング規則（計測時の記録が基本） --------------------------------
if ((regroup)); then
  [[ -v ISU_API_GROUPS ]] || ISU_API_GROUPS=()
  printf '%s\n' "${ISU_API_GROUPS[@]}" | sed '/^$/d' >"$tmp/groups.txt"
  group_source="config (--regroup)"
else
  jq -r '.conditions.api_groups[]' "$dir/run.json" >"$tmp/groups.txt"
  group_source="run.json (計測時の設定)"
fi
groups_sha="$(sha256_file "$tmp/groups.txt")"

# ---- 収集状態の確認と入力ファイルの列挙 -------------------------------------
access=() slow=() profiles=()
for h in $(jq -r '.hosts[].name' "$dir/run.json"); do
  raw="$dir/raw/$h" roles="$(jq -r --arg h "$h" '.hosts[] | select(.name == $h) | .roles | join(" ")' "$dir/run.json")"
  if [[ ! -f "$raw/.fetched" ]]; then issue error "$h" all "回収できていない（measure.sh stop を再実行）"; continue; fi
  for c in $(jq -r '.conditions.collectors[]' "$dir/run.json"); do
    s1="$(envget "$raw/start.env" "collector_$c")" s2="$(envget "$raw/stop.env" "collector_$c")"
    [[ "$s1" == started ]] || issue warn "$h" "$c" "記録されていない (${s1:-不明})"
    [[ "$s1" != started || "$s2" == stopped ]] || issue warn "$h" "$c" "計測の途中で終了していた（記録は途中まで）"
  done
  if [[ " $roles " == *" nginx "* ]]; then
    s="$(envget "$raw/stop.env" access_status)"
    [[ "$s" == complete ]] || issue error "$h" access_log "${s:-missing}: $(envget "$raw/stop.env" access_reason)"
    r="$(envget "$raw/stop.env" access_reason)"; [[ "$s" != complete || -z "$r" ]] || issue info "$h" access_log "$r"
    [[ "$(envget "$raw/start.env" access_log_format)" != unknown ]] || issue warn "$h" access_log "ログ形式 ($ISU_NGINX_LOG_FORMAT) を確認できなかった"
    [[ -f "$raw/access.log" ]] && access+=("$raw/access.log")
  fi
  if [[ " $roles " == *" mysql "* ]]; then
    s="$(envget "$raw/stop.env" slow_status)"
    [[ "$s" == complete ]] || issue error "$h" slow_log "${s:-missing}: $(envget "$raw/stop.env" slow_reason)"
    v="$(envget "$raw/start.env" mysql_slow_query_log)"
    [[ "$v" == 1 || "$v" == ON ]] || issue error "$h" slow_log "計測開始時に slow_query_log が有効ではなかった (${v:-不明})"
    lqt="$(envget "$raw/start.env" mysql_long_query_time)"
    awk -v v="${lqt:-x}" 'BEGIN { exit !(v ~ /^[0-9.]+$/ && v + 0 == 0) }' ||
      issue warn "$h" slow_log "long_query_time=${lqt:-不明}: それより短い SQL は記録されていない（回数・合計は全体ではない）"
    [[ -f "$raw/slow.log" ]] && slow+=("$raw/slow.log")
  fi
  for p in "$raw"/pprof-*.pb.gz; do [[ -f "$p" ]] && profiles+=("$p"); done
done
[[ "$st" == stop_incomplete ]] && issue error - all "stop が完了していないホストがある"

# ---- 集計（全データに対して行う。表示の件数制限とは無関係） -----------------
LC_ALL=C awk -f "$AWK_DIR/common.awk" -f "$AWK_DIR/api.awk" -v groups="$tmp/groups.txt" -v meta="$R/api-meta.env" \
  "${access[@]}" </dev/null | sort -t$'\t' -k5,5gr -k1,1 >"$R/api.tsv"
LC_ALL=C awk -f "$AWK_DIR/common.awk" -f "$AWK_DIR/sql.awk" -v meta="$R/sql-meta.env" -v fpfile="$R/sql-fingerprints.tsv" \
  "${slow[@]}" </dev/null | sort -t$'\t' -k3,3gr -k1,1 >"$R/sql.tsv"
[[ -f "$R/sql-fingerprints.tsv" ]] || : >"$R/sql-fingerprints.tsv"
((${#access[@]})) && (($(envget "$R/api-meta.env" parsed) == 0)) && issue error - access_log "解析できる行がない（ログ形式を確認）"
u="$(envget "$R/api-meta.env" unparsed)"; ((${u:-0} == 0)) || issue warn - access_log "解析できない行が $u 行（最初: $(envget "$R/api-meta.env" unparsed_sample)）"
((${#slow[@]})) && (($(envget "$R/sql-meta.env" entries) == 0)) && issue warn - slow_log "SQL が1件も記録されていない"

: >"$R/resources-cpu.tsv"; : >"$R/resources-proc.tsv"; : >"$R/resources-disk.tsv"
for h in $(jq -r '.hosts[].name' "$dir/run.json"); do
  raw="$dir/raw/$h"
  [[ -f "$raw/vmstat.log" ]] && LC_ALL=C awk -f "$AWK_DIR/common.awk" -f "$AWK_DIR/res.awk" -v kind=vmstat -v host="$h" "$raw/vmstat.log" >>"$R/resources-cpu.tsv"
  [[ -f "$raw/pidstat.log" ]] && LC_ALL=C awk -f "$AWK_DIR/common.awk" -f "$AWK_DIR/res.awk" -v kind=pidstat -v host="$h" "$raw/pidstat.log" | sort -t$'\t' -k3,3gr | head -10 >>"$R/resources-proc.tsv"
  [[ -f "$raw/iostat.log" ]] && LC_ALL=C awk -f "$AWK_DIR/common.awk" -f "$AWK_DIR/res.awk" -v kind=iostat -v host="$h" "$raw/iostat.log" >>"$R/resources-disk.tsv"
done

# ---- 人が読む詳細レポート（ツールがある場合だけ） ---------------------------
tools="{}"
tool_ver() { tools="$(jq --arg k "$1" --arg v "$2" '. + {($k): $v}' <<<"$tools")"; }
if ((${#access[@]})) && command -v alp >/dev/null 2>&1; then
  tool_ver alp "$(alp --version 2>&1 | head -1)"
  if grep -q ',' "$tmp/groups.txt"; then issue info - alp "グループの正規表現にカンマがあるため alp を実行しなかった"
  else cat "${access[@]}" | alp ltsv -m "$(paste -sd, "$tmp/groups.txt")" --sort sum -r >"$R/alp.txt" 2>&1 || issue warn - alp "alp が失敗した (reports/alp.txt)"; fi
else tool_ver alp unavailable; fi
if ((${#slow[@]})) && command -v pt-query-digest >/dev/null 2>&1; then
  tool_ver pt-query-digest "$(pt-query-digest --version 2>&1 | tail -1)"
  for f in "${slow[@]}"; do
    h="$(basename "$(dirname "$f")")"
    pt-query-digest --limit 30 "$f" >"$R/pt-query-digest-$h.txt" 2>&1 || issue warn "$h" pt-query-digest "失敗した"
  done
else tool_ver pt-query-digest unavailable; fi
if ((${#profiles[@]})); then
  if command -v go >/dev/null 2>&1; then
    tool_ver go "$(go version)"
    for p in "${profiles[@]}"; do
      h="$(basename "$(dirname "$p")")" b="$(basename "$p" .pb.gz)"
      go tool pprof -top -nodecount=200 "$p" >"$R/pprof/$h-$b.top.txt" 2>&1 || issue warn "$h" pprof "解析に失敗した ($b)"
    done
  else issue warn - pprof "go がないため pprof を解析していない（プロファイルは raw/ にある）"; tool_ver go unavailable; fi
fi
jq -r '.profiles[] | "\(.host)\t\(.file)"' "$dir/run.json" | while IFS=$'\t' read -r h f; do
  [[ -f "$dir/raw/$h/$f" ]] || issue warn "$h" pprof "取得記録はあるが回収されていない ($f)"
done

# ---- metrics.json ----------------------------------------------------------
napi="$(wc -l <"$R/api.tsv" | tr -d ' ')" nsql="$(wc -l <"$R/sql.tsv" | tr -d ' ')"
status=complete
grep -q '^error' "$tmp/issues.tsv" && status=partial
((napi + nsql == 0)) && { status=failed; issue error - all "解析できるアクセスログ・SQL が1件もない"; }

tsv='def rows: split("\n") | map(select(length > 0) | split("\t")); def n: tonumber;'
jq -n --arg run "$run" --arg av "$ANALYZER_VERSION" --arg gv "$GROUPING_VERSION" --arg sv "$SQLNORM_VERSION" \
  --rawfile api "$R/api.tsv" --rawfile sql "$R/sql.tsv" --rawfile cpu "$R/resources-cpu.tsv" \
  --rawfile proc "$R/resources-proc.tsv" --rawfile disk "$R/resources-disk.tsv" \
  --argjson am "$(env_to_json "$R/api-meta.env")" --argjson sm "$(env_to_json "$R/sql-meta.env")" \
  "$tsv"'
  ($api | rows | map({id: .[0], method: .[1], group: .[2], count: (.[3] | n), total_time: (.[4] | n), avg_time: (.[5] | n),
     max_time: (.[6] | n), status: {"2xx": (.[7] | n), "3xx": (.[8] | n), "4xx": (.[9] | n), "5xx": (.[10] | n)}, hosts: .[11]})) as $A |
  ($sql | rows | map({id: .[0], count: (.[1] | n), total_time: (.[2] | n), avg_time: (.[3] | n), max_time: (.[4] | n),
     lock_time: (.[5] | n), rows_sent: (.[6] | n), rows_examined: (.[7] | n),
     first_sample: {host: .[8], offset: (.[9] | n)}, slowest_sample: {host: .[10], offset: (.[11] | n)}, fingerprint_head: .[12]})) as $S |
  {format_version: 1, run_id: $run, analyzer: $av, api_grouping_version: $gv, sql_normalizer_version: $sv,
   totals: {requests: ($A | map(.count) | add // 0), request_time: ($A | map(.total_time) | add // 0),
     "4xx": ($A | map(.status["4xx"]) | add // 0), "5xx": ($A | map(.status["5xx"]) | add // 0),
     queries: ($S | map(.count) | add // 0), query_time: ($S | map(.total_time) | add // 0),
     rows_examined: ($S | map(.rows_examined) | add // 0)},
   access_log: $am, slow_log: $sm, api: $A, sql: $S,
   resources: {cpu: ($cpu | rows | map({host: .[0], samples: (.[1] | n), us: (.[2] | n), sy: (.[3] | n), wa: (.[4] | n),
       idle: (.[5] | n), busy_peak_10s: (.[6] | n), first: .[7], last: .[8]})),
     processes: ($proc | rows | map({host: .[0], command: .[1], avg_cpu: (.[2] | n), max_cpu: (.[3] | n), max_rss_kb: (.[4] | n)})),
     disks: ($disk | rows | map({host: .[0], device: .[1], avg_util: (.[2] | n), max_util: (.[3] | n), r_s: (.[4] | n), w_s: (.[5] | n)}))}}' \
  >"$tmp/metrics.json"

# ---- manifest.json ---------------------------------------------------------
hostinfo="$(for h in $(jq -r '.hosts[].name' "$dir/run.json"); do
  jq -n --arg h "$h" --argjson s "$(env_to_json "$dir/raw/$h/start.env")" --argjson e "$(env_to_json "$dir/raw/$h/stop.env")" \
    '{($h): {start: $s, stop: $e}}'
done | jq -s 'add // {}')"
issues_json="$(jq -R -s 'split("\n") | map(select(length > 0) | split("\t") | {severity: .[0], host: .[1], artifact: .[2], message: .[3]})
  | sort_by({"error": 0, "warn": 1, "info": 2}[.severity])' "$tmp/issues.tsv")"
reports_json="$(cd "$R" && find . -type f | sed 's|^\./|reports/|' | LC_ALL=C sort | jq -R -s 'split("\n") | map(select(. != ""))')"
jq -n --slurpfile run "$dir/run.json" --argjson bench "$( [[ -f "$dir/bench.json" ]] && cat "$dir/bench.json" || echo null)" \
  --argjson hi "$hostinfo" --argjson issues "$issues_json" --argjson tools "$tools" --argjson reports "$reports_json" \
  --arg status "$status" --arg at "$(now_iso)" --arg av "$ANALYZER_VERSION" --arg gv "$GROUPING_VERSION" --arg sv "$SQLNORM_VERSION" \
  --arg gsrc "$group_source" --arg gsha "$groups_sha" --rawfile groups "$tmp/groups.txt" '
  $run[0] as $r |
  def nn: if . == null or . == "" then null else . end;
  ([$r.hosts[] | select(.roles | index("app")) | .name] | map({key: ., value: ($hi[.].start // {} | {
      commit: (.DEPLOY_COMMIT | nn), dirty: (.DEPLOY_DIRTY | nn), diff_sha256: (.DEPLOY_DIFF_SHA256 | nn),
      deployed_at: (.DEPLOYED_AT | nn), binary_sha256_deployed: (.DEPLOY_BIN_SHA256 | nn),
      binary_sha256_at_start: (.app_bin_sha256_at_start | nn)}
    | . + {binary_matches: (if .binary_sha256_deployed and .binary_sha256_at_start then .binary_sha256_deployed == .binary_sha256_at_start else null end)})})
    | from_entries) as $dep |
  ($r.local_code) as $loc |
  ([$dep | to_entries[] | .key as $h | .value |
     (if .commit == null then "\($h): 配布記録がない（deploy/app.sh 以外で配布した?）" else empty end),
     (if .commit != null and $loc.commit != null and .commit != $loc.commit then "\($h): 配布済みコミット \(.commit[0:12]) と手元 \($loc.commit[0:12]) が違う" else empty end),
     (if .dirty == "true" or $loc.dirty == true then (if .diff_sha256 != ($loc.diff_sha256 // "none") then "\($h): 未コミット差分が手元と配布済みで違う" else "\($h): 未コミットの差分を含む" end) else empty end),
     (if .binary_matches == false then "\($h): 計測開始時のバイナリが配布記録と違う" else empty end)]) as $why |
  {format_version: 1, run_id: $r.run_id, baseline_run_id: $r.baseline_run_id, status: $status, note: $r.note,
   started_at: $r.started_at, stopped_at: $r.stopped_at, marks: $r.marks,
   hosts: [$r.hosts[] | . + {log_ranges: ($hi[.name] // {} | {start: .start, stop: .stop})}],
   bench: ($bench // {pass: null, score: null, errors: null, message: null}),
   code: {local_at_start: $loc, deployed: $dep,
     consistency: (if ($dep | length) == 0 or $loc.commit == null or ([$dep[] | .commit] | any(. == null)) then "unknown"
                   elif ($why | length) == 0 then "match" else "mismatch" end), consistency_notes: $why},
   measurement: {collectors: $r.conditions.collectors, interval_sec: $r.conditions.interval_sec,
     access_log: $r.conditions.access_log, slow_log: $r.conditions.slow_log, profiles: $r.profiles,
     mysql: ($hi | to_entries | map(select(.value.start.mysql_long_query_time != null)) | map({key: .key, value: {
       slow_query_log: .value.start.mysql_slow_query_log, long_query_time: .value.start.mysql_long_query_time,
       log_output: .value.start.mysql_log_output}}) | from_entries)},
   analysis: {generated_at: $at, analyzer: $av, sql_normalizer_version: $sv, tools: $tools,
     api_grouping: {version: $gv, source: $gsrc, rules_sha256: $gsha, rules: ($groups | split("\n") | map(select(. != "")))}},
   issues: $issues,
   artifacts: {context: "context.md", metrics: (if $status == "failed" then null else "metrics.json" end), reports: $reports,
     raw: "raw/", snapshots: "snapshots/", experiments_dir: "experiments/"}}' >"$tmp/manifest.json"

# ---- 公開（置き換え）。manifest.json を最後に置き、完成の目印にする -----------
rm -f "$dir/manifest.json"
rm -rf "$dir/reports.old"
[[ -d "$dir/reports" ]] && mv "$dir/reports" "$dir/reports.old"
mv "$R" "$dir/reports"
rm -rf "$dir/reports.old"
if [[ "$status" == failed ]]; then
  rm -f "$dir/metrics.json" "$dir/context.md"
  mv "$tmp/manifest.json" "$dir/manifest.json"
  err "集計できるデータがありません (status=failed)。詳細: jq .issues $dir/manifest.json"
  jq -r '.issues[] | "  [\(.severity)] \(.host) \(.artifact): \(.message)"' "$dir/manifest.json" | head -20 >&2
  exit "$EX_FAIL"
fi
mv "$tmp/metrics.json" "$dir/metrics.json"
mv "$tmp/manifest.json" "$dir/manifest.json"
log "集計しました: status=$status, API $napi 種, SQL $nsql 種 ($dir)"
"$ISU_SCRIPTS_DIR/agent-context.sh" "$run"
