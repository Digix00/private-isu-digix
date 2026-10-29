# shellcheck shell=bash
# 出力量の上限制御（UTF-8 のバイト数）。awk の C ロケールでバイト単位に処理する。
#
# 入力の各行は種別の接頭辞を持つ:
#   H<TAB>text  ヘッダー（常に表示。収まらなければエラー）
#   I<TAB>text  項目（1行=1件。上限内に収まるだけ表示）
#   M<TAB>more  上限件数の外にまだ項目があることを示す（表示はしない）
#   F<TAB>text  フッター（常に表示）
# 1行が FIELD_MAX*2 バイトを超える場合は UTF-8 の文字境界で切り詰める。
#
# bounded_output MAX_BYTES OFFSET NEXT_CMD [PAGE]
#   PAGE を指定すると、続きの offset を「OFFSET + 表示件数」ではなく「OFFSET + PAGE」にする
#   （1ページに複数の一覧を含む compare.sh 用。バイト上限で途中が省略された場合は --limit を減らすよう案内する）
bounded_output() {
  LC_ALL=C awk -v max="$1" -v off="$2" -v nextcmd="$3" -v page="${4:-0}" -v fmax="$((ISU_FIELD_MAX_BYTES * 2))" '
    BEGIN { for (i = 1; i < 256; i++) ord[sprintf("%c", i)] = i }
    function cut(s, n,   L, p, b, need) {
      if (length(s) <= n) return s
      s = substr(s, 1, n - 3); L = length(s); p = L
      while (p > 0 && ord[substr(s, p, 1)] >= 128 && ord[substr(s, p, 1)] < 192) p--
      if (p > 0) {
        b = ord[substr(s, p, 1)]
        need = (b >= 240) ? 4 : (b >= 224) ? 3 : (b >= 192) ? 2 : 1
        if (L - p + 1 < need) s = substr(s, 1, p - 1)
      }
      return s "..."
    }
    {
      kind = substr($0, 1, 1); text = cut(substr($0, 3), fmax)
      if (kind == "H") hdr[++nh] = text
      else if (kind == "I") item[++ni] = text
      else if (kind == "F") ftr[++nf] = text
      else if (kind == "M") more = 1
    }
    END {
      used = 0
      for (i = 1; i <= nh; i++) used += length(hdr[i]) + 1
      for (i = 1; i <= nf; i++) used += length(ftr[i]) + 1
      reserve = 200 + length(nextcmd)
      if (used + reserve > max) {
        printf "error: 上限 %d バイトにヘッダーとメタデータが収まりません。--max-bytes を増やしてください\n", max > "/dev/stderr"
        exit 2
      }
      k = 0
      for (i = 1; i <= ni; i++) {
        if (used + length(item[i]) + 1 + reserve > max) { cutbytes = 1; break }
        used += length(item[i]) + 1; k++
      }
      if (ni > 0 && k == 0) {
        printf "error: 上限 %d バイトでは1件も表示できません。--max-bytes を増やしてください\n", max > "/dev/stderr"
        exit 2
      }
      for (i = 1; i <= nh; i++) print hdr[i]
      for (i = 1; i <= k; i++) print item[i]
      for (i = 1; i <= nf; i++) print ftr[i]
      printf "--- 返却: %d 件 (offset %d から) / バイト上限 %d による省略: %s\n", k, off, max, (cutbytes ? "あり" : "なし")
      if (page > 0 && cutbytes) print "--- 続き: バイト上限で途中を省略した。--limit を小さくするか --max-bytes を増やして再実行"
      else if (page > 0 && more) print "--- 続き: " nextcmd " --offset " (off + page)
      else if ((cutbytes || more) && nextcmd == "") print "--- 続き: 省略した項目は scripts/evidence.sh で取得できます"
      else if (cutbytes || more) { nc = nextcmd; if (!sub(/%OFFSET%/, off + k, nc)) nc = nc " --offset " (off + k); print "--- 続き: " nc }
      else print "--- 続き: なし（最後まで表示済み）"
    }'
}

# 生テキスト（ログ行など）を項目として流す。各行の先頭に I<TAB> を付ける。
as_items() { LC_ALL=C awk '{ print "I\t" $0 }'; }
