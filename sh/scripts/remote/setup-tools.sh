# 対象ホスト側のツール確認・導入。MODE=check|install
# 入力: ALP_VERSION, ALP_SHA256_AMD64, ALP_SHA256_ARM64
# システム全体の更新（apt upgrade）は行わない。既存のコマンドはそのまま再利用する。
show() { printf '  %-16s %s\n' "$1" "$2"; }
ver() {
  case "$1" in
    pidstat | iostat) "$1" -V 2>&1 | head -1 ;;
    alp) alp --version 2>&1 | head -1 ;;
    pt-query-digest) pt-query-digest --version 2>&1 | head -1 ;;
    htop) htop --version 2>&1 | head -1 ;;
    *) echo present ;;
  esac
}
missing_pkgs=() need_alp=0
for t in top htop pidstat iostat vmstat curl alp pt-query-digest; do
  if have "$t"; then show "$t" "$(command -v "$t") ($(ver "$t"))"; else
    show "$t" "なし"
    case "$t" in
      htop) missing_pkgs+=(htop) ;;
      pidstat | iostat) missing_pkgs+=(sysstat) ;;
      curl) missing_pkgs+=(curl) ;;
      pt-query-digest) missing_pkgs+=(percona-toolkit) ;;
      alp) need_alp=1 ;;
    esac
  fi
done
[[ "$MODE" == check ]] && exit 0

# apt で入るもの（Ubuntu 公式リポジトリ）
if ((${#missing_pkgs[@]})); then
  mapfile -t missing_pkgs < <(printf '%s\n' "${missing_pkgs[@]}" | sort -u)
  rlog "apt-get install: ${missing_pkgs[*]}"
  "${SUDO[@]}" apt-get update -qq
  "${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing_pkgs[@]}"
fi

# alp は GitHub Releases から固定バージョンを取得し、sha256 を照合してから配置する
if ((need_alp)); then
  case "$(uname -m)" in
    x86_64) arch=amd64 sum="$ALP_SHA256_AMD64" ;;
    aarch64) arch=arm64 sum="$ALP_SHA256_ARM64" ;;
    *) rdie "alp: 未対応のアーキテクチャ $(uname -m)" ;;
  esac
  tmp="$(mktemp -d)"
  url="https://github.com/tkuchiki/alp/releases/download/v${ALP_VERSION}/alp_linux_${arch}.tar.gz"
  rlog "download $url"
  curl -fsSL -o "$tmp/alp.tar.gz" "$url"
  echo "$sum  $tmp/alp.tar.gz" | sha256sum -c - >/dev/null || rdie "alp: sha256 が一致しません。配置を中止しました"
  tar -xzf "$tmp/alp.tar.gz" -C "$tmp" alp
  "${SUDO[@]}" install -m 0755 "$tmp/alp" /usr/local/bin/alp
  rm -rf "$tmp"
  rlog "alp $(alp --version) を /usr/local/bin に配置しました"
fi
