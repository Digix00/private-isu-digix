# shellcheck shell=bash
# 実行ID ごとの結果ディレクトリ（results/<run-id>/）の扱い。
#   run.json      measure.sh が書く実行の記録（開始・終了・ホスト・ロック・計測条件・手元のコード）
#   bench.json    利用者が measure.sh result で書くベンチ結果
#   raw/<host>/   回収した元データ（回収後は書き込み禁止にする）
#   snapshots/    当時の設定・インデックス・手元の差分
#   reports/ metrics.json manifest.json context.md   report.sh / agent-context.sh が生成する

# 集計方法のバージョン。ID 生成・URL グルーピング・SQL 正規化を変えたら上げる（比較可能性の判定に使う）
# shellcheck disable=SC2034 # 読み込む側のスクリプトで使う
ANALYZER_VERSION="isu-prep-analyzer/1"
GROUPING_VERSION="urlgroup-v1"
SQLNORM_VERSION="sqlnorm-v1"
AWK_DIR="$ISU_LIB_DIR/awk"

run_dir() { printf '%s/%s' "$ISU_RESULTS_DIR" "$1"; }

require_run() {
  local d
  d="$(run_dir "$1")"
  [[ -f "$d/run.json" ]] || die "実行ID '$1' の記録がありません: $d/run.json" "$EX_USAGE"
}

# JSON ファイルを jq で更新し、一時ファイルから置き換える
json_update() {
  local file="$1"
  shift
  jq "$@" "$file" | atomic_write "$file"
}

# key=value の行を JSON オブジェクトにする
env_to_json() {
  if [[ -f "$1" ]]; then
    jq -R -s 'split("\n") | map(select(test("^[A-Za-z_][A-Za-z0-9_.]*=")) | {(sub("=.*"; "")): sub("^[^=]*="; "")}) | add // {}' "$1"
  else
    echo null
  fi
}

# 手元の競技アプリのソース状態（コミット・未コミット差分）
local_code_json() {
  local src="${ISU_APP_SRC_DIR:-}" patch="$1" commit dirty=unknown diffsha=null
  if [[ -z "$src" || "$src" == *__TODO__* ]] || ! commit="$(git -C "$src" rev-parse HEAD 2>/dev/null)"; then
    jq -n '{commit: null, dirty: null, diff_sha256: null, note: "ISU_APP_SRC_DIR が未設定または Git リポジトリではない"}'
    return
  fi
  if [[ -n "$(git -C "$src" status --porcelain 2>/dev/null)" ]]; then
    dirty=true
    git -C "$src" diff HEAD >"$patch" 2>/dev/null || true
    diffsha="\"$(sha256_file "$patch")\""
  else
    dirty=false
  fi
  jq -n --arg c "$commit" --argjson d "$dirty" --argjson s "$diffsha" --arg p "$([[ $dirty == true ]] && basename "$patch")" \
    '{commit: $c, dirty: $d, diff_sha256: $s, diff_file: (if $p == "" then null else "snapshots/" + $p end)}'
}

# 出力上限の引数（--max-bytes）を解決する
resolve_max() { local v="${1:-$2}"; validate_max_bytes "$v"; printf '%s' "$v"; }
