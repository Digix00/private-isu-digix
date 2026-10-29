# shellcheck shell=bash
# SSH 越しの実行。スクリプト本体は標準入力で渡し、値は環境変数として安全にクォートして渡す。
# ホスト鍵検証は無効にしない（~/.ssh/config と known_hosts をそのまま使う）。

# remote_run HOST "SCRIPT [SCRIPT...]" [KEY=VALUE ...]
#   scripts/remote/_common.sh と scripts/remote/SCRIPT... を連結して対象ホストの bash で実行する。
remote_run() {
  local host="$1" kv envs=() s files=("$ISU_SCRIPTS_DIR/remote/_common.sh")
  for s in $2; do files+=("$ISU_SCRIPTS_DIR/remote/$s"); done
  shift 2
  for kv in "ISU_REMOTE_SUDO=$ISU_REMOTE_SUDO" "ISU_REMOTE_STATE_DIR=$ISU_REMOTE_STATE_DIR" "$@"; do
    [[ "$kv" =~ ^[A-Z_][A-Z0-9_]*= ]] || die "内部エラー: 不正な環境変数指定 '$kv'"
    envs+=("$(shell_quote "$kv")")
  done
  # shellcheck disable=SC2029 # 値はクォート済みで、意図して手元で展開する
  cat "${files[@]}" |
    ssh "${ISU_SSH_OPTS[@]}" "$host" "env ${envs[*]} bash -s"
}

# 変更を伴うリモート実行。dry-run では SSH 接続自体を行わない。
remote_mut() {
  if is_dry_run; then
    printf '[dry-run] ssh %s: %s %s\n' "$1" "$2" "$(shell_join "${@:3}")" >&2
    return 0
  fi
  remote_run "$@"
}

# 複数ホストの結果を表示し、1台でも失敗していれば非0を返す
# 使い方: report_hosts "処理名" host1=0 host2=1 ...
report_hosts() {
  local title="$1" kv failed=0
  shift
  (($#)) || { err "$title: 対象ホストがありません"; return "$EX_FAIL"; }
  echo "== $title: ホスト別の結果" >&2
  for kv in "$@"; do
    if [[ "${kv#*=}" == 0 ]]; then
      echo "  OK    ${kv%%=*}" >&2
    else
      echo "  FAIL  ${kv%%=*} (exit ${kv#*=})" >&2
      failed=1
    fi
  done
  ((failed == 0)) || { err "$title: 一部またはすべてのホストで失敗しました"; return "$EX_FAIL"; }
}

# 手元のファイルを対象ホストへ送る（変更を伴うため dry-run では送らない）
remote_upload() {
  local host="$1" src="$2" dest="$3"
  if is_dry_run; then
    printf '[dry-run] upload %s -> %s:%s\n' "$src" "$host" "$dest" >&2
    return 0
  fi
  # shellcheck disable=SC2029 # パスはクォート済み
  ssh "${ISU_SSH_OPTS[@]}" "$host" "mkdir -p $(shell_quote "$(dirname "$dest")") && cat > $(shell_quote "$dest")" <"$src"
}
