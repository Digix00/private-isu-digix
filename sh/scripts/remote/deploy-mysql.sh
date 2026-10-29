# MySQL 設定の配置・検証・反映（対象ホスト側）。
# 入力: SERVICE, MODE=file|dynamic|restart, DYNAMIC_VARS（SET GLOBAL を許す変数名）, MYSQL_CLI
# ファイルへの反映 / 稼働中の値 / 再起動後に読まれる値（my_print_defaults）を区別して表示する。
read -ra MYSQL <<<"${MYSQL_CLI:-sudo -n mysql}"
files_install

# 検証: MySQL 8.0.16 以降の mysqld --validate-config（サーバーを起動せずに設定を読む）
ver="$(mysqld --version 2>/dev/null || true)"
num="$(grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' <<<"$ver" | head -1)"
if [[ "$ver" == *MariaDB* || -z "$num" ]] || ! printf '8.0.16\n%s\n' "$num" | sort -V -C; then
  files_restore
  rdie "このバージョンでは mysqld --validate-config を使えないため中止しました: ${ver:-不明}"
fi
if ! out="$("${SUDO[@]}" mysqld --validate-config --user=mysql 2>&1)"; then
  echo "$out" >&2
  files_restore
  rdie "mysqld --validate-config に失敗したため反映しません"
fi
rlog "mysqld --validate-config: ok ($num)"

# 管理ファイルの [mysqld] / [server] セクションにある key=value（キーの - は _ にそろえる）
parse_cnf() {
  awk '/^[[:space:]]*\[/ { s = ($0 ~ /^[[:space:]]*\[(mysqld|server)\]/); next }
       s { sub(/#.*/, ""); if ($0 !~ /[A-Za-z]/) next
           k = $0; v = "ON"; if (index($0, "=")) { k = substr($0, 1, index($0, "=") - 1); v = substr($0, index($0, "=") + 1) }
           gsub(/[[:space:]]|"/, "", k); gsub(/^[[:space:]"]+|[[:space:]"]+$/, "", v); gsub(/-/, "_", k)
           print k "\t" v }'
}
expected="$(for f in $(managed_files); do "${SUDO[@]}" cat "$f" | parse_cnf; done)"
persisted="$("${SUDO[@]}" my_print_defaults mysqld 2>/dev/null | sed 's/^--//' | awk -F= '{k=$1; gsub(/-/,"_",k); v=substr($0, length($1)+2); print k "\t" (index($0,"=") ? v : "ON")}')"

runtime() { [[ "$1" =~ ^[a-z0-9_]+$ ]] && "${MYSQL[@]}" -NBe "SELECT @@GLOBAL.$1" 2>/dev/null; }
same() { awk -v a="$1" -v b="$2" 'function n(x) { x = toupper(x); return x == "ON" ? 1 : x == "OFF" ? 0 : x }
  BEGIN { a = n(a); b = n(b); exit !((a == b) || (a ~ /^[0-9.]+$/ && b ~ /^[0-9.]+$/ && a + 0 == b + 0)) }'; }

fail=0
case "$MODE" in
  file) ;;
  dynamic)
    while IFS=$'\t' read -r k v; do
      [[ -n "$k" && " $DYNAMIC_VARS " == *" $k "* ]] || continue
      same "$(runtime "$k" || true)" "$v" && continue
      [[ "$v" =~ ^[A-Za-z0-9_./:-]+$ ]] || { rlog "$k の値 '$v' は SET GLOBAL できない文字を含むため省略"; fail=1; continue; }
      [[ "$v" =~ ^([0-9.]+|ON|OFF|on|off)$ ]] && sql="SET GLOBAL $k = $v" || sql="SET GLOBAL $k = '$v'"
      "${MYSQL[@]}" -e "$sql" && rlog "$sql" || { rlog "失敗: $sql"; fail=1; }
    done <<<"$expected"
    ;;
  restart)
    rlog "systemctl restart $SERVICE（明示的に --restart が指定されたため）"
    "${SUDO[@]}" systemctl restart "$SERVICE" || rdie "$SERVICE の再起動に失敗しました"
    for ((i = 0; i < 30; i++)); do systemctl is-active --quiet "$SERVICE" && break; sleep 1; done
    systemctl is-active --quiet "$SERVICE" || rdie "$SERVICE が active になりません"
    ;;
  *) rdie "unknown MODE: $MODE" ;;
esac

printf '%-32s %-14s %-14s %-14s %s\n' "変数" "ファイル" "稼働中" "再起動後" "状態"
while IFS=$'\t' read -r k v; do
  [[ -n "$k" ]] || continue
  r="$(runtime "$k" || echo '?')"
  p="$(awk -F'\t' -v k="$k" '$1 == k { v = $2 } END { print (v == "" ? "-" : v) }' <<<"$persisted")"
  st=""
  same "$r" "$v" || st+="稼働中と不一致($([[ " $DYNAMIC_VARS " == *" $k "* ]] && echo '--apply-dynamic で反映可' || echo '要 --restart')) "
  same "$p" "$v" || st+="再起動後は別の値(後から読まれる設定で上書き?) "
  printf '%-32s %-14s %-14s %-14s %s\n' "$k" "$v" "$r" "$p" "${st:-ok}"
done <<<"$expected"
[[ "$MODE" == dynamic ]] && rlog "注意: SET GLOBAL は既存の接続のセッション値を変えません。アプリの接続プールは再接続（アプリの再起動など）まで古い値のままです"
exit "$fail"
