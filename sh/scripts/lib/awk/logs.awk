# evidence.sh logs: API_ID とエラー・ステータス・時間帯で元のアクセスログを絞り込む（ストリーム処理）。
# 一致した行を数えながら、offset〜offset+limit 件目だけを元ログの位置（host:行）付きで出す。
BEGIN { load_groups(groups); if (st != "") { gsub(/x/, ".", st); st = "^" st "$" } }
FNR == 1 { n = split(FILENAME, pp, "/"); host = pp[n - 1] }
{
  ltsv($0); if (!("uri" in L)) next
  if (api_id(L["method"], api_group(L["uri"])) != want) next
  if (errors == 1 && L["status"] !~ /^[45]/) next
  if (st != "" && L["status"] !~ st) next
  t = substr(L["time"], 12, 8); if ((from != "" && t < from) || (to != "" && t > to)) next
  m++
  if (m > off && m <= off + lim) printf "I\t%s:%d\t%s\t%s\t%s\treqtime=%s\t%s\n", host, FNR, L["time"], L["method"], L["status"], L["reqtime"], L["uri"]
}
END {
  printf "H\t# logs run=%s filter=%s sort=ファイル順 total=%d offset=%d limit=%d\n", run, filter, m, off, lim
  print "H\t# 列: 元ログの位置(host:行)\ttime\tmethod\tstatus\treqtime\turi"
  if (m > off + lim) print "M\tmore"
}
