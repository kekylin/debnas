#!/usr/bin/env bats
# 测试: lib/system/keyring.sh — gpg_key_fingerprint_verify / keyring_install_verified
# 技术: 临时 GNUPGHOME 生成一次性测试密钥（绝不触碰 ~/.gnupg）；curl 用 PATH mock 从本地目录取文件
# 依赖: gpg；缺 gpg 时整体跳过

load '../../helpers/common-setup'

setup_file() {
  command -v gpg >/dev/null 2>&1 || return 0
  export KR_ROOT="${BATS_FILE_TMPDIR}/kr"
  mkdir -p "$KR_ROOT" && chmod 700 "$KR_ROOT"
  export GH_A="${KR_ROOT}/gnupg-a" GH_B="${KR_ROOT}/gnupg-b"
  mkdir -m 700 "$GH_A" "$GH_B"
  GNUPGHOME="$GH_A" gpg --batch --pinentry-mode loopback --passphrase '' \
    --quick-gen-key "Vendor A <a@example.invalid>" ed25519 sign 1d 2>/dev/null
  export FPR_A
  FPR_A=$(GNUPGHOME="$GH_A" gpg --batch --with-colons -k 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }')
  # 再加一个子密钥：校验只认主密钥指纹
  GNUPGHOME="$GH_A" gpg --batch --pinentry-mode loopback --passphrase '' --quick-add-key "$FPR_A" cv25519 encr 1d 2>/dev/null
  GNUPGHOME="$GH_B" gpg --batch --pinentry-mode loopback --passphrase '' \
    --quick-gen-key "Vendor B <b@example.invalid>" ed25519 sign 1d 2>/dev/null
  export FPR_B
  FPR_B=$(GNUPGHOME="$GH_B" gpg --batch --with-colons -k 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }')
  export KR_SRV="${KR_ROOT}/srv"
  mkdir -p "$KR_SRV"
  GNUPGHOME="$GH_A" gpg --batch --armor --export "$FPR_A" > "${KR_SRV}/a.asc"
  GNUPGHOME="$GH_A" gpg --batch --export "$FPR_A" > "${KR_SRV}/a.gpg"
  GNUPGHOME="$GH_B" gpg --batch --armor --export "$FPR_B" > "${KR_SRV}/b.asc"
  cat "${KR_SRV}/a.asc" "${KR_SRV}/b.asc" > "${KR_SRV}/ab.asc"
  # A 的公钥带上 B 的第三方认证签名、末尾再附一段无关文本：export-minimal 后两者都应被丢弃
  GNUPGHOME="$GH_B" gpg --batch --import "${KR_SRV}/a.asc" 2>/dev/null
  GNUPGHOME="$GH_B" gpg --batch --yes --pinentry-mode loopback --passphrase "" --quick-sign-key "$FPR_A" 2>/dev/null || true
  { GNUPGHOME="$GH_B" gpg --batch --armor --export "$FPR_A"; printf "\nTRAILING JUNK\n"; } > "${KR_SRV}/a-extra.asc"
  GNUPGHOME="$GH_B" gpg --batch --pinentry-mode loopback --passphrase '' --armor --export-secret-keys "$FPR_B" > "${KR_SRV}/secret.asc" 2>/dev/null
}

teardown_file() {
  if [[ -n "${GH_A:-}" ]] && command -v gpgconf >/dev/null 2>&1; then
    GNUPGHOME="$GH_A" gpgconf --kill all 2>/dev/null || true
    GNUPGHOME="$GH_B" gpgconf --kill all 2>/dev/null || true
  fi
  [[ -n "${KR_ROOT:-}" && -d "$KR_ROOT" ]] && rm -rf -- "${KR_ROOT:?}"
  return 0
}

setup() {
  [[ -n "${KR_ROOT:-}" ]] || skip "需要 gpg 生成测试密钥"
  export NO_COLOR=1
  export DEBNAS_TMP_BASE="${BATS_TMPDIR}/kr-tmp"
  setup_debnas_lib
  source "${DEBNAS_ROOT}/lib/system/tempfile.sh"
  source "${DEBNAS_ROOT}/lib/system/keyring.sh"
  sleep() { :; }
  DEST_DIR="${BATS_TMPDIR}/kr-dest"
  rm -rf "$DEST_DIR"; mkdir -p "$DEST_DIR"

  # curl mock：URL 的文件名映射到 $KR_SRV 下同名文件；CURL_FAIL_FIRST=1 时第一次调用失败
  MOCK_BIN="${BATS_TMPDIR}/kr-mock"
  mkdir -p "$MOCK_BIN"
  export CURL_COUNT="${BATS_TMPDIR}/kr-curl-count"
  rm -f "$CURL_COUNT"
  cat > "${MOCK_BIN}/curl" << 'INNEREOF'
#!/usr/bin/env bash
out="" url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) shift; out="$1" ;;
    --) shift; url="$1" ;;
    --proto|--max-time|--connect-timeout|--max-filesize) shift ;;
    -*) ;;
    *) url="$1" ;;
  esac
  shift
