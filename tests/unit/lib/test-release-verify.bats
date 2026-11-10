#!/usr/bin/env bats
# 测试: 发布产物签名校验
#   - install.sh：dearmor_pubkey / verify_release / 参数与 preflight
#   - lib/system/installer.sh：installer_dearmor_key / installer_load_release_key /
#     installer_verify_release / installer_version_lt / tag·分支名校验
#   - tools/release.sh --embed-key 写入的内嵌公钥可被 install.sh 正常使用
# 技术: 临时 GNUPGHOME 生成一次性测试密钥（绝不触碰 ~/.gnupg），产物与密钥随测试删除
# 依赖: gpg（生成测试密钥/签名）、gpgv、sha256sum；缺 gpg 时整体跳过

load '../../helpers/common-setup'

setup_file() {
  if ! command -v gpg >/dev/null 2>&1 || ! command -v gpgv >/dev/null 2>&1; then
    return 0
  fi
  export RV_ROOT="${BATS_FILE_TMPDIR}/rv"
  mkdir -p "$RV_ROOT"
  chmod 700 "$RV_ROOT"
  export GNUPGHOME_A="${RV_ROOT}/gnupg-a" GNUPGHOME_B="${RV_ROOT}/gnupg-b"
  mkdir -m 700 "$GNUPGHOME_A" "$GNUPGHOME_B"

  # 发布密钥 A：ed25519 主密钥 + 签名子密钥（签名实际由子密钥完成，覆盖"主密钥指纹匹配"）
  GNUPGHOME="$GNUPGHOME_A" gpg --batch --pinentry-mode loopback --passphrase '' \
    --quick-gen-key "DebNAS Test <test@example.invalid>" ed25519 sign 1d 2>/dev/null
  export FPR_A
  FPR_A=$(GNUPGHOME="$GNUPGHOME_A" gpg --batch --with-colons -k 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }')
  GNUPGHOME="$GNUPGHOME_A" gpg --batch --pinentry-mode loopback --passphrase '' \
    --quick-add-key "$FPR_A" ed25519 sign 1d 2>/dev/null
  # 攻击者密钥 B
  GNUPGHOME="$GNUPGHOME_B" gpg --batch --pinentry-mode loopback --passphrase '' \
    --quick-gen-key "Attacker <evil@example.invalid>" ed25519 sign 1d 2>/dev/null
  export FPR_B
  FPR_B=$(GNUPGHOME="$GNUPGHOME_B" gpg --batch --with-colons -k 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }')

  GNUPGHOME="$GNUPGHOME_A" gpg --batch --armor --export-options export-minimal --export "$FPR_A" > "${RV_ROOT}/a.asc"
  GNUPGHOME="$GNUPGHOME_A" gpg --batch --export-options export-minimal --export "$FPR_A" > "${RV_ROOT}/a.gpg"
  GNUPGHOME="$GNUPGHOME_B" gpg --batch --export "$FPR_B" > "${RV_ROOT}/b.gpg"

  # 发布产物（模拟 release.sh）：tar 包 + SHA256SUMS + 签名
  local src="${RV_ROOT}/src/debnas"
  mkdir -p "${src}/bin"
  echo 'echo hello' > "${src}/bin/debnas"
  export REL_NAME="debnas-v9.9.9.tar.gz"
  mkdir -p "${RV_ROOT}/dist"
  tar -czf "${RV_ROOT}/dist/${REL_NAME}" -C "${RV_ROOT}/src" debnas
  echo 'fake install.sh' > "${RV_ROOT}/dist/install.sh"
  (cd "${RV_ROOT}/dist" && sha256sum "$REL_NAME" install.sh > SHA256SUMS)
  GNUPGHOME="$GNUPGHOME_A" gpg --batch --pinentry-mode loopback --passphrase '' \
    --detach-sign --armor -o "${RV_ROOT}/dist/SHA256SUMS.asc" "${RV_ROOT}/dist/SHA256SUMS" 2>/dev/null
}

teardown_file() {
  if [[ -n "${GNUPGHOME_A:-}" ]] && command -v gpgconf >/dev/null 2>&1; then
    GNUPGHOME="$GNUPGHOME_A" gpgconf --kill all 2>/dev/null || true
    GNUPGHOME="$GNUPGHOME_B" gpgconf --kill all 2>/dev/null || true
  fi
  if [[ -n "${RV_ROOT:-}" && -d "$RV_ROOT" ]]; then
    rm -rf -- "${RV_ROOT:?}"
  fi
}

