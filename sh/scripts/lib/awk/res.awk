# vmstat / pidstat / iostat の記録を要約する。-v kind=vmstat|pidstat|iostat -v host=HOST
#   vmstat : host samples us sy wa id busy_peak_10s first last
#   pidstat: host command avg_cpu max_cpu max_rss_kb   （平均は記録した全時刻に対する平均。いない時刻は 0）
#   iostat : host device avg_util max_util avg_r_s avg_w_s
# -v bucket=N を付けた vmstat は、N 秒ごとの時系列（host time us sy wa id）を出す（-v from/to で絞り込み）。
function col(name) { return (name in H) ? $(H[name]) + 0 : 0 }

kind == "vmstat" && $1 == "r" { for (i = 1; i <= NF; i++) H[$i] = i; next }
kind == "vmstat" && $1 ~ /^[0-9]+$/ && ("id" in H) {
  if (!skipped) { skipped = 1; next }  # 1行目は起動からの平均なので使わない
  ts = $(NF - 1) " " $NF
  if ((from != "" && ts < from) || (to != "" && ts > to)) next
  n++; us += col("us"); sy += col("sy"); wa += col("wa"); idl += col("id")
  if (first == "") first = ts; last = ts
  b = (bucket > 0) ? bucket : 10
  sec = substr(ts, 18, 2) + 0; bk = substr(ts, 1, 17) sprintf("%02d", int(sec / b) * b)
  if (!(bk in bn)) order[++nb] = bk
  bn[bk]++; bus[bk] += col("us"); bsy[bk] += col("sy"); bwa[bk] += col("wa"); bid[bk] += col("id")
  next
}

kind == "pidstat" && $1 == "#" && $2 == "Time" { for (i = 2; i <= NF; i++) H[$i] = i - 1; next }
kind == "pidstat" && $1 !~ /^#/ && ("%CPU" in H) && NF >= H["Command"] {
  cmd = $(H["Command"]); c = col("%CPU")
  if (!($1 in seen)) { seen[$1] = 1; times++ }
  cpu[cmd] += c; if (c > cmax[cmd]) cmax[cmd] = c
  if (col("RSS") > rss[cmd]) rss[cmd] = col("RSS")
  next
}

kind == "iostat" && $1 == "Device" { for (i = 1; i <= NF; i++) H[$i] = i; dev = 1; next }
kind == "iostat" && dev && NF == 0 { dev = 0; next }
kind == "iostat" && dev && $1 !~ /^loop/ {
  d = $1; dn[d]++; u = col("%util"); du[d] += u; if (u > dm[d]) dm[d] = u
  dr[d] += col("r/s"); dw[d] += col("w/s")
  next
}

END {
  if (kind == "vmstat" && bucket > 0) {
    for (i = 1; i <= nb; i++) { k = order[i]
      printf "%s\t%s\t%.1f\t%.1f\t%.1f\t%.1f\n", host, k, bus[k] / bn[k], bsy[k] / bn[k], bwa[k] / bn[k], bid[k] / bn[k] }
  } else if (kind == "vmstat" && n) {
    peak = 0
    for (k in bn) { v = 100 - bid[k] / bn[k]; if (v > peak) peak = v }
    printf "%s\t%d\t%.1f\t%.1f\t%.1f\t%.1f\t%.1f\t%s\t%s\n", host, n, us / n, sy / n, wa / n, idl / n, peak, first, last
  } else if (kind == "pidstat" && times) {
    for (k in cpu) printf "%s\t%s\t%.1f\t%.1f\t%d\n", host, k, cpu[k] / times, cmax[k], rss[k]
  } else if (kind == "iostat") {
    for (d in dn) printf "%s\t%s\t%.1f\t%.1f\t%.1f\t%.1f\n", host, d, du[d] / dn[d], dm[d], dr[d] / dn[d], dw[d] / dn[d]
  }
}
