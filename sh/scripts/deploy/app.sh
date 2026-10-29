#!/usr/bin/env bash
#? 使い方: scripts/deploy/app.sh [--host HOST]... [--dry-run] [--rollback]
#?
#? 手元でアプリをビルドし、成功した成果物だけを app 役のホストへ配布する。
#?   1. ビルドフック（ISU_APP_BUILD_HOOK）を GOOS/GOARCH/CGO_ENABLED を指定して実行
#?   2. 成果物の形式（ELF・CPU アーキテクチャ）を確認
#?   3. 対象ホストのロックを取得（計測中・他のデプロイ中なら中止）
#?   4. 転送 → sha256 照合 → 以前のバイナリを .prev に退避 → rename で切り替え
#?   5. サービス（ISU_APP_SERVICE）だけを再起動し、HTTP 応答を確認
#? MySQL や nginx には触れない。
#?
#?   --host HOST  対象を app 役のホストの一部に絞る（複数可）
#?   --dry-run    ビルド・転送・再起動を行わず、実行予定だけを表示する（SSH 接続もしない）
#?   --rollback   ビルドせず、対象ホストのバイナリを直前の .prev に戻して再起動する
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
source "$ISU_LIB_DIR/config.sh"
source "$ISU_LIB_DIR/remote.sh"
source "$ISU_LIB_DIR/lock.sh"

hosts=() rollback=0
while (($#)); do
  case "$1" in
    --host) [[ $# -ge 2 ]] || usage_error "--host に値が必要です"; hosts+=("$2"); shift 2 ;;
    --dry-run) export ISU_DRY_RUN=1; shift ;;
    --rollback) rollback=1; shift ;;
    -h | --help) print_help; exit 0 ;;
    *) usage_error "不明な引数: $1" ;;
  esac
done
require_cmd ssh git
load_config
cfg_require ISU_APP_SERVICE ISU_APP_REMOTE_BIN ISU_APP_SRC_DIR ISU_APP_BUILD_HOOK ISU_APP_GOOS ISU_APP_GOARCH
: "${ISU_APP_CGO_ENABLED:=0}" "${ISU_APP_CHECK_URL:=}" "${ISU_APP_CHECK_STATUS:=200}" "${ISU_APP_CHECK_RETRIES:=10}"
cfg_no_todo ISU_APP_CHECK_URL
targets="$(hosts_for_role app "${hosts[@]}")"

