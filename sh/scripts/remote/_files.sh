# 設定ファイル一式の配置と復旧（対象ホスト側。deploy-nginx.sh / deploy-mysql.sh の前に連結される）。
# 入力: BUNDLE（転送した tar.gz）, BACKUP_NAME（退避先の名前）
STAGE="$(mktemp -d)"
BACKUP="$STATE_DIR/backup/$BACKUP_NAME"
trap 'rm -rf "$STAGE"' EXIT
tar -xzf "$BUNDLE" -C "$STAGE"
rm -f "$BUNDLE"

# 既存ファイルを退避し、差分を表示してから配置する
files_install() {
  local f dest
  mkdir -p "$BACKUP"
  : >"$BACKUP/MAP"
  while IFS=$'\t' read -r f dest; do
    if "${SUDO[@]}" test -e "$dest"; then
      "${SUDO[@]}" cp -p "$dest" "$BACKUP/$f"
      printf '%s\t%s\tpresent\n' "$f" "$dest" >>"$BACKUP/MAP"
      echo "--- 差分: $dest (先頭 40 行)"
      { "${SUDO[@]}" diff -u "$dest" "$STAGE/$f" || true; } | head -40
    else
      printf '%s\t%s\tabsent\n' "$f" "$dest" >>"$BACKUP/MAP"
      echo "--- 新規: $dest"
    fi
    "${SUDO[@]}" install -m 0644 "$STAGE/$f" "$dest"
  done <"$STAGE/MAP"
  rlog "退避先: $BACKUP"
}

# files_install の前の状態に戻す
files_restore() {
  local f dest st
  while IFS=$'\t' read -r f dest st; do
    if [[ "$st" == present ]]; then "${SUDO[@]}" cp -p "$BACKUP/$f" "$dest"; else "${SUDO[@]}" rm -f "$dest"; fi
  done <"$BACKUP/MAP"
  rlog "設定ファイルを配置前の状態に戻しました（退避先: $BACKUP）"
}

managed_files() { cut -f2 "$STAGE/MAP"; }
