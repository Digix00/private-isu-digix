# MySQL のスロークエリログを、正規化した SQL ごとに集計する。入力は raw/<host>/slow.log。
# 各エントリの開始バイト位置を記録し、sql-detail でサンプルを元ログから取り出せるようにする。
# -v meta=FILE -v fpfile=FILE（ID と正規化 SQL の全文）
# 出力 TSV: id count total avg max lock_total rows_sent rows_examined first_host first_off max_host max_off fp_head
function flush() {
  if (q == "") return
  fp = fingerprint(q); id = query_id(fp)
  if (!(id in cnt)) { fpt[id] = fp; fh[id] = host; fo[id] = start }
  cnt[id]++; tot[id] += qt; lk[id] += lt; rs_[id] += rs; re_[id] += re
  if (!(id in mx) || qt > mx[id]) { mx[id] = qt; mh[id] = host; mo[id] = start }
  entries++; q = ""; have = 0
}
FNR == 1 { flush(); off = 0; pt = 0; n = split(FILENAME, pp, "/"); host = pp[n - 1] }
{ len = length($0) + 1 }
/^# Time: / { flush(); start = off; pt = 1; off += len; next }
/^# User@Host: / { if (!pt) { flush(); start = off }; pt = 0; off += len; next }
/^# Query_time: / { qt = $3 + 0; lt = $5 + 0; rs = $7 + 0; re = $9 + 0; have = 1; off += len; next }
/^#/ { off += len; next }
# mysqld の再起動・ログの再オープン時に出るヘッダー
/^\/.*Version: / || /^Tcp port: / || /^Time +Id +Command/ { flush(); off += len; next }
/^SET timestamp=[0-9]+;$/ || /^use [^ ]+;$/ { off += len; next }
have { q = (q == "" ? $0 : q " " $0); off += len; next }
{ if ($0 != "") orphan++; off += len }
END {
  flush()
  for (id in cnt) {
    printf "%s\t%d\t%.6f\t%.6f\t%.6f\t%.6f\t%d\t%d\t%s\t%d\t%s\t%d\t%s\n", id, cnt[id], tot[id], tot[id] / cnt[id], mx[id],
      lk[id], rs_[id], re_[id], fh[id], fo[id], mh[id], mo[id], cut(fpt[id], 200)
    printf "%s\t%s\n", id, fpt[id] > fpfile
  }
  printf "entries=%d\nunparsed=%d\n", entries, orphan > meta
}
