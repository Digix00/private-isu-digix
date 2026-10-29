# 対象ホスト上の実行状態ロック（deploy と measure で共有）。
# ACTION=acquire|release|status, LOCK_ID, LOCK_KIND(deploy|measure), LOCK_SUBJECT, LOCK_OWNER
# mkdir が原子的であることを使う。複数の手元PCから操作しても、同じホストでは1つしか取れない。
LOCK="$STATE_DIR/lock"
mkdir -p "$STATE_DIR"
case "$ACTION" in
  acquire)
    if mkdir "$LOCK" 2>/dev/null; then
      printf 'id=%s\nkind=%s\nsubject=%s\nowner=%s\nsince=%s\n' \
        "$LOCK_ID" "$LOCK_KIND" "$LOCK_SUBJECT" "$LOCK_OWNER" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$LOCK/info.tmp"
      mv "$LOCK/info.tmp" "$LOCK/info"
    else
      echo "ロック中のため実行できません:" >&2
      sed 's/^/  /' "$LOCK/info" >&2 2>/dev/null || echo "  (情報を書き込み中、または壊れています: $LOCK)" >&2
      exit 3
    fi
    ;;
  release)
    [[ -d "$LOCK" ]] || { rlog "ロックはありません"; exit 0; }
    held="$(sed -n 's/^id=//p' "$LOCK/info" 2>/dev/null || true)"
    [[ "$held" == "$LOCK_ID" ]] || rdie "ロックIDが一致しないため解除しません (保持: ${held:-不明}, 指定: $LOCK_ID)" 3
    rm -f "$LOCK/info"
    rmdir "$LOCK"
    ;;
  status)
    if [[ -d "$LOCK" ]]; then
      echo "locked"
      sed 's/^/  /' "$LOCK/info" 2>/dev/null || echo "  (情報なし)"
    else
      echo "unlocked"
    fi
    ;;
  *) rdie "unknown ACTION: $ACTION" ;;
esac