setup() {
  if [[ -z "${RV_ROOT:-}" ]]; then
    skip "需要 gpg 与 gpgv 生成测试密钥"
  fi
  export NO_COLOR=1
  setup_debnas_lib
  source "${DEBNAS_ROOT}/lib/system/installer.sh"
  WORK="$(mktemp -d "${BATS_TEST_TMPDIR}/w.XXXXXX")"
  cp "${RV_ROOT}/dist/${REL_NAME}" "${RV_ROOT}/dist/SHA256SUMS" "${RV_ROOT}/dist/SHA256SUMS.asc" "$WORK/"
}

# 用攻击者密钥 B 重新签名 SHA256SUMS
_resign_with_b() {
  GNUPGHOME="$GNUPGHOME_B" gpg --batch --yes --pinentry-mode loopback --passphrase '' \
    --detach-sign --armor -o "${WORK}/SHA256SUMS.asc" "${WORK}/SHA256SUMS" 2>/dev/null
}

# 在独立 bash 进程中 source install.sh 后调用其函数
# （install.sh 的 readonly 常量与 logging.sh 的 DEBNAS_LOG_DIR 同名，不能与 lib 在同一 shell 加载）
_inst() {
  bash -c 'source "$1"; shift; "$@"' _ "${DEBNAS_ROOT}/install.sh" "$@"
}

# ==================== dearmor ====================

@test "dearmor_pubkey: armor → 二进制与 gpg --export 完全一致" {
  run _inst dearmor_pubkey "$(cat "${RV_ROOT}/a.asc")" "${WORK}/k.gpg"
  [[ "$status" -eq 0 ]]
  cmp -s "${WORK}/k.gpg" "${RV_ROOT}/a.gpg"
}

@test "dearmor_pubkey: 带 Comment 头与 CRLF 的 armor 也能解码" {
  local armor
  armor=$(sed '1a Comment: test header' "${RV_ROOT}/a.asc" | sed 's/$/\r/')
  run _inst dearmor_pubkey "$armor" "${WORK}/k.gpg"
  [[ "$status" -eq 0 ]]
  cmp -s "${WORK}/k.gpg" "${RV_ROOT}/a.gpg"
}

@test "dearmor_pubkey: 空串/占位文本 → 失败" {
  run _inst dearmor_pubkey "" "${WORK}/k.gpg"
  [[ "$status" -ne 0 ]]
  run _inst dearmor_pubkey "$(cat "${DEBNAS_ROOT}/keys/debnas-release.asc")" "${WORK}/k2.gpg"
  if grep -q 'BEGIN PGP PUBLIC KEY BLOCK' "${DEBNAS_ROOT}/keys/debnas-release.asc"; then
    skip "仓库已配置真实发布公钥"
  fi
  [[ "$status" -ne 0 ]]
}

@test "dearmor_pubkey: 两个公钥块（换钥过渡期）→ 逐块解码后依次拼接" {
  GNUPGHOME="$GNUPGHOME_B" gpg --batch --armor --export "$FPR_B" > "${WORK}/b.asc"
  run _inst dearmor_pubkey "$(cat "${RV_ROOT}/a.asc" "${WORK}/b.asc")" "${WORK}/k.gpg"
  [[ "$status" -eq 0 ]]
  cmp -s "${WORK}/k.gpg" <(cat "${RV_ROOT}/a.gpg" "${RV_ROOT}/b.gpg")
  # 拼出的 keyring 可直接用于验签
  run _inst verify_release "$WORK" "$REL_NAME" "${WORK}/k.gpg" "${FPR_B},${FPR_A}"
  [[ "$status" -eq 0 ]]
}

@test "dearmor_pubkey: 公钥块不完整（缺 END / 嵌套 BEGIN / 空块）→ 失败" {
  run _inst dearmor_pubkey "$(sed '$d' "${RV_ROOT}/a.asc")" "${WORK}/k.gpg"
  [[ "$status" -ne 0 ]]
  run _inst dearmor_pubkey "$(sed '$d' "${RV_ROOT}/a.asc"; cat "${RV_ROOT}/a.asc")" "${WORK}/k.gpg"
  [[ "$status" -ne 0 ]]
  run _inst dearmor_pubkey "$(cat "${RV_ROOT}/a.asc"; printf -- '-----BEGIN PGP PUBLIC KEY BLOCK-----\n\n-----END PGP PUBLIC KEY BLOCK-----\n')" "${WORK}/k.gpg"
  [[ "$status" -ne 0 ]]
}

