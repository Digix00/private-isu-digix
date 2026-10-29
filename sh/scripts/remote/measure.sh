# 計測の開始・終了・回収・pprof 取得（対象ホスト側）。
# ACTION=start|stop|fetch|profile|status, RUN_ID, TOKEN, ROLES, ACCESS_LOG, LOG_FORMAT, SLOW_LOG,
# COLLECTORS, INTERVAL, MYSQL_CLI, APP_BIN, PPROF_URL, PROFILE_TYPE, PROFILE_SECONDS
RUN="$STATE_DIR/runs/$RUN_ID"
read -ra MYSQL <<<"${MYSQL_CLI:-sudo -n mysql}"
has_role() { [[ " $ROLES " == *" $1 "* ]]; }
pos() { "${SUDO[@]}" stat -c '%i %s' "$1" 2>/dev/null || echo "- -"; }
mask() { sed -E 's/((PASS|PASSWORD|SECRET|TOKEN|KEY|DSN)[A-Za-z0-9_]*[[:space:]=:]+)[^[:space:];"]+/\1****/Ig'; }

# 記録用プロセスが自分の起動したものか。PID だけを信用せず、Linux では環境変数のトークン、
# /proc がない環境では起動時に記録した開始時刻と実行ファイル名（ps -o lstart,comm）が一致することを確認する。
pident() { ps -o lstart= -o comm= -p "$1" 2>/dev/null | tr -s " " | sed "s/^ //; s/ $//"; }
is_ours() {
  local pid="$1" started="$2"
  if [[ -r "/proc/$pid/environ" ]]; then
    tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | grep -qxF "ISU_MEASURE_TOKEN=$TOKEN"
  else
    [[ -n "$started" && "$(pident "$pid")" == "$started" ]]
  fi
}

# ログの [開始位置, 終了位置) を切り出す。ローテーションされていたら旧ファイルを inode で探す。
slice() {
  local name="$1" file="$2" si="$3" so="$4" ei es old st=complete reason=""
  read -r ei es < <(pos "$file")
  if [[ "$si" == - ]]; then st=missing reason="開始時にファイルがなかった: $file"
  elif [[ "$ei" == - ]]; then st=missing reason="終了時にファイルがない: $file"
  elif [[ "$ei" == "$si" && "$es" -eq "$so" ]]; then
    : >"$RUN/$name.log"   # 計測中に1行も書かれなかった
  elif [[ "$ei" == "$si" && "$es" -gt "$so" ]]; then
    "${SUDO[@]}" tail -c +"$((so + 1))" "$file" | head -c "$((es - so))" >"$RUN/$name.log"
  elif [[ "$ei" == "$si" ]]; then
    st=partial reason="計測中にファイルが切り詰められた（開始位置より小さい）。現在の内容だけを回収"
    "${SUDO[@]}" cat "$file" >"$RUN/$name.log"
  else
    old="$("${SUDO[@]}" find "$(dirname "$file")" -maxdepth 1 -inum "$si" -print -quit 2>/dev/null || true)"
    if [[ -n "$old" && "$old" != *.gz ]]; then
      { "${SUDO[@]}" tail -c +"$((so + 1))" "$old"; "${SUDO[@]}" head -c "$es" "$file"; } >"$RUN/$name.log"
      reason="計測中にローテーションされた（$old と $file をつないで回収）"
    else
      st=partial reason="計測中にローテーションされ、旧ファイルが見つからない（圧縮済み?）。ローテーション後の分だけを回収"
      "${SUDO[@]}" head -c "$es" "$file" >"$RUN/$name.log"
    fi
  fi
  printf '%s_end_inode=%s\n%s_end_offset=%s\n%s_status=%s\n%s_reason=%s\n' "$name" "$ei" "$name" "$es" "$name" "$st" "$name" "$reason"
}

