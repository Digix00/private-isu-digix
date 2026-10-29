# shellcheck shell=bash
# 対象ホスト側で実行されるスクリプトの共通部分（remote_run が先頭に連結する）。
set -Eeuo pipefail
# shellcheck disable=SC2034 # 連結される各スクリプトで使う
read -ra SUDO <<<"${ISU_REMOTE_SUDO:-sudo -n}"
# shellcheck disable=SC2034
STATE_DIR="${ISU_REMOTE_STATE_DIR:-/var/tmp/isu-prep}"
HOST="$(hostname)"
rlog() { printf '[%s] %s\n' "$HOST" "$*" >&2; }
rdie() { printf '[%s] error: %s\n' "$HOST" "$1" >&2; exit "${2:-1}"; }
have() { command -v "$1" >/dev/null 2>&1; }