@test "installer_dearmor_key 与 dearmor_pubkey 结果一致" {
  run installer_dearmor_key "${RV_ROOT}/a.asc" "${WORK}/k.gpg"
  [[ "$status" -eq 0 ]]
  cmp -s "${WORK}/k.gpg" "${RV_ROOT}/a.gpg"
}

# ==================== install.sh verify_release ====================

@test "verify_release: 正确签名 + 正确 tar 包 → 通过（签名由子密钥完成，匹配主密钥指纹）" {
  run _inst verify_release "$WORK" "$REL_NAME" "${RV_ROOT}/a.gpg" "$FPR_A"
  [[ "$status" -eq 0 ]]
  [[ -f "${WORK}/${REL_NAME}" ]]
}

@test "verify_release: 指纹大小写/空格不敏感" {
  local spaced
  spaced=$(echo "$FPR_A" | tr 'A-F' 'a-f' | sed 's/..../& /g')
  run _inst verify_release "$WORK" "$REL_NAME" "${RV_ROOT}/a.gpg" "$spaced"
  [[ "$status" -eq 0 ]]
}

@test "verify_release: 篡改 tar 包 → 失败且删除下载物" {
  printf 'X' >> "${WORK}/${REL_NAME}"
  run _inst verify_release "$WORK" "$REL_NAME" "${RV_ROOT}/a.gpg" "$FPR_A"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"SHA256 校验失败"* ]]
  [[ ! -e "${WORK}/${REL_NAME}" && ! -e "${WORK}/SHA256SUMS" && ! -e "${WORK}/SHA256SUMS.asc" ]]
}

@test "verify_release: 篡改 SHA256SUMS → 签名验证失败" {
  local real
  real=$(sha256sum "${WORK}/${REL_NAME}" | cut -c1-64)
  printf 'X' >> "${WORK}/${REL_NAME}"
  local fake
  fake=$(sha256sum "${WORK}/${REL_NAME}" | cut -c1-64)
  sed -i "s/${real}/${fake}/" "${WORK}/SHA256SUMS"
  run _inst verify_release "$WORK" "$REL_NAME" "${RV_ROOT}/a.gpg" "$FPR_A"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"签名验证失败"* ]]
  [[ ! -e "${WORK}/${REL_NAME}" ]]
}

@test "verify_release: 另一把密钥签名 → 失败" {
  _resign_with_b
  run _inst verify_release "$WORK" "$REL_NAME" "${RV_ROOT}/a.gpg" "$FPR_A"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"签名验证失败"* ]]
}

@test "verify_release: keyring 被换成攻击者公钥 → 指纹不匹配失败" {
  _resign_with_b
  run _inst verify_release "$WORK" "$REL_NAME" "${RV_ROOT}/b.gpg" "$FPR_A"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"签名者指纹不匹配"* ]]
}

@test "verify_release: SHA256SUMS 中缺少 tar 包条目 → 失败" {
  run _inst verify_release "$WORK" "debnas-v0.0.1.tar.gz" "${RV_ROOT}/a.gpg" "$FPR_A"
  [[ "$status" -ne 0 ]]
}

@test "verify_release: 非法文件名 / 无效指纹 → 失败" {
  run _inst verify_release "$WORK" "../etc/passwd" "${RV_ROOT}/a.gpg" "$FPR_A"
  [[ "$status" -ne 0 ]]
  run _inst verify_release "$WORK" "$REL_NAME" "${RV_ROOT}/a.gpg" ""
  [[ "$status" -ne 0 ]]
  run _inst verify_release "$WORK" "$REL_NAME" "${RV_ROOT}/a.gpg" "1234"
  [[ "$status" -ne 0 ]]
}

@test "verify_release: 缺少签名文件 → 失败" {
  rm -f "${WORK}/SHA256SUMS.asc"
  run _inst verify_release "$WORK" "$REL_NAME" "${RV_ROOT}/a.gpg" "$FPR_A"
  [[ "$status" -ne 0 ]]
}

# ==================== lib/system/installer.sh ====================

