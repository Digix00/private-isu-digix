# 集計で共有する awk 関数（POSIX awk の範囲。LC_ALL=C でバイト単位に動かす）。
# ID 生成・URL グルーピング・SQL 正規化を変えたときは、results.sh の ANALYZER_* のバージョンも上げること。

BEGIN { for (i = 1; i < 256; i++) ORD[sprintf("%c", i)] = i }

# 安定した短い ID（2つの多項式ハッシュ）。API_ID と QUERY_ID に使う。暗号学的な強さはない。
function hash12(s,   i, h1, h2, b) {
  h1 = 7; h2 = 11
  for (i = 1; i <= length(s); i++) {
    b = ORD[substr(s, i, 1)]
    h1 = (h1 * 31 + b) % 2147483647
    h2 = (h2 * 131 + b) % 2147483629
  }
  return sprintf("%08x%04x", h1, h2 % 65536)
}

# UTF-8 の文字境界で n バイト以内に切り詰める
function cut(s, n,   L, p, b, need) {
  if (length(s) <= n) return s
  s = substr(s, 1, n - 3); L = length(s); p = L
  while (p > 0 && ORD[substr(s, p, 1)] >= 128 && ORD[substr(s, p, 1)] < 192) p--
  if (p > 0) {
    b = ORD[substr(s, p, 1)]
    need = (b >= 240) ? 4 : (b >= 224) ? 3 : (b >= 192) ? 2 : 1
    if (L - p + 1 < need) s = substr(s, 1, p - 1)
  }
  return s "..."
}

# URL グルーピング: クエリ文字列を除き、設定した正規表現（ERE）に上から順に当てはめる。
# 一致した正規表現そのものをグループ名にする（alp の -m と同じ表示）。どれにも一致しなければパスのまま。
function load_groups(file,   line) {
  NG = 0
  while ((getline line < file) > 0) if (line != "") GRP[++NG] = line
  close(file)
}
function api_group(path,   i) {
  sub(/\?.*/, "", path)
  for (i = 1; i <= NG; i++) if (path ~ GRP[i]) return GRP[i]
  return path
}
function api_id(method, group) { return "a" hash12(method " " group) }

# LTSV の1行を L[ラベル] に展開する
function ltsv(line,   n, i, f, p) {
  split("", L)
  n = split(line, f, "\t")
  for (i = 1; i <= n; i++) { p = index(f[i], ":"); if (p) L[substr(f[i], 1, p - 1)] = substr(f[i], p + 1) }
}

# SQL 正規化（sqlnorm-v1）: 小文字化、コメント除去、文字列・数値を ?、IN (...) と VALUES の列挙をまとめる
function fingerprint(q,   s) {
  s = tolower(q)
  gsub(/\/\*[^*]*\*+([^\/*][^*]*\*+)*\//, "", s)
  gsub(/'([^'\\]|\\.)*'/, "?", s)
  gsub(/"([^"\\]|\\.)*"/, "?", s)
  s = " " s
  while (match(s, /[^a-z0-9_$.?][-]?[0-9]+(\.[0-9]+)?([e][-+]?[0-9]+)?/))
    s = substr(s, 1, RSTART) "?" substr(s, RSTART + RLENGTH)
  gsub(/[ \t\r\n]+/, " ", s)
  gsub(/^ +| +$/, "", s); sub(/ *;$/, "", s)
  gsub(/in \( *\?( *, *\?)* *\)/, "in (?+)", s)
  if (s ~ /^(insert|replace) /) sub(/ values *\(.*$/, " values (?+)", s)
  return s
}
function query_id(fp) { return "q" hash12(fp) }
