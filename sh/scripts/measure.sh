#!/usr/bin/env bash
# shellcheck disable=SC2016 # jq のプログラムは意図してシングルクォートで書く
#? 使い方:
#?   scripts/measure.sh start   RUN_ID [--baseline RUN_ID] [--note TEXT] [--host HOST]...
#?   scripts/measure.sh mark    RUN_ID LABEL            # 例: load-start / load-end（任意）
#?   scripts/measure.sh profile RUN_ID [--type cpu|heap|allocs|goroutine|block|mutex] [--seconds N] [--host HOST]...
#?   scripts/measure.sh stop    RUN_ID
#?   scripts/measure.sh status  RUN_ID
#?   scripts/measure.sh result  RUN_ID --pass true|false [--score N] [--errors N] [--message TEXT]
#?
#? ベンチ1回分の計測を行う。ベンチ自体は利用者が手動で実行する。
#?   start   対象ホストに計測ロックを取り（この間 deploy は拒否される）、ログの現在位置を記録し、
#?           vmstat / pidstat / iostat（ISU_MEASURE_COLLECTORS）を起動する。MySQL は再起動しない
#?   profile 計測中に app 役のホストで pprof を取得する（CPU 等は必要なときだけ。既定 cpu 30 秒）
#?   stop    自分が起動した記録用プロセスだけを停止し、start〜stop の区間のログを切り出して回収、ロックを解除
#?           失敗しても再実行できる（回収済みのホストは飛ばす）
#?   result  ベンチのスコア・成否・エラー数を記録する（未記録の項目は null のまま）
#? 実行ID は英数字で始まり、英数字 . _ - のみ。既存の実行IDは上書きしない。
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$ISU_LIB_DIR/config.sh"
source "$ISU_LIB_DIR/remote.sh"
source "$ISU_LIB_DIR/lock.sh"
source "$ISU_LIB_DIR/results.sh"