done
n=$(( $(cat "$CURL_COUNT" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$CURL_COUNT"
[[ "${CURL_FAIL_FIRST:-0}" == 1 && "$n" -eq 1 ]] && exit 7
src="${KR_SRV}/${url##*/}"
[[ -f "$src" ]] || exit 22
cat "$src" > "$out"
INNEREOF
  chmod +x "${MOCK_BIN}/curl"
  export PATH="${MOCK_BIN}:${PATH}"
}

teardown() {
  rm -rf "${DEST_DIR:-}" "${MOCK_BIN:-}" "${DEBNAS_TMP_BASE:-}" 2>/dev/null || true
}

# ==================== gpg_key_fingerprint_verify ====================

@test "gpg_key_fingerprint_verify: 主密钥指纹匹配（armored / 二进制）" {
  run gpg_key_fingerprint_verify "${KR_SRV}/a.asc" "$FPR_A"
  [[ "$status" -eq 0 ]]
  run gpg_key_fingerprint_verify "${KR_SRV}/a.gpg" "$FPR_A"
  [[ "$status" -eq 0 ]]
}

@test "gpg_key_fingerprint_verify: 指纹大小写/空格不敏感" {
  local spaced
  spaced=$(echo "$FPR_A" | tr 'A-F' 'a-f' | sed 's/..../& /g')
  run gpg_key_fingerprint_verify "${KR_SRV}/a.asc" "$spaced"
  [[ "$status" -eq 0 ]]
}

@test "gpg_key_fingerprint_verify: 指纹不符 / 多把主密钥 / 含私钥 / 期望值非法 → 失败" {
  run gpg_key_fingerprint_verify "${KR_SRV}/b.asc" "$FPR_A" "Vendor"
  [[ "$status" -eq 1 && "$output" == *"Vendor GPG 公钥指纹不匹配"* ]]
  run gpg_key_fingerprint_verify "${KR_SRV}/ab.asc" "$FPR_A"
  [[ "$status" -eq 1 && "$output" == *"恰好包含一把主密钥"* ]]
  run gpg_key_fingerprint_verify "${KR_SRV}/secret.asc" "$FPR_B"
  [[ "$status" -eq 1 && "$output" == *"私钥"* ]]
  run gpg_key_fingerprint_verify "${KR_SRV}/a.asc" "1234"
  [[ "$status" -eq 1 ]]
  run gpg_key_fingerprint_verify "${KR_SRV}/none.asc" "$FPR_A"
  [[ "$status" -eq 1 ]]
}

@test "gpg_key_fingerprint_verify: 子密钥指纹不算匹配" {
  local sub
  sub=$(GNUPGHOME="$GH_A" gpg --batch --with-colons -k 2>/dev/null | awk -F: '$1 == "sub" { s = 1; next } s && $1 == "fpr" { print $10; exit }')
  [[ -n "$sub" ]]
  run gpg_key_fingerprint_verify "${KR_SRV}/a.asc" "$sub"
  [[ "$status" -eq 1 ]]
}

@test "gpg_key_fingerprint_verify: 无 gpg 时报错" {
  local nobin="${BATS_TMPDIR}/kr-nogpg" c
  mkdir -p "$nobin"
  for c in mktemp chmod rm mkdir; do ln -sf "$(command -v "$c")" "${nobin}/${c}"; done
  PATH="$nobin" run gpg_key_fingerprint_verify "${KR_SRV}/a.asc" "$FPR_A"
  rm -rf "$nobin"
  [[ "$status" -eq 1 && "$output" == *"缺少 gpg"* ]]
}

# ==================== keyring_install_verified ====================

@test "keyring_install_verified: --dearmor 写入二进制 keyring（644，与 gpg --export 一致）" {
  run keyring_install_verified "https://example.invalid/key/a.asc" "$FPR_A" "${DEST_DIR}/sub/vendor.gpg" --dearmor --label Vendor
  [[ "$status" -eq 0 ]]
  gpg_key_fingerprint_verify "${DEST_DIR}/sub/vendor.gpg" "$FPR_A"
  cmp -s "${DEST_DIR}/sub/vendor.gpg" "${KR_SRV}/a.gpg"
  [[ "$(stat -c '%a' "${DEST_DIR}/sub/vendor.gpg")" == "644" ]]
  [[ -z "$(find "${DEST_DIR}/sub" -name '.*.debnas.*')" ]]
}

@test "keyring_install_verified: 不加 --dearmor 存 armored 导出结果（.asc）；二进制内容写 .asc 被拒" {
  run keyring_install_verified "https://example.invalid/a.asc" "$FPR_A" "${DEST_DIR}/vendor.asc"
  [[ "$status" -eq 0 ]]
  cmp -s "${DEST_DIR}/vendor.asc" "${KR_SRV}/a.asc"
  run keyring_install_verified "https://example.invalid/a.gpg" "$FPR_A" "${DEST_DIR}/other.asc"
  [[ "$status" -eq 1 ]]
  [[ ! -e "${DEST_DIR}/other.asc" ]]
}

@test "keyring_install_verified: 二进制下载 + --dearmor 原样使用" {
  run keyring_install_verified "https://example.invalid/a.gpg" "$FPR_A" "${DEST_DIR}/v.gpg" --dearmor
  [[ "$status" -eq 0 ]]
  cmp -s "${DEST_DIR}/v.gpg" "${KR_SRV}/a.gpg"
}

@test "keyring_install_verified: 指纹不符时失败且不动已有 keyring" {
  printf 'OLD' > "${DEST_DIR}/v.gpg"
  run keyring_install_verified "https://example.invalid/b.asc" "$FPR_A" "${DEST_DIR}/v.gpg" --dearmor
  [[ "$status" -eq 1 ]]
  [[ "$(cat "${DEST_DIR}/v.gpg")" == "OLD" ]]
}

@test "keyring_install_verified: 内容未变时跳过（inode 不变）" {
  keyring_install_verified "https://example.invalid/a.asc" "$FPR_A" "${DEST_DIR}/v.gpg" --dearmor
  local before
  before=$(stat -c '%i' "${DEST_DIR}/v.gpg")
  run keyring_install_verified "https://example.invalid/a.asc" "$FPR_A" "${DEST_DIR}/v.gpg" --dearmor
  [[ "$status" -eq 0 && "$output" == *"未变更"* ]]
  [[ "$(stat -c '%i' "${DEST_DIR}/v.gpg")" == "$before" ]]
}

@test "keyring_install_verified: 下载失败重试 1 次" {
  CURL_FAIL_FIRST=1 run keyring_install_verified "https://example.invalid/a.asc" "$FPR_A" "${DEST_DIR}/v.gpg" --dearmor
  [[ "$status" -eq 0 ]]
  [[ "$(cat "$CURL_COUNT")" -eq 2 ]]
  rm -f "$CURL_COUNT"
  run keyring_install_verified "https://example.invalid/missing.asc" "$FPR_A" "${DEST_DIR}/w.gpg" --dearmor
  [[ "$status" -eq 1 ]]
  [[ "$(cat "$CURL_COUNT")" -eq 2 ]]
  [[ ! -e "${DEST_DIR}/w.gpg" ]]
}

@test "keyring_install_verified: 参数校验（非 http(s) 地址 / 相对路径 / 未知选项）" {
  run keyring_install_verified "file:///etc/passwd" "$FPR_A" "${DEST_DIR}/v.gpg"
  [[ "$status" -eq 1 ]]
  run keyring_install_verified "https://example.invalid/a.asc" "$FPR_A" "relative.gpg"
  [[ "$status" -eq 1 ]]
  run keyring_install_verified "https://example.invalid/a.asc" "$FPR_A" "${DEST_DIR}/v.gpg" --bogus
  [[ "$status" -eq 1 ]]
  [[ ! -e "${DEST_DIR}/v.gpg" ]]
}

# ==================== 回归：写入 export-minimal 导出结果而非原始下载字节（C10） ====================

_sig_count() { GNUPGHOME="$GH_A" gpg --batch --list-packets "$1" 2>/dev/null | grep -c ':signature packet:' || true; }

@test "C10 keyring_install_verified: 去掉第三方签名与附带内容（--dearmor 二进制）" {
  [[ "$(_sig_count "${KR_SRV}/a-extra.asc")" -gt "$(_sig_count "${KR_SRV}/a.gpg")" ]] || skip "未能生成第三方签名"
  run keyring_install_verified "https://example.invalid/a-extra.asc" "$FPR_A" "${DEST_DIR}/m.gpg" --dearmor
  [[ "$status" -eq 0 ]]
  gpg_key_fingerprint_verify "${DEST_DIR}/m.gpg" "$FPR_A"
  [[ "$(_sig_count "${DEST_DIR}/m.gpg")" -eq "$(_sig_count "${KR_SRV}/a.gpg")" ]]
  ! grep -q "TRAILING JUNK" "${DEST_DIR}/m.gpg" || false
}

@test "C10 keyring_install_verified: armored 下载写 .asc 时用 --armor 导出（Docker 场景）" {
  run keyring_install_verified "https://example.invalid/a-extra.asc" "$FPR_A" "${DEST_DIR}/docker.asc"
  [[ "$status" -eq 0 ]]
  grep -q "BEGIN PGP PUBLIC KEY BLOCK" "${DEST_DIR}/docker.asc"
  ! grep -q "TRAILING JUNK" "${DEST_DIR}/docker.asc" || false
  [[ "$(_sig_count "${DEST_DIR}/docker.asc")" -eq "$(_sig_count "${KR_SRV}/a.asc")" ]]
  gpg_key_fingerprint_verify "${DEST_DIR}/docker.asc" "$FPR_A"
}

@test "C10 keyring.sh: 导入临时 GNUPGHOME 后 export-minimal 导出，不再 cp 原始下载文件" {
  local body
  body=$(sed -n '/^keyring_install_verified()/,/^}/p' "${DEBNAS_ROOT}/lib/system/keyring.sh")
  [[ "$body" == *'--export --export-options export-minimal'* ]]
  [[ "$body" == *'--import "$tmp_dl"'* ]]
  [[ "$body" != *'cp -- "$tmp_dl" "$tmp_out"'* ]]
}
