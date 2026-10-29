# shellcheck shell=bash
# 対象ホスト上のロックを手元から扱う。deploy は処理中だけ、measure は start から stop まで保持する。
# 計測中のホストへの配布や、同じホストへの同時デプロイを防ぐ。

new_lock_id() { printf '%s-%s-%s' "$(date +%Y%m%d%H%M%S)" "$$" "$RANDOM"; }

LOCKED_HOSTS=()

# lock_acquire_all ID KIND SUBJECT HOST...
#   すべて取れなければ、取れた分を解除して EX_LOCKED を返す（一部のホストだけ変更されることを防ぐ）
lock_acquire_all() {
  local id="$1" kind="$2" subject="$3" h
  shift 3
  is_dry_run && { log "[dry-run] ロック取得を省略: $*"; return 0; }
  for h in "$@"; do
    if remote_run "$h" lock.sh ACTION=acquire "LOCK_ID=$id" "LOCK_KIND=$kind" \
      "LOCK_SUBJECT=$subject" "LOCK_OWNER=$(id -un)@$(hostname)"; then
      LOCKED_HOSTS+=("$h")
    else
      err "$h のロックを取得できませんでした（計測中または他の操作中）。状態の確認: scripts/lock.sh status --host $h"
      lock_release_all "$id"
      return "$EX_LOCKED"
    fi
  done
}

lock_release_all() {
  local id="$1" h rc=0
  for h in "${LOCKED_HOSTS[@]}"; do
    remote_run "$h" lock.sh ACTION=release "LOCK_ID=$id" || { rc=1; err "$h のロック解除に失敗しました (ID: $id)"; }
  done
  LOCKED_HOSTS=()
  return "$rc"
}
