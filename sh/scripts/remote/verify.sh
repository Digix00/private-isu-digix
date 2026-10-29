# サービス状態・待ち受け・HTTP 応答の確認（対象ホスト側、読み取り専用）。
# 入力: VERIFY_SERVICES="svc ..." VERIFY_PORTS="80 3306" VERIFY_URLS="url|status ..."
fail=0
ok() { printf '  OK    %s\n' "$*"; }
ng() { printf '  NG    %s\n' "$*"; fail=1; }

for s in ${VERIFY_SERVICES:-}; do
  a="$(systemctl is-active "$s" 2>/dev/null || true)"
  e="$(systemctl is-enabled "$s" 2>/dev/null || true)"
  [[ "$a" == active ]] && ok "service $s: $a" || ng "service $s: ${a:-unknown}"
  # 再起動試験に備えて自動起動も確認する
  [[ "$e" == enabled ]] && ok "service $s 自動起動: $e" || ng "service $s 自動起動: ${e:-unknown}"
done

listening="$(ss -Htln 2>/dev/null | awk '{print $4}')"
for p in ${VERIFY_PORTS:-}; do
  grep -Eq "[:.]${p}\$" <<<"$listening" && ok "listen :$p" || ng "listen :$p (待ち受けなし)"
done

for u in ${VERIFY_URLS:-}; do
  url="${u%|*}" want="${u##*|}"
  got="$(curl -sS -o /dev/null -m 10 -w '%{http_code}' "$url" 2>/dev/null || true)"
  [[ "$got" == "$want" ]] && ok "GET $url -> $got" || ng "GET $url -> ${got:-接続失敗} (期待 $want)"
done
exit "$fail"