case "$ACTION" in
  start)
    [[ -e "$RUN" ]] && rdie "この実行IDのデータが対象ホストに既にあります: $RUN" 2
    mkdir -p "$RUN"
    {
      echo "host=$HOST"
      echo "roles=$ROLES"
      echo "started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      if has_role nginx; then
        read -r i s < <(pos "$ACCESS_LOG")
        printf 'access_log=%s\naccess_log_start_inode=%s\naccess_log_start_offset=%s\n' "$ACCESS_LOG" "$i" "$s"
        conf="$("${SUDO[@]}" nginx -T 2>/dev/null | awk -v p="$ACCESS_LOG" '$1 == "access_log" && $2 == p' || true)"
        grep -q "[[:space:]]$LOG_FORMAT" <<<"$conf" && echo "access_log_format=$LOG_FORMAT" || echo "access_log_format=unknown"
        grep -qE 'buffer=|flush=' <<<"$conf" && echo "access_log_buffered=yes" || echo "access_log_buffered=no"
      fi
      if has_role mysql; then
        read -r i s < <(pos "$SLOW_LOG")
        printf 'slow_log=%s\nslow_log_start_inode=%s\nslow_log_start_offset=%s\n' "$SLOW_LOG" "$i" "$s"
        if v="$("${MYSQL[@]}" -NBe 'SELECT @@GLOBAL.slow_query_log, @@GLOBAL.long_query_time, @@GLOBAL.log_output, @@GLOBAL.slow_query_log_file' 2>/dev/null)"; then
          IFS=$'\t' read -r a b c d <<<"$v"
          printf 'mysql_slow_query_log=%s\nmysql_long_query_time=%s\nmysql_log_output=%s\nmysql_slow_query_log_file=%s\n' "$a" "$b" "$c" "$d"
        else
          echo "mysql_settings=unknown"
        fi
      fi
      if has_role app; then
        [[ -f "$STATE_DIR/deployed-app.env" ]] && cat "$STATE_DIR/deployed-app.env"
        echo "app_bin_sha256_at_start=$("${SUDO[@]}" sha256sum "$APP_BIN" 2>/dev/null | awk '{print $1}')"
      fi
    } >"$RUN/start.env"
    started_pids=()
    for c in $COLLECTORS; do
      case "$c" in
        vmstat) cmd=(vmstat -n -t "$INTERVAL") ;;
        pidstat) cmd=(pidstat -h -u -r "$INTERVAL") ;;
        iostat) cmd=(iostat -x -t -y "$INTERVAL") ;;
        *) echo "collector_$c=unknown" >>"$RUN/start.env"; continue ;;
      esac
      have "${cmd[0]}" || { echo "collector_$c=missing" >>"$RUN/start.env"; continue; }
      nohup env ISU_MEASURE_TOKEN="$TOKEN" LC_ALL=C S_TIME_FORMAT=ISO "${cmd[@]}" >"$RUN/$c.log" 2>&1 </dev/null &
      started_pids+=("$c:$!")
      echo "collector_$c=started" >>"$RUN/start.env"
    done
    # nohup → env → 本体 の exec が終わってから識別情報（開始時刻・実行ファイル名）を記録する
    sleep 1
    : >"$RUN/pids"
    for cp in "${started_pids[@]}"; do echo "${cp%%:*} ${cp#*:} $(pident "${cp#*:}")" >>"$RUN/pids"; done
    cat "$RUN/start.env"
    ;;

  stop)
    [[ -d "$RUN" ]] || rdie "この実行IDの計測データがありません: $RUN"
    # 再実行しても同じ結果になるようにする（切り出し済みなら記録を返すだけ）
    [[ -f "$RUN/stop.env" ]] && { cat "$RUN/stop.env"; exit 0; }
    # shellcheck source=/dev/null
    source <(grep -E '^(access_log|slow_log)_start_(inode|offset)=' "$RUN/start.env")
    {
      if [[ -f "$RUN/pids" ]]; then
        while read -r name pid started; do
          if is_ours "$pid" "$started"; then kill -TERM "$pid" && echo "collector_$name=stopped"
          else echo "collector_$name=not_running"; fi   # 途中で終了した、または別のプロセス（停止しない）
        done <"$RUN/pids"
        mv "$RUN/pids" "$RUN/pids.done"
      fi
      sleep 1
      has_role nginx && slice access "$ACCESS_LOG" "${access_log_start_inode:--}" "${access_log_start_offset:-0}"
      has_role mysql && slice slow "$SLOW_LOG" "${slow_log_start_inode:--}" "${slow_log_start_offset:-0}"
      if has_role nginx; then "${SUDO[@]}" nginx -T 2>/dev/null | mask >"$RUN/snap-nginx-T.txt" || true; fi
      if has_role mysql; then
        "${MYSQL[@]}" -Be "SHOW GLOBAL VARIABLES" 2>/dev/null | mask >"$RUN/snap-mysql-variables.tsv" || true
        "${MYSQL[@]}" -Be "SELECT table_schema, table_name, index_name, seq_in_index, column_name, non_unique FROM information_schema.statistics WHERE table_schema NOT IN ('mysql','sys','performance_schema','information_schema') ORDER BY 1,2,3,4" >"$RUN/snap-mysql-indexes.tsv" 2>/dev/null || true
        "${MYSQL[@]}" -Be "SELECT table_schema, table_name, table_rows, data_length, index_length FROM information_schema.tables WHERE table_schema NOT IN ('mysql','sys','performance_schema','information_schema') ORDER BY 1,2" >"$RUN/snap-mysql-tables.tsv" 2>/dev/null || true
      fi
      echo "stopped_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } >"$RUN/stop.env.tmp"
    mv "$RUN/stop.env.tmp" "$RUN/stop.env"
    cat "$RUN/stop.env"
    ;;

  fetch)
    [[ -f "$RUN/stop.env" ]] || rdie "stop が終わっていません: $RUN"
    tar -czf - -C "$RUN" .
    ;;

  profile)
    [[ -f "$RUN/pids" ]] || rdie "この実行IDは計測中ではありません: $RUN_ID"
    case "$PROFILE_TYPE" in
      cpu) path="profile?seconds=$PROFILE_SECONDS" ;;
      heap | allocs | goroutine | block | mutex) path="$PROFILE_TYPE" ;;
      *) rdie "未対応のプロファイル: $PROFILE_TYPE" 2 ;;
    esac
    f="$RUN/pprof-$PROFILE_TYPE-$(date +%H%M%S).pb.gz"
    rlog "取得中: $PPROF_URL/debug/pprof/$path"
    curl -fsS -m "$((PROFILE_SECONDS + 30))" -o "$f" "$PPROF_URL/debug/pprof/$path" || {
      rm -f "$f"
      rdie "pprof の取得に失敗しました: $PPROF_URL（アプリに pprof を組み込み、ISU_PPROF を設定して起動しているか確認）"
    }
    echo "profile=$(basename "$f")"
    ;;

  status)
    if [[ ! -d "$RUN" ]]; then echo "run: なし"; exit 0; fi
    [[ -f "$RUN/stop.env" ]] && echo "run: stop 済み" || echo "run: 計測中または stop 未完了"
    if [[ -f "$RUN/pids" ]]; then
      while read -r name pid started; do
        is_ours "$pid" "$started" && echo "  $name (pid $pid): 実行中" || echo "  $name (pid $pid): 停止済み（または別のプロセス）"
      done <"$RUN/pids"
    fi
    # shellcheck disable=SC2012 # 人が見るための一覧
    ls -l "$RUN" | sed 's/^/  /'
    ;;
  *) rdie "unknown ACTION: $ACTION" ;;
esac