@test "installer_load_release_key + installer_verify_release: 安装目录公钥 → 通过" {
  local inst="${WORK}/inst"
  mkdir -p "${inst}/keys"
  cp "${RV_ROOT}/a.asc" "${inst}/keys/debnas-release.asc"
  echo "$FPR_A" > "${inst}/keys/debnas-release.fpr"
  local fpr
  fpr=$(installer_load_release_key "$inst" "${WORK}/k.gpg")
  [[ "$fpr" == "$FPR_A" ]]
  run installer_verify_release "$WORK" "$REL_NAME" "${WORK}/k.gpg" "$fpr"
  [[ "$status" -eq 0 ]]
}

@test "installer_verify_release: 篡改 tar 包 / 另一把密钥签名 → 失败" {
  printf 'X' >> "${WORK}/${REL_NAME}"
  run installer_verify_release "$WORK" "$REL_NAME" "${RV_ROOT}/a.gpg" "$FPR_A"
  [[ "$status" -ne 0 ]]
  [[ ! -e "${WORK}/${REL_NAME}" ]]

  cp "${RV_ROOT}/dist/${REL_NAME}" "${RV_ROOT}/dist/SHA256SUMS" "$WORK/"
  _resign_with_b
  run installer_verify_release "$WORK" "$REL_NAME" "${RV_ROOT}/a.gpg" "$FPR_A"
  [[ "$status" -ne 0 ]]
}

@test "installer_load_release_key: 缺少 .fpr 或占位公钥 → 失败" {
  local inst="${WORK}/inst"
  mkdir -p "${inst}/keys"
  cp "${RV_ROOT}/a.asc" "${inst}/keys/debnas-release.asc"
  run installer_load_release_key "$inst" "${WORK}/k.gpg"
  [[ "$status" -ne 0 ]]
  echo "$FPR_A" > "${inst}/keys/debnas-release.fpr"
  echo "占位说明" > "${inst}/keys/debnas-release.asc"
  run installer_load_release_key "$inst" "${WORK}/k.gpg"
  [[ "$status" -ne 0 ]]
}

@test "installer_version_lt: sort -V 语义" {
  installer_version_lt v3.9.0 v3.10.0
  run installer_version_lt v3.10.0 v3.9.0
  [[ "$status" -ne 0 ]]
  run installer_version_lt v3.1.0 v3.1.0
  [[ "$status" -ne 0 ]]
}

@test "installer_valid_tag / installer_valid_branch: 拒绝路径穿越与特殊字符" {
  installer_valid_tag v3.1.0
  run installer_valid_tag "../x"
  [[ "$status" -ne 0 ]]
  run installer_valid_tag "a/b"
  [[ "$status" -ne 0 ]]
  run installer_valid_tag ""
  [[ "$status" -ne 0 ]]
  installer_valid_branch dev
  installer_valid_branch feature/x
  run installer_valid_branch "a/../b"
  [[ "$status" -ne 0 ]]
  run installer_valid_branch "a b"
  [[ "$status" -ne 0 ]]
}

# ==================== install.sh 参数 / preflight ====================

@test "install.sh: --branch 未加 --unsigned → 拒绝" {
  run bash -c 'source "$1"; parse_args --branch dev' _ "${DEBNAS_ROOT}/install.sh"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"--unsigned"* ]]
}

@test "install.sh: --unsigned 在非交互环境下拒绝（--yes 也不能跳过）" {
  run bash -c 'source "$1"; parse_args --unsigned --yes; preflight_source; echo REACHED' _ "${DEBNAS_ROOT}/install.sh" < /dev/null
  [[ "$status" -ne 0 ]]
  [[ "$output" != *"REACHED"* ]]
  [[ "$output" == *"非交互"* ]]
}

@test "install.sh: 内嵌公钥为空时默认安装报错并提示 --unsigned" {
  if [[ -n "$(bash -c 'source "$1"; echo "$DEBNAS_RELEASE_KEY_FPR"' _ "${DEBNAS_ROOT}/install.sh")" ]]; then
    skip "仓库已内嵌真实发布公钥"
  fi
  run bash -c 'source "$1"; parse_args; preflight_source' _ "${DEBNAS_ROOT}/install.sh"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"维护者尚未配置发布公钥"* ]]
  [[ "$output" == *"--unsigned"* ]]
}

# ==================== tools/release.sh --embed-key ====================

