# nginx の LTSV アクセスログを API（メソッド + グループ）ごとに集計する。入力は raw/<host>/access.log。
# -v groups=FILE  -v meta=FILE
# 出力 TSV: id method group count total_time avg_time max_time 2xx 3xx 4xx 5xx hosts
BEGIN { load_groups(groups) }
FNR == 1 { n = split(FILENAME, pp, "/"); host = pp[n - 1] }
{
  ltsv($0)
  if (!("uri" in L) || !("reqtime" in L)) { unparsed++; if (bad_sample == "") bad_sample = host ":" FNR; next }
  m = L["method"]; g = api_group(L["uri"]); k = m SUBSEP g
  t = L["reqtime"] + 0
  cnt[k]++; sum[k] += t; if (t > mx[k]) mx[k] = t
  c = substr(L["status"], 1, 1) "xx"; st[k, c]++
  if (!((k, host) in hc)) hl[k] = hl[k] (hl[k] == "" ? "" : ",") host
  hc[k, host]++
  ts = L["time"]; if (first == "" || ts < first) first = ts; if (ts > last) last = ts
  parsed++
}
END {
  for (k in cnt) {
    split(k, kk, SUBSEP); hs = ""
    nh = split(hl[k], hh, ",")
    for (i = 1; i <= nh; i++) hs = hs (i > 1 ? "," : "") hh[i] "=" hc[k, hh[i]]
    printf "%s\t%s\t%s\t%d\t%.6f\t%.6f\t%.6f\t%d\t%d\t%d\t%d\t%s\n", api_id(kk[1], kk[2]), kk[1], kk[2], cnt[k], sum[k],
      sum[k] / cnt[k], mx[k], st[k, "2xx"], st[k, "3xx"], st[k, "4xx"], st[k, "5xx"], hs
  }
  printf "parsed=%d\nunparsed=%d\nunparsed_sample=%s\nfirst=%s\nlast=%s\n", parsed, unparsed, bad_sample, first, last > meta
}