action="${1:-}"
[[ "$action" == -h || "$action" == --help || -z "$action" ]] && { print_help; [[ -n "$action" ]]; exit $?; }
[[ "$action" =~ ^(start|mark|profile|stop|status|result)$ ]] || usage_error "不明なサブコマンド: $action"
[[ $# -ge 2 ]] || usage_error "実行IDを指定してください"
run="$2"
validate_run_id "$run"
shift 2

hosts=() baseline="" note="" ptype=cpu pseconds="" label="" pass="" score="" errors="" message=""
while (($#)); do
  case "$1" in
    --host) [[ $# -ge 2 ]] || usage_error "--host に値が必要です"; hosts+=("$2"); shift 2 ;;
    --baseline) [[ $# -ge 2 ]] || usage_error "--baseline に値が必要です"; baseline="$2"; validate_run_id "$2"; shift 2 ;;
    --note) [[ $# -ge 2 ]] || usage_error "--note に値が必要です"; note="$2"; shift 2 ;;
    --type) [[ $# -ge 2 ]] || usage_error "--type に値が必要です"; ptype="$2"; shift 2 ;;
    --seconds) [[ "${2:-}" =~ ^[0-9]+$ ]] && (($2 >= 1 && $2 <= 300)) || usage_error "--seconds は 1〜300 の整数です"; pseconds="$2"; shift 2 ;;
    --pass) [[ "${2:-}" =~ ^(true|false)$ ]] || usage_error "--pass は true か false です"; pass="$2"; shift 2 ;;
    --score) [[ "${2:-}" =~ ^-?[0-9]+$ ]] || usage_error "--score は整数です"; score="$2"; shift 2 ;;
    --errors) [[ "${2:-}" =~ ^[0-9]+$ ]] || usage_error "--errors は0以上の整数です"; errors="$2"; shift 2 ;;
    --message) [[ $# -ge 2 ]] || usage_error "--message に値が必要です"; message="$2"; shift 2 ;;
    -h | --help) print_help; exit 0 ;;
    -*) usage_error "不明な引数: $1" ;;
    *) [[ "$action" == mark && -z "$label" ]] || usage_error "不明な引数: $1"; label="$1"; shift ;;
  esac
done
[[ "$ptype" =~ ^(cpu|heap|allocs|goroutine|block|mutex)$ ]] || usage_error "--type が不正です: $ptype"

require_cmd ssh jq tar
load_config
: "${ISU_MEASURE_COLLECTORS:=vmstat pidstat iostat}" "${ISU_MEASURE_INTERVAL:=1}"
: "${ISU_NGINX_ACCESS_LOG:=/var/log/nginx/access.log}" "${ISU_NGINX_LOG_FORMAT:=isucon_ltsv}"
: "${ISU_MYSQL_SLOW_LOG:=/var/log/mysql/mysql-slow.log}" "${ISU_MYSQL_CLI:=sudo -n mysql}"
: "${ISU_PPROF_URL:=http://127.0.0.1:6060}" "${ISU_PPROF_SECONDS:=30}" "${ISU_APP_REMOTE_BIN:=}"
[[ -v ISU_API_GROUPS ]] || ISU_API_GROUPS=()
dir="$(run_dir "$run")"

remote_measure() {
  local h="$1"
  shift
  remote_run "$h" measure.sh "RUN_ID=$run" "TOKEN=$(jq -r .token "$dir/run.json")" "ROLES=${ISU_ROLES[$h]:-}" \
    "ACCESS_LOG=$ISU_NGINX_ACCESS_LOG" "LOG_FORMAT=$ISU_NGINX_LOG_FORMAT" "SLOW_LOG=$ISU_MYSQL_SLOW_LOG" \
    "COLLECTORS=$ISU_MEASURE_COLLECTORS" "INTERVAL=$ISU_MEASURE_INTERVAL" "MYSQL_CLI=$ISU_MYSQL_CLI" \
    "APP_BIN=$ISU_APP_REMOTE_BIN" "PPROF_URL=$ISU_PPROF_URL" "$@"
}
run_hosts() { jq -r '.hosts[].name' "$dir/run.json"; }
require_collecting() {
  require_run "$run"
  [[ "$(jq -r .status "$dir/run.json")" == collecting ]] || die "実行ID '$run' は計測中ではありません (status: $(jq -r .status "$dir/run.json"))"
}

case "$action" in
  start)
    cfg_no_todo ISU_APP_REMOTE_BIN ISU_NGINX_ACCESS_LOG ISU_MYSQL_SLOW_LOG
    targets="$(select_hosts "${hosts[@]}")"
    mkdir -p "$ISU_RESULTS_DIR"
    # mkdir が失敗する = 既に存在する。既存の結果は上書きしない
    mkdir "$dir" 2>/dev/null || die "実行ID '$run' の結果が既にあります: $dir（別の実行IDを使ってください）" "$EX_USAGE"
    [[ -z "$baseline" || -f "$(run_dir "$baseline")/run.json" ]] || warn "基準の実行ID '$baseline' の結果がまだありません"
    lock_id="$(new_lock_id)"
    # shellcheck disable=SC2086 # ホスト名は検証済み
    if ! lock_acquire_all "$lock_id" measure "$run" $targets; then rmdir "$dir"; exit "$EX_LOCKED"; fi
    mkdir -p "$dir/raw" "$dir/snapshots"
    hosts_json="$(for h in $targets; do jq -n --arg n "$h" --arg r "${ISU_ROLES[$h]:-}" '{name: $n, roles: ($r | split(" ") | map(select(. != "")))}'; done | jq -s .)"
    groups_json="$(printf '%s\n' "${ISU_API_GROUPS[@]}" | jq -R -s 'split("\n") | map(select(. != ""))')"
    jq -n --arg run "$run" --arg base "$baseline" --arg note "$note" --arg at "$(now_iso)" --arg lock "$lock_id" \
      --arg token "$run.$lock_id" --argjson hosts "$hosts_json" --argjson groups "$groups_json" \
      --argjson code "$(local_code_json "$dir/snapshots/local-diff.patch")" \
      --arg col "$ISU_MEASURE_COLLECTORS" --arg iv "$ISU_MEASURE_INTERVAL" --arg al "$ISU_NGINX_ACCESS_LOG" --arg sl "$ISU_MYSQL_SLOW_LOG" \
      '{format_version: 1, run_id: $run, baseline_run_id: (if $base == "" then null else $base end),
        note: (if $note == "" then null else $note end), status: "collecting", started_at: $at, stopped_at: null,
        lock_id: $lock, token: $token, hosts: $hosts, local_code: $code, marks: [], profiles: [], stop_errors: [],
        conditions: {collectors: ($col | split(" ") | map(select(. != ""))), interval_sec: ($iv | tonumber),
          access_log: $al, slow_log: $sl, api_groups: $groups}}' | atomic_write "$dir/run.json"
    statuses=()
    for h in $targets; do
      mkdir -p "$dir/raw/$h"
      rc=0
      remote_measure "$h" ACTION=start >"$dir/raw/$h/start.env" || rc=$?
      statuses+=("$h=$rc")
      grep -E '^collector_|^access_log_format|^access_log_buffered|^mysql_slow_query_log=|^mysql_long_query_time' "$dir/raw/$h/start.env" | sed "s/^/  [$h] /" >&2 || true
      grep -q '^access_log_buffered=yes' "$dir/raw/$h/start.env" && warn "$h: access_log にバッファ指定があります。stop 時に末尾が欠ける可能性があります"
      grep -q '^access_log_format=unknown' "$dir/raw/$h/start.env" && warn "$h: access_log が $ISU_NGINX_LOG_FORMAT 形式か確認できません（集計できない可能性）"
    done
    log "計測を開始しました: $run （ベンチを実行し、終わったら scripts/measure.sh stop $run）"
    report_hosts "measure start" "${statuses[@]}" || {
      err "開始に失敗したホストがあります。この実行を続けるか、scripts/measure.sh stop $run で回収・ロック解除してください"
      exit "$EX_FAIL"
    }
    ;;

  mark)
    require_collecting
    [[ -n "$label" && "$label" =~ ^[A-Za-z0-9._-]{1,40}$ ]] || usage_error "LABEL は英数字 . _ - の40文字以内です"
    json_update "$dir/run.json" --arg l "$label" --arg at "$(now_iso)" '.marks += [{label: $l, at: $at}]'
    log "mark: $label ($(now_iso)、手元の時刻)"
    ;;

  profile)
    require_collecting
    seconds="${pseconds:-$ISU_PPROF_SECONDS}"
    statuses=()
    for h in $(run_hosts); do
      host_has_role "$h" app || continue
      ((${#hosts[@]} == 0)) || [[ " ${hosts[*]} " == *" $h "* ]] || continue
      rc=0
      out="$(remote_measure "$h" ACTION=profile "PROFILE_TYPE=$ptype" "PROFILE_SECONDS=$seconds")" || rc=$?
      statuses+=("$h=$rc")
      ((rc == 0)) && json_update "$dir/run.json" --arg h "$h" --arg f "${out#profile=}" --arg t "$ptype" --argjson s "$seconds" --arg at "$(now_iso)" \
        '.profiles += [{host: $h, file: $f, type: $t, seconds: $s, at: $at}]'
    done
    report_hosts "measure profile ($ptype)" "${statuses[@]}"
    ;;

  stop)
    require_run "$run"
    st="$(jq -r .status "$dir/run.json")"
    [[ "$st" == collecting || "$st" == stop_incomplete ]] || die "実行ID '$run' は既に stop 済みです (status: $st)"
    lock_id="$(jq -r .lock_id "$dir/run.json")"
    statuses=() failed=()
    for h in $(run_hosts); do
      if [[ -f "$dir/raw/$h/.fetched" ]]; then statuses+=("$h=0"); continue; fi
      rc=0
      { remote_measure "$h" ACTION=stop >"$dir/raw/$h/stop.env.tmp" &&
        mv "$dir/raw/$h/stop.env.tmp" "$dir/raw/$h/stop.env" &&
        mkdir -p "$dir/raw/$h/.incoming" &&
        remote_measure "$h" ACTION=fetch | tar -xzf - -C "$dir/raw/$h/.incoming"; } || rc=$?
      if ((rc == 0)); then
        # 回収したデータを配置し、設定のスナップショットは snapshots/ へ分ける
        mkdir -p "$dir/snapshots/$h"
        for f in "$dir/raw/$h/.incoming"/*; do
          case "$(basename "$f")" in
            snap-*) mv "$f" "$dir/snapshots/$h/$(basename "$f" | sed 's/^snap-//')" ;;
            start.env | stop.env | stop.env.tmp | pids.done) rm -f "$f" ;;
            *) mv "$f" "$dir/raw/$h/" ;;
          esac
        done
        rmdir "$dir/raw/$h/.incoming"
        touch "$dir/raw/$h/.fetched"
        chmod -R a-w "$dir/raw/$h"
        remote_run "$h" lock.sh ACTION=release "LOCK_ID=$lock_id" || warn "$h のロック解除に失敗しました（scripts/lock.sh status --host $h）"
      else
        rm -rf "$dir/raw/$h/.incoming" "$dir/raw/$h/stop.env.tmp"
        failed+=("$h")
      fi
      statuses+=("$h=$rc")
    done
    if ((${#failed[@]})); then
      json_update "$dir/run.json" --arg at "$(now_iso)" --arg f "${failed[*]}" '.status = "stop_incomplete" | .stop_errors += [{at: $at, hosts: ($f | split(" "))}]'
      err "回収できなかったホスト: ${failed[*]}。原因を確認して scripts/measure.sh stop $run を再実行してください（回収済みのホストは飛ばします）"
    else
      json_update "$dir/run.json" --arg at "$(now_iso)" '.status = "collected" | .stopped_at = $at'
      log "回収しました: $dir （次: scripts/measure.sh result $run --pass true --score N、scripts/report.sh $run）"
    fi
    report_hosts "measure stop" "${statuses[@]}"
    ;;

  status)
    require_run "$run"
    jq -r '"run: \(.run_id)  status: \(.status)  started: \(.started_at)  stopped: \(.stopped_at // "-")  lock: \(.lock_id)",
      "hosts: \([.hosts[] | .name + "(" + (.roles | join(",")) + ")"] | join(" "))",
      "profiles: \(.profiles | length)  marks: \([.marks[].label] | join(","))"' "$dir/run.json"
    statuses=()
    for h in $(run_hosts); do
      echo "### $h"
      rc=0
      { remote_run "$h" lock.sh ACTION=status && remote_measure "$h" ACTION=status; } || rc=$?
      statuses+=("$h=$rc")
    done
    report_hosts "measure status" "${statuses[@]}"
    ;;

  result)
    require_run "$run"
    [[ -n "$pass" ]] || usage_error "--pass true|false を指定してください"
    jq -n --argjson p "$pass" --arg s "$score" --arg e "$errors" --arg m "$message" --arg at "$(now_iso)" \
      '{pass: $p, score: (if $s == "" then null else ($s | tonumber) end), errors: (if $e == "" then null else ($e | tonumber) end),
        message: (if $m == "" then null else $m end), recorded_at: $at}' | atomic_write "$dir/bench.json"
    log "ベンチ結果を記録しました: $dir/bench.json"
    ;;
esac