@test "release.sh --embed-key: 写入 install.sh 内嵌区块后可直接验证产物" {
  local repo="${WORK}/repo"
  mkdir -p "${repo}/tools" "${repo}/keys" "${repo}/lib/system"
  cp "${DEBNAS_ROOT}/install.sh" "${repo}/install.sh"
  cp "${DEBNAS_ROOT}/tools/release.sh" "${repo}/tools/release.sh"
  cp "${DEBNAS_ROOT}/lib/system/installer.sh" "${repo}/lib/system/installer.sh"
  run bash "${repo}/tools/release.sh" --embed-key "${RV_ROOT}/a.asc"
  [[ "$status" -eq 0 ]]
  [[ "$(cat "${repo}/keys/debnas-release.fpr")" == "$FPR_A" ]]
  bash -n "${repo}/install.sh"
  run bash -c 'source "$1"; set +e
    dearmor_pubkey "$DEBNAS_RELEASE_PUBKEY" "$2/k.gpg" || exit 9
    verify_release "$2" "$3" "$2/k.gpg" "$DEBNAS_RELEASE_KEY_FPR"' _ "${repo}/install.sh" "$WORK" "$REL_NAME"
  [[ "$status" -eq 0 ]]
}

@test "release.sh --embed-key: 拒绝私钥文件" {
  local repo="${WORK}/repo"
  mkdir -p "${repo}/tools" "${repo}/lib/system"
  cp "${DEBNAS_ROOT}/install.sh" "${repo}/install.sh"
  cp "${DEBNAS_ROOT}/tools/release.sh" "${repo}/tools/release.sh"
  cp "${DEBNAS_ROOT}/lib/system/installer.sh" "${repo}/lib/system/installer.sh"
  GNUPGHOME="$GNUPGHOME_B" gpg --batch --pinentry-mode loopback --passphrase '' \
    --armor --export-secret-keys "$FPR_B" > "${WORK}/secret.asc"
  run bash "${repo}/tools/release.sh" --embed-key "${WORK}/secret.asc"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"私钥"* ]]
  cmp -s "${repo}/install.sh" "${DEBNAS_ROOT}/install.sh"
}

# ==================== 审计修复：预发布版本比较 / 版本号统一 / 多指纹 / 公钥一致性 ====================

@test "installer_version_lt: 预发布版本低于同号正式版（sort -V 会判反）" {
  installer_version_lt v3.1.0-rc1 v3.1.0
  run installer_version_lt v3.1.0 v3.1.0-rc1
  [[ "$status" -ne 0 ]]
  installer_version_lt v3.1.0rc1 v3.1.0
  installer_version_lt v3.1.0-rc1 v3.1.0-rc2
  installer_version_lt v3.1.0-rc2 v3.1.1-rc1
  installer_version_lt v3.1.0 v3.1.1-rc1
  run installer_version_lt v3.1.1-rc1 v3.1.0
  [[ "$status" -ne 0 ]]
}

@test "cmd_update: 缺少 RELEASE 标记时退回用 DEBNAS_VERSION 做防降级比较" {
  sed -n '/^cmd_update()/,/^}/p' "${DEBNAS_ROOT}/bin/debnas" | grep -q 'installed_tag="$DEBNAS_VERSION"'
}

@test "release.sh --bump: 同步改 lib/system/args.sh 的 DEBNAS_VERSION" {
  local repo="${WORK}/repo"
  mkdir -p "${repo}/tools" "${repo}/lib/system"
  cp "${DEBNAS_ROOT}/install.sh" "${repo}/install.sh"
  cp "${DEBNAS_ROOT}/tools/release.sh" "${repo}/tools/release.sh"
  cp "${DEBNAS_ROOT}/lib/system/installer.sh" "${DEBNAS_ROOT}/lib/system/args.sh" "${repo}/lib/system/"
  run bash "${repo}/tools/release.sh" --bump v9.8.7
  [[ "$status" -eq 0 ]]
  grep -qx 'readonly DEBNAS_VERSION="${DEBNAS_VERSION:-v9.8.7}"' "${repo}/lib/system/args.sh"
  grep -qx 'readonly DEBNAS_RELEASE_TAG="v9.8.7"' "${repo}/install.sh"
  run bash -c 'unset DEBNAS_VERSION; source "$1"; echo "$DEBNAS_VERSION"' _ "${repo}/lib/system/args.sh"
  [[ "$output" == "v9.8.7" ]]
}

