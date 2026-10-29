# 読み取り専用の環境調査（対象ホスト側）。何も変更しない。
# 秘密情報らしき値（PASSWORD/SECRET/TOKEN/KEY を含む変数）は伏せて出力する。
mask() { sed -E 's/((PASS|PASSWORD|SECRET|TOKEN|KEY|DSN)[A-Za-z0-9_]*[=:][[:space:]]*)[^[:space:]"]+/\1****/Ig'; }
section() { printf '\n== %s\n' "$1"; }
try() { "$@" 2>&1 || echo "(失敗: $*)"; }

section "host"; try hostnamectl 2>/dev/null || hostname
section "os"; try cat /etc/os-release | grep -E '^(NAME|VERSION)='; uname -srm
section "cpu/mem"; echo "nproc: $(nproc)"; try free -h
section "disk"; try df -h -x tmpfs -x devtmpfs -x overlay
section "listening (ss -tlnp)"; try "${SUDO[@]}" ss -tlnp
section "running services"; try systemctl list-units --type=service --state=running --no-pager --no-legend
section "top processes (cpu)"; try ps -eo pid,user,pcpu,pmem,etime,comm --sort=-pcpu | head -15

section "nginx"
if have nginx; then
  try nginx -v
  "${SUDO[@]}" nginx -T 2>/dev/null | grep -E '^# configuration file|^\s*(access_log|error_log|log_format|include|upstream|proxy_pass|root)\b' | mask | head -80 || echo "(nginx -T を読めません: sudo 権限を確認)"
else echo "nginx: not found"; fi

section "mysql"
if have mysqld; then
  try mysqld --version
  echo "-- 読み込まれる設定ファイルの順序"
  mysqld --verbose --help 2>/dev/null | grep -A1 '^Default options' | tail -1 || true
  echo "-- 現在の主要設定 (sudo mysql が使える場合)"
  "${SUDO[@]}" mysql -NBe "SELECT @@version, @@slow_query_log, @@slow_query_log_file, @@long_query_time, @@log_output, @@innodb_buffer_pool_size, @@max_connections" 2>/dev/null ||
    echo "(sudo mysql で接続できません。認証方法を確認)"
else echo "mysqld: not found"; fi

section "systemd units of interest"
for u in $(systemctl list-units --type=service --state=running --no-legend --plain 2>/dev/null | awk '{print $1}' | grep -Ev '^(systemd|dbus|cron|ssh|snap|getty|rsyslog|polkit|udisks|multipathd|networkd|unattended|user@)' | head -10); do
  echo "--- $u"; systemctl cat "$u" 2>/dev/null | grep -E '^(ExecStart|WorkingDirectory|User|Environment|EnvironmentFile)=' | mask
done

section "tools"
for t in top htop pidstat iostat vmstat alp pt-query-digest go curl; do
  printf '%-16s %s\n' "$t" "$(command -v "$t" || echo '-')"
done
