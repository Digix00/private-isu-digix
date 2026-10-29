# shellcheck shell=bash
# 設定の読み込みと、ホスト・役割の解決。
# 設定ファイルは Bash 形式で source する（= 信頼するローカルファイル。Git 管理外）。

ISU_CONFIG="${ISU_CONFIG:-$ISU_REPO_ROOT/config/isucon.conf}"

load_config() {
  [[ -f "$ISU_CONFIG" ]] ||
    die "設定ファイルがありません: $ISU_CONFIG
  cp config/isucon.conf.example config/isucon.conf で作成し、TODO の項目を埋めてください。" "$EX_USAGE"
  # shellcheck source=/dev/null
  source "$ISU_CONFIG"
  # load_config の中で source するため、-g のない declare はこの関数のローカル変数になってしまう
  if local -p 2>/dev/null | grep -q " ISU_"; then
    die "設定ファイルで declare を使う場合は declare -g / declare -gA にしてください: $(local -p | grep -o " ISU_[A-Z_]*" | tr -d "\n")" "$EX_USAGE"
  fi

  # 既定値（設定ファイルで上書き可能）
  : "${ISU_RESULTS_DIR:=$ISU_REPO_ROOT/results}"
  : "${ISU_EXPERIMENTS_DIR:=$ISU_REPO_ROOT/experiments}"
  : "${ISU_REMOTE_STATE_DIR:=/var/tmp/isu-prep}"
  : "${ISU_REMOTE_SUDO:=sudo -n}"
  : "${ISU_CONTEXT_MAX_BYTES:=8192}"
  : "${ISU_OUTPUT_MAX_BYTES:=16384}"
  : "${ISU_OUTPUT_HARD_MAX_BYTES:=65536}"
  : "${ISU_LIST_LIMIT:=20}"
  : "${ISU_FIELD_MAX_BYTES:=300}"
  if ! declare -p ISU_SSH_OPTS >/dev/null 2>&1; then
    ISU_SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10)
  fi
  # 相対パスは設定ファイルのあるリポジトリを基準にする
  [[ "$ISU_RESULTS_DIR" = /* ]] || ISU_RESULTS_DIR="$ISU_REPO_ROOT/$ISU_RESULTS_DIR"
  [[ "$ISU_EXPERIMENTS_DIR" = /* ]] || ISU_EXPERIMENTS_DIR="$ISU_REPO_ROOT/$ISU_EXPERIMENTS_DIR"

  declare -p ISU_HOSTS >/dev/null 2>&1 && ((${#ISU_HOSTS[@]})) ||
    die "ISU_HOSTS が設定されていません ($ISU_CONFIG)" "$EX_USAGE"
  declare -p ISU_ROLES >/dev/null 2>&1 ||
    die "ISU_ROLES が設定されていません ($ISU_CONFIG)" "$EX_USAGE"
  local h r
  for h in "${ISU_HOSTS[@]}"; do
    [[ "$h" != *__TODO__* && "$h" =~ ^[A-Za-z0-9._-]+$ ]] ||
      die "ISU_HOSTS に未設定または不正なホスト名があります: '$h'" "$EX_USAGE"
    for r in ${ISU_ROLES[$h]:-}; do
      [[ "$r" =~ ^(app|nginx|mysql)$ ]] || die "ホスト $h の役割が不正です: '$r' (app nginx mysql のみ)" "$EX_USAGE"
    done
  done
}

# 指定した変数がすべて設定済み（空でなく __TODO__ を含まない）であることを確認する
cfg_require() {
  local v missing=()
  for v in "$@"; do
    if ! declare -p "$v" >/dev/null 2>&1; then missing+=("$v"); continue; fi
    local -n ref="$v"
    if [[ "$(declare -p "$v")" == "declare -"[aA]* ]]; then
      ((${#ref[@]})) && [[ "${ref[*]}" != *__TODO__* ]] || missing+=("$v")
    else
      [[ -n "$ref" && "$ref" != *__TODO__* ]] || missing+=("$v")
    fi
    unset -n ref
  done
  ((${#missing[@]} == 0)) ||
    die "次の設定が未設定です (TODO のまま): ${missing[*]} — $ISU_CONFIG を編集してください" "$EX_USAGE"
}

host_has_role() {
  local host="$1" role="$2"
  [[ " ${ISU_ROLES[$host]:-} " == *" $role "* ]]
}

# 役割を持つホストを出力する。第2引数以降で絞り込み（指定ホストが役割を持たなければエラー）。
hosts_for_role() {
  local role="$1" h out=()
  shift
  if (($#)); then
    for h in "$@"; do
      [[ " ${ISU_HOSTS[*]} " == *" $h "* ]] || usage_error "ISU_HOSTS にないホストです: $h"
      host_has_role "$h" "$role" || usage_error "ホスト $h は役割 '$role' を持っていません"
      out+=("$h")
    done
  else
    for h in "${ISU_HOSTS[@]}"; do host_has_role "$h" "$role" && out+=("$h"); done
  fi
  ((${#out[@]})) || die "役割 '$role' のホストがありません (ISU_ROLES を確認)" "$EX_USAGE"
  printf '%s\n' "${out[@]}"
}

# --host が指定されていればそれ、なければ全ホスト
select_hosts() {
  local h
  if (($#)); then
    for h in "$@"; do
      [[ " ${ISU_HOSTS[*]} " == *" $h "* ]] || usage_error "ISU_HOSTS にないホストです: $h"
    done
    printf '%s\n' "$@"
  else
    printf '%s\n' "${ISU_HOSTS[@]}"
  fi
}

# 出力上限の検証。不正値・最大超過・最低限のメタデータも入らない値を拒否する。
validate_max_bytes() {
  local v="$1"
  [[ "$v" =~ ^[0-9]+$ ]] || usage_error "--max-bytes は整数で指定してください: '$v'"
  ((v >= 1024)) || usage_error "--max-bytes が小さすぎます (最低 1024 バイト。メタデータ分の領域が必要)"
  ((v <= ${ISU_OUTPUT_HARD_MAX_BYTES:-65536})) || usage_error "--max-bytes の上限は ${ISU_OUTPUT_HARD_MAX_BYTES:-65536} バイトです"
}