@test "installer_load_release_key: 指纹文件多行（密钥轮换），任一指纹匹配即通过" {
  local inst="${WORK}/inst"
  mkdir -p "${inst}/keys"
  cp "${RV_ROOT}/a.asc" "${inst}/keys/debnas-release.asc"
  printf '# 新旧主密钥并存\n%s\n\n%s\n' "$FPR_B" "$FPR_A" > "${inst}/keys/debnas-release.fpr"
  local fpr
  fpr=$(installer_load_release_key "$inst" "${WORK}/k.gpg")
  [[ "$fpr" == "${FPR_B},${FPR_A}" ]]
  run installer_verify_release "$WORK" "$REL_NAME" "${WORK}/k.gpg" "$fpr"
  [[ "$status" -eq 0 ]]
  # 两个指纹都不是签名者 → 失败
  cp "${RV_ROOT}/dist/${REL_NAME}" "${RV_ROOT}/dist/SHA256SUMS" "${RV_ROOT}/dist/SHA256SUMS.asc" "$WORK/"
  run installer_verify_release "$WORK" "$REL_NAME" "${WORK}/k.gpg" "${FPR_B},${FPR_B}"
  [[ "$status" -ne 0 ]]
  # 非法行 → 拒绝
  printf '%s\nnot-a-fpr\n' "$FPR_A" > "${inst}/keys/debnas-release.fpr"
  run installer_load_release_key "$inst" "${WORK}/k.gpg"
  [[ "$status" -ne 0 ]]
}

@test "release.sh --check-keys: keys/ 与内嵌公钥一致才通过；指纹文件多出没有对应公钥的指纹也算不一致" {
  local repo="${WORK}/repo"
  mkdir -p "${repo}/tools" "${repo}/keys" "${repo}/lib/system"
  cp "${DEBNAS_ROOT}/install.sh" "${repo}/install.sh"
  cp "${DEBNAS_ROOT}/tools/release.sh" "${repo}/tools/release.sh"
  cp "${DEBNAS_ROOT}/lib/system/installer.sh" "${DEBNAS_ROOT}/lib/system/args.sh" "${repo}/lib/system/"
  run bash "${repo}/tools/release.sh" --embed-key "${RV_ROOT}/a.asc"
  [[ "$status" -eq 0 ]]
  run bash "${repo}/tools/release.sh" --check-keys
  [[ "$status" -eq 0 ]]
  # 指纹文件里的注释、空行、大小写与空格不影响
  printf '# 发布主密钥\n\n%s\n' "$(echo "$FPR_A" | tr 'A-F' 'a-f' | sed 's/..../& /g')" > "${repo}/keys/debnas-release.fpr"
  run bash "${repo}/tools/release.sh" --check-keys
  [[ "$status" -eq 0 ]]
  # 指纹文件多出一把（内嵌区块与公钥文件里都没有它）→ 不一致；多钥并存须经 --embed-key --keep-old 生成
  printf '%s\n%s\n' "$FPR_B" "$FPR_A" > "${repo}/keys/debnas-release.fpr"
  run bash "${repo}/tools/release.sh" --check-keys
  [[ "$status" -ne 0 && "$output" == *"不一致"* ]]
  printf '%s\n' "$FPR_A" > "${repo}/keys/debnas-release.fpr"
  # keys/ 里的公钥被换成另一把 → 不一致
  GNUPGHOME="$GNUPGHOME_B" gpg --batch --armor --export "$FPR_B" > "${repo}/keys/debnas-release.asc"
  run bash "${repo}/tools/release.sh" --check-keys
  [[ "$status" -ne 0 && "$output" == *"不一致"* ]]
  # 指纹文件不含内嵌指纹 → 失败
  cp "${RV_ROOT}/a.asc" "${repo}/keys/debnas-release.asc"
  printf '%s\n' "$FPR_B" > "${repo}/keys/debnas-release.fpr"
  run bash "${repo}/tools/release.sh" --check-keys
  [[ "$status" -ne 0 ]]
}

@test "release.sh 构建发布：用 check_keys 比对 tag 内 keys/debnas-release.asc 与内嵌公钥" {
  sed -n '/^build_release()/,/^}/p' "${DEBNAS_ROOT}/tools/release.sh" | grep -q 'check_keys "$tag_install" "$tag_asc" "$tag_fprf"'
}
