#!/usr/bin/env bash
#? 使い方:
#?   scripts/setup-tools.sh check [--local | --remote] [--host HOST]...
#?   scripts/setup-tools.sh install --remote [--host HOST]... [--dry-run]
#?   scripts/setup-tools.sh install --local [--dry-run]
#?
#? 計測ツールの有無とバージョンを確認し、足りないものだけを導入する。既存のコマンドは再利用する。
#?   手元PC : bash(4.4+) ssh jq awk git go(pprof 解析) alp pt-query-digest
#?            macOS は Homebrew、Linux は apt の install コマンドを使う
#?   サーバー: htop sysstat(pidstat/iostat) percona-toolkit(pt-query-digest) は apt、
#?            alp は GitHub Releases の固定バージョンを sha256 照合して /usr/local/bin へ配置
#? apt upgrade などのシステム全体の更新や、curl で取得したスクリプトの実行は行わない。
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
source "$ISU_LIB_DIR/config.sh"
source "$ISU_LIB_DIR/remote.sh"

# alp の取得元とチェックサム（https://github.com/tkuchiki/alp/releases/tag/v1.0.22 の checksums.txt）
ALP_VERSION=1.0.22
ALP_SHA256_AMD64=e5830a70ca064aa89b6ed4715a71591e83e0fe9c85284bbec4208b7d949cbc42
ALP_SHA256_ARM64=80fd5bef2cc8097731b49ffe1a5e81c1732fb1bf897696bec986912d6d9e1888

mode="${1:-}"
[[ "$mode" == -h || "$mode" == --help ]] && { print_help; exit 0; }
[[ "$mode" == check || "$mode" == install ]] || usage_error "サブコマンドは check または install です"
shift
where="" hosts=()
while (($#)); do
  case "$1" in
    --local) where=local; shift ;;
    --remote) where=remote; shift ;;
    --host) [[ $# -ge 2 ]] || usage_error "--host に値が必要です"; hosts+=("$2"); shift 2 ;;
    --dry-run) export ISU_DRY_RUN=1; shift ;;
    -h | --help) print_help; exit 0 ;;
    *) usage_error "不明な引数: $1" ;;
  esac
done
[[ "$mode" == check || -n "$where" ]] || usage_error "install には --local か --remote を指定してください"

local_tools=(ssh jq awk git go alp pt-query-digest)
check_local() {
  echo "### local ($(uname -sm), bash $BASH_VERSION)"
  local t missing=()
  for t in "${local_tools[@]}"; do
    if command -v "$t" >/dev/null 2>&1; then
      printf '  %-16s %s\n' "$t" "$(command -v "$t")"
    else
      printf '  %-16s なし\n' "$t"; missing+=("$t")
    fi
  done
  # go は pprof 解析、alp/pt-query-digest は report の詳細レポートで使う（なければその項目が未作成になる）
  LOCAL_MISSING=("${missing[@]}")
}

install_local() {
  check_local
  local pkgs=() t
  for t in "${LOCAL_MISSING[@]}"; do
    case "$t" in
      pt-query-digest) pkgs+=(percona-toolkit) ;;
      ssh) die "ssh がありません。OS の OpenSSH クライアントを導入してください" ;;
      *) pkgs+=("$t") ;;
    esac
  done
  ((${#pkgs[@]})) || { log "手元のツールはすべてそろっています"; return 0; }
  if [[ "$(uname -s)" == Darwin ]]; then
    require_cmd brew
    run_mut brew install "${pkgs[@]}"
  else
    # Linux の apt には alp がないため、alp は手動で導入する（README 参照）
    local apt_pkgs=()
    for t in "${pkgs[@]}"; do
      case "$t" in alp) warn "alp は apt にありません。https://github.com/tkuchiki/alp/releases から導入してください" ;; go) apt_pkgs+=(golang-go) ;; *) apt_pkgs+=("$t") ;; esac
    done
    ((${#apt_pkgs[@]})) && run_mut sudo apt-get install -y "${apt_pkgs[@]}"
  fi
}

remote_each() {
  local m="$1" h rc statuses=()
  load_config
  targets="$(select_hosts "${hosts[@]}")"
for h in $targets; do
    echo "### $h"
    rc=0
    if [[ "$m" == check ]]; then
      remote_run "$h" setup-tools.sh MODE=check || rc=$?
    else
      remote_mut "$h" setup-tools.sh MODE=install "ALP_VERSION=$ALP_VERSION" \
        "ALP_SHA256_AMD64=$ALP_SHA256_AMD64" "ALP_SHA256_ARM64=$ALP_SHA256_ARM64" || rc=$?
    fi
    statuses+=("$h=$rc")
  done
  report_hosts "setup-tools $m" "${statuses[@]}"
}

case "$mode:$where" in
  check:local) check_local ;;
  check:remote) remote_each check ;;
  check:) check_local; remote_each check ;;
  install:local) install_local ;;
  install:remote) remote_each install ;;
esac