build() {
  local hook="$ISU_APP_BUILD_HOOK" out="$1"
  [[ "$hook" = /* ]] || hook="$ISU_REPO_ROOT/$hook"
  [[ -x "$hook" ]] || die "ビルドフックがないか実行できません: $hook (config/hooks/build-app.sh.example を参照)" "$EX_USAGE"
  [[ -d "$ISU_APP_SRC_DIR" ]] || die "ISU_APP_SRC_DIR がありません: $ISU_APP_SRC_DIR" "$EX_USAGE"

  # 手元とターゲットの OS/CPU が違う場合、CGO を使うビルドはクロスコンパイラが必要になるため対応しない
  local here_os here_arch
  here_os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  here_arch="$(uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/')"
  if [[ "$ISU_APP_CGO_ENABLED" == 1 && "$here_os/$here_arch" != "$ISU_APP_GOOS/$ISU_APP_GOARCH" ]]; then
    die "CGO_ENABLED=1 のクロスビルド ($here_os/$here_arch -> $ISU_APP_GOOS/$ISU_APP_GOARCH) には対応していません。
  同じ OS/CPU の環境でビルドするか、CGO を使わない構成にしてください。" "$EX_USAGE"
  fi

  log "build: $hook (GOOS=$ISU_APP_GOOS GOARCH=$ISU_APP_GOARCH CGO_ENABLED=$ISU_APP_CGO_ENABLED)"
  rm -f "$out"
  run_mut env GOOS="$ISU_APP_GOOS" GOARCH="$ISU_APP_GOARCH" CGO_ENABLED="$ISU_APP_CGO_ENABLED" \
    ISU_APP_SRC_DIR="$ISU_APP_SRC_DIR" OUT="$out" "$hook" || die "ビルドに失敗しました。配布は行いません"
  is_dry_run && return 0
  [[ -s "$out" ]] || die "ビルドフックが成果物を作りませんでした: $out"
  if command -v file >/dev/null 2>&1; then
    local desc want
    desc="$(file -b "$out")"
    case "$ISU_APP_GOARCH" in amd64) want="x86-64" ;; arm64) want="aarch64|ARM aarch64" ;; *) want="." ;; esac
    [[ "$ISU_APP_GOOS" != linux ]] || { grep -q '^ELF' <<<"$desc" && grep -Eq "$want" <<<"$desc"; } ||
      die "成果物の形式が $ISU_APP_GOOS/$ISU_APP_GOARCH ではありません: $desc"
  fi
}

# 配布したソースを後から特定できるよう、コミット・未コミット差分のハッシュを記録する
source_info() {
  local src="$ISU_APP_SRC_DIR" commit dirty diffsha
  commit="$(git -C "$src" rev-parse HEAD 2>/dev/null || echo unknown)"
  if [[ "$commit" == unknown ]]; then dirty=unknown diffsha=unknown
  elif [[ -n "$(git -C "$src" status --porcelain 2>/dev/null)" ]]; then
    dirty=true
    diffsha="$( { git -C "$src" diff HEAD; git -C "$src" ls-files --others --exclude-standard; } | { sha256sum 2>/dev/null || shasum -a 256; } | awk '{print $1}')"
  else dirty=false diffsha=none; fi
  printf 'DEPLOY_COMMIT=%s\nDEPLOY_DIRTY=%s\nDEPLOY_DIFF_SHA256=%s\nDEPLOYED_AT=%s\nDEPLOYED_BY=%s\n' \
    "$commit" "$dirty" "$diffsha" "$(now_iso)" "$(id -un)@$(hostname)"
}

common_env=("BIN=$ISU_APP_REMOTE_BIN" "SERVICE=$ISU_APP_SERVICE" "CHECK_URL=$ISU_APP_CHECK_URL"
  "CHECK_STATUS=$ISU_APP_CHECK_STATUS" "CHECK_RETRIES=$ISU_APP_CHECK_RETRIES")
artifact="" sha=""
if ((rollback == 0)); then
  workdir="$(mktemp -d)"
  trap 'rm -rf "$workdir"' EXIT
  artifact="$workdir/app"
  build "$artifact"
  is_dry_run || { sha="$(sha256_file "$artifact")"; log "artifact sha256: $sha"; }
  info="$(source_info)"
  [[ "$info" == *DEPLOY_DIRTY=true* ]] && warn "未コミットの変更を含むバイナリを配布します（差分のハッシュを記録します）"
fi

lock_id="$(new_lock_id)"
# shellcheck disable=SC2086 # ホスト名は検証済みで空白を含まない
lock_acquire_all "$lock_id" deploy app $targets || exit $?
trap 'lock_release_all "$lock_id"; rm -rf "${workdir:-/nonexistent}"' EXIT

statuses=()
for h in $targets; do
  echo "### $h"
  rc=0
  if ((rollback)); then
    remote_mut "$h" deploy-app.sh ACTION=rollback "${common_env[@]}" || rc=$?
  else
    upload="$ISU_REMOTE_STATE_DIR/upload/app.$sha"
    { remote_upload "$h" "$artifact" "$upload" &&
      remote_mut "$h" deploy-app.sh ACTION=install "UPLOAD=$upload" "SHA256=$sha" "DEPLOY_INFO=$info" "${common_env[@]}"; } || rc=$?
  fi
  statuses+=("$h=$rc")
done
report_hosts "deploy app" "${statuses[@]}"
