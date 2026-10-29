# アプリのバイナリ切り替え・再起動・確認（対象ホスト側）。
# ACTION=install|rollback, UPLOAD, SHA256, BIN, SERVICE, CHECK_URL, CHECK_STATUS, DEPLOY_INFO(複数行 key=value)
INFO="$STATE_DIR/deployed-app.env"

restart_and_check() {
  "${SUDO[@]}" systemctl restart "$SERVICE" || { rlog "systemctl restart $SERVICE に失敗"; return 1; }
  local i got=""
  for ((i = 0; i < ${CHECK_RETRIES:-10}; i++)); do
    if systemctl is-active --quiet "$SERVICE"; then
      [[ -z "$CHECK_URL" ]] && { rlog "$SERVICE: active"; return 0; }
      got="$(curl -sS -o /dev/null -m 5 -w '%{http_code}' "$CHECK_URL" 2>/dev/null || true)"
      [[ "$got" == "$CHECK_STATUS" ]] && { rlog "$SERVICE: active, GET $CHECK_URL -> $got"; return 0; }
    fi
    sleep 1
  done
  rlog "$SERVICE の確認に失敗 (is-active: $(systemctl is-active "$SERVICE" || true), HTTP: ${got:-なし}, 期待 $CHECK_STATUS)"
  rlog "直近のログ: journalctl -u $SERVICE -n 50 --no-pager"
  return 1
}

case "$ACTION" in
  install)
    got="$(sha256sum "$UPLOAD" | awk '{print $1}')"
    [[ "$got" == "$SHA256" ]] || rdie "転送したバイナリの sha256 が一致しません ($got)"
    if [[ -e "$BIN" ]]; then
      "${SUDO[@]}" cp -p "$BIN" "$BIN.prev"
      [[ -f "$INFO" ]] && cp -p "$INFO" "$INFO.prev"
    fi
    # 同じディレクトリでの rename で切り替える（実行中のファイルを書き換えない）
    "${SUDO[@]}" install -m 0755 "$UPLOAD" "$BIN.new"
    "${SUDO[@]}" mv -f "$BIN.new" "$BIN"
    printf '%s\nDEPLOY_BIN_SHA256=%s\n' "$DEPLOY_INFO" "$SHA256" >"$INFO"
    rm -f "$UPLOAD"
    restart_and_check || { rlog "戻す場合: scripts/deploy/app.sh --rollback --host <host>"; exit 1; }
    ;;
  rollback)
    [[ -e "$BIN.prev" ]] || rdie "以前のバイナリ $BIN.prev がありません"
    "${SUDO[@]}" cp -p "$BIN.prev" "$BIN.new"
    "${SUDO[@]}" mv -f "$BIN.new" "$BIN"
    if [[ -f "$INFO.prev" ]]; then cp -p "$INFO.prev" "$INFO"; else rm -f "$INFO"; fi
    rlog "$BIN を $BIN.prev の内容に戻しました"
    restart_and_check
    ;;
  *) rdie "unknown ACTION: $ACTION" ;;
esac
