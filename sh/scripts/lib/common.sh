# shellcheck shell=bash
# 共通処理: エラー表示、引数検証、dry-run、パス解決。
# 各エントリスクリプトから `source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"` で読み込む。

if [[ -z "${BASH_VERSINFO:-}" || "${BASH_VERSINFO[0]}" -lt 4 || ( "${BASH_VERSINFO[0]}" -eq 4 && "${BASH_VERSINFO[1]}" -lt 4 ) ]]; then
  echo "error: bash 4.4 以上が必要です (現在: ${BASH_VERSION:-unknown})。macOS では 'brew install bash' を利用してください。" >&2
  exit 2
fi

set -Eeuo pipefail
shopt -s inherit_errexit 2>/dev/null || true

# ツール一式のルート = scripts/ の1つ上（sh/）。呼び出し時のカレントディレクトリに依存しない
ISU_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISU_SCRIPTS_DIR="$(cd "$ISU_LIB_DIR/.." && pwd)"
ISU_REPO_ROOT="$(cd "$ISU_SCRIPTS_DIR/.." && pwd)"
export ISU_REPO_ROOT

ISU_DRY_RUN="${ISU_DRY_RUN:-0}"
ISU_PROG="$(basename "$0")"

# 終了コード: 0=成功, 1=処理失敗(一部失敗含む), 2=使い方・設定の誤り, 3=ロック競合
# shellcheck disable=SC2034 # 読み込む側のスクリプトで使う
readonly EX_FAIL=1 EX_USAGE=2 EX_LOCKED=3

log()  { printf '[%s] %s\n' "$ISU_PROG" "$*" >&2; }
warn() { printf '[%s] warning: %s\n' "$ISU_PROG" "$*" >&2; }
err()  { printf '[%s] error: %s\n' "$ISU_PROG" "$*" >&2; }
die()  { err "$1"; exit "${2:-$EX_FAIL}"; }
usage_error() { err "$1"; echo "詳しくは '$ISU_PROG --help' を参照してください。" >&2; exit "$EX_USAGE"; }

# コマンドが存在することを確認する
require_cmd() {
  local c missing=()
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if ((${#missing[@]})); then
    die "必要なコマンドが見つかりません: ${missing[*]} (README の依存関係を参照)" "$EX_USAGE"
  fi
}

# 実行IDの検証。パス区切りや先頭ドット、空白を拒否する。
validate_run_id() {
  local id="$1"
  [[ "$id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] && [[ "$id" != *..* ]] ||
    usage_error "不正な実行IDです: '$id' (英数字で始まり、英数字 . _ - のみ、64文字以内)"
}

# POSIX sh でも安全に解釈できるシングルクォート表現にする（SSH 越しの引数渡し用）
shell_quote() {
  local s="$1"
  printf "'%s'" "${s//\'/\'\\\'\'}"
}

shell_join() {
  local out="" a
  for a in "$@"; do out+="$(shell_quote "$a") "; done
  printf '%s' "${out% }"
}

is_dry_run() { [[ "$ISU_DRY_RUN" == 1 ]]; }

# 変更を伴うローカル処理。dry-run では実行せず内容だけ表示する。
run_mut() {
  if is_dry_run; then
    printf '[dry-run] %s\n' "$(shell_join "$@")" >&2
    return 0
  fi
  "$@"
}

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# 一時ファイルに書いてから置き換える（読み手が書きかけのファイルを見ないように）
atomic_write() {
  local dest="$1" tmp
  tmp="$(mktemp "${dest}.tmp.XXXXXX")"
  if cat >"$tmp"; then
    mv -f "$tmp" "$dest"
  else
    rm -f "$tmp"
    return 1
  fi
}

# --help 用。スクリプト先頭の "#?" で始まる行を表示する。
print_help() {
  sed -n 's/^#? \{0,1\}//p' "$0"
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | awk '{print $1}'
}
