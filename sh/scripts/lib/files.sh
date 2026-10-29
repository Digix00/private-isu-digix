# shellcheck shell=bash
# 設定ファイル一式（"手元のパス:配置先の絶対パス" の配列）を1つの tar.gz にまとめる。
# 対象ホスト側の scripts/remote/_files.sh が展開・退避・配置・復旧を行う。

# make_bundle OUT ENTRY...
make_bundle() {
  local out="$1" stage entry src dest i=0
  shift
  (($#)) || die "配布するファイルが設定されていません" "$EX_USAGE"
  stage="$(mktemp -d)"
  : >"$stage/MAP"
  for entry in "$@"; do
    src="${entry%%:*}" dest="${entry#*:}"
    [[ "$src" = /* ]] || src="$ISU_REPO_ROOT/$src"
    [[ -f "$src" ]] || { rm -rf "$stage"; die "配布元のファイルがありません: $src" "$EX_USAGE"; }
    [[ "$dest" = /* && "$dest" != *..* && "$dest" =~ ^[A-Za-z0-9_./-]+$ ]] ||
      { rm -rf "$stage"; die "配置先は空白や .. を含まない絶対パスにしてください: '$dest'" "$EX_USAGE"; }
    i=$((i + 1))
    cp "$src" "$stage/f$i"
    printf 'f%s\t%s\n' "$i" "$dest" >>"$stage/MAP"
    log "管理するファイル: ${entry%%:*} -> $dest"
  done
  tar -czf "$out" -C "$stage" .
  rm -rf "$stage"
}
