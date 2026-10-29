# nginx 設定の配置・検証・reload（対象ホスト側）。入力: SERVICE, CHECK_URL, CHECK_STATUS
# 新しい設定を置いた状態で nginx -t を行い（include も含めて実際に読まれる設定一式を検証）、
# 失敗したら配置前に戻す。成功した場合だけ reload する。
files_install

if ! out="$("${SUDO[@]}" nginx -t 2>&1)"; then
  echo "$out" >&2
  rlog "nginx -t に失敗したため reload しません"
  files_restore
  "${SUDO[@]}" nginx -t >/dev/null 2>&1 && rlog "復旧後の nginx -t: ok" || rlog "復旧後も nginx -t が失敗します。手動で確認してください"
  exit 1
fi

# 管理するファイルが実際に読み込まれているか（include されていない設定は効かない）
dump="$("${SUDO[@]}" nginx -T 2>/dev/null || true)"
for f in $(managed_files); do
  if ! grep -qF "# configuration file $f:" <<<"$dump"; then
    rlog "$f は nginx の設定から include されていません（sites-enabled へのリンクや include を確認）"
    files_restore
    exit 1
  fi
done

if ! "${SUDO[@]}" systemctl reload "$SERVICE"; then
  rlog "reload に失敗しました。設定ファイルを戻します（稼働中のプロセスは旧設定のまま）"
  files_restore
  exit 1
fi
systemctl is-active --quiet "$SERVICE" || rdie "$SERVICE が active ではありません"
if [[ -n "$CHECK_URL" ]]; then
  got="$(curl -sS -o /dev/null -m 5 -w '%{http_code}' "$CHECK_URL" 2>/dev/null || true)"
  [[ "$got" == "$CHECK_STATUS" ]] || rdie "GET $CHECK_URL -> ${got:-接続失敗} (期待 $CHECK_STATUS)。戻す場合は docs/operations.md を参照"
fi
rlog "nginx: reload 完了"
