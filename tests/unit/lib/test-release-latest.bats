#!/usr/bin/env bats
# 测试: 已签名的"最新版本"指针（LATEST / LATEST.asc）与换发布密钥的平滑过渡
#   - installer_verify_latest / installer_latest_tag：通过 / 篡改 LATEST / 换密钥签名 / 文件缺失回退
#   - cmd_update：指针校验未通过时拒绝自动更新
#   - tools/release.sh --sign-latest
#   - tools/release.sh --embed-key <新公钥> --keep-old：过渡版新旧两把都认；移除旧钥后旧钥签的包被拒
# 技术: 临时 GNUPGHOME 生成一次性测试密钥（绝不触碰 ~/.gnupg），wget 为 PATH Mock（不联网）
# 依赖: gpg、gpgv、sha256sum；缺 gpg 时整体跳过

load '../../helpers/common-setup'

setup_file() {
  if ! command -v gpg >/dev/null 2>&1 || ! command -v gpgv >/dev/null 2>&1; then
    return 0
  fi
  export RL_ROOT="${BATS_FILE_TMPDIR}/rl"
  mkdir -p "$RL_ROOT"
  chmod 700 "$RL_ROOT"
  export GNUPGHOME_OLD="${RL_ROOT}/gnupg-old" GNUPGHOME_NEW="${RL_ROOT}/gnupg-new"
  mkdir -m 700 "$GNUPGHOME_OLD" "$GNUPGHOME_NEW"

  # 旧发布密钥（现役）：主密钥 + 签名子密钥
  GNUPGHOME="$GNUPGHOME_OLD" gpg --batch --pinentry-mode loopback --passphrase '' \
    --quick-gen-key "DebNAS Old <old@example.invalid>" ed25519 sign 1d 2>/dev/null
  export FPR_OLD
  FPR_OLD=$(GNUPGHOME="$GNUPGHOME_OLD" gpg --batch --with-colons -k 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }')
  GNUPGHOME="$GNUPGHOME_OLD" gpg --batch --pinentry-mode loopback --passphrase '' \
    --quick-add-key "$FPR_OLD" ed25519 sign 1d 2>/dev/null
  # 新发布密钥（换钥目标；在"换密钥签名"用例里也充当不受信任的密钥）
  GNUPGHOME="$GNUPGHOME_NEW" gpg --batch --pinentry-mode loopback --passphrase '' \
    --quick-gen-key "DebNAS New <new@example.invalid>" ed25519 sign 1d 2>/dev/null
  export FPR_NEW
  FPR_NEW=$(GNUPGHOME="$GNUPGHOME_NEW" gpg --batch --with-colons -k 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }')

  GNUPGHOME="$GNUPGHOME_OLD" gpg --batch --armor --export-options export-minimal --export "$FPR_OLD" > "${RL_ROOT}/old.asc"
  GNUPGHOME="$GNUPGHOME_OLD" gpg --batch --export-options export-minimal --export "$FPR_OLD" > "${RL_ROOT}/old.gpg"
  GNUPGHOME="$GNUPGHOME_NEW" gpg --batch --armor --export-options export-minimal --export "$FPR_NEW" > "${RL_ROOT}/new.asc"
  GNUPGHOME="$GNUPGHOME_NEW" gpg --batch --export-options export-minimal --export "$FPR_NEW" > "${RL_ROOT}/new.gpg"

  # 两份发布产物：同一个 tar 包，分别由旧钥、新钥签名
  export REL_NAME="debnas-v9.9.9.tar.gz"
  mkdir -p "${RL_ROOT}/src/debnas/bin" "${RL_ROOT}/dist-old" "${RL_ROOT}/dist-new"
  echo 'echo hello' > "${RL_ROOT}/src/debnas/bin/debnas"
  tar -czf "${RL_ROOT}/dist-old/${REL_NAME}" -C "${RL_ROOT}/src" debnas
  (cd "${RL_ROOT}/dist-old" && sha256sum "$REL_NAME" > SHA256SUMS)
  cp "${RL_ROOT}/dist-old/${REL_NAME}" "${RL_ROOT}/dist-old/SHA256SUMS" "${RL_ROOT}/dist-new/"
  GNUPGHOME="$GNUPGHOME_OLD" gpg --batch --pinentry-mode loopback --passphrase '' \
    --detach-sign --armor -o "${RL_ROOT}/dist-old/SHA256SUMS.asc" "${RL_ROOT}/dist-old/SHA256SUMS" 2>/dev/null
  GNUPGHOME="$GNUPGHOME_NEW" gpg --batch --pinentry-mode loopback --passphrase '' \
    --detach-sign --armor -o "${RL_ROOT}/dist-new/SHA256SUMS.asc" "${RL_ROOT}/dist-new/SHA256SUMS" 2>/dev/null
}

teardown_file() {
  if [[ -n "${GNUPGHOME_OLD:-}" ]] && command -v gpgconf >/dev/null 2>&1; then
    GNUPGHOME="$GNUPGHOME_OLD" gpgconf --kill all 2>/dev/null || true
    GNUPGHOME="$GNUPGHOME_NEW" gpgconf --kill all 2>/dev/null || true
  fi
  if [[ -n "${RL_ROOT:-}" && -d "$RL_ROOT" ]]; then
    rm -rf -- "${RL_ROOT:?}"
  fi
}

setup() {
  if [[ -z "${RL_ROOT:-}" ]]; then
    skip "需要 gpg 与 gpgv 生成测试密钥"
  fi
  export NO_COLOR=1
  setup_debnas_lib
  source "${DEBNAS_ROOT}/lib/system/installer.sh"
  WORK="$(mktemp -d "${BATS_TEST_TMPDIR}/w.XXXXXX")"
  # 已安装目录：只信任旧钥
  INST="${WORK}/inst"
  mkdir -p "${INST}/keys"
  cp "${RL_ROOT}/old.asc" "${INST}/keys/debnas-release.asc"
  echo "$FPR_OLD" > "${INST}/keys/debnas-release.fpr"

  # wget Mock：github → $WWW/global/<文件>，gitee → $WWW/cn/<文件>；文件不存在返回 8（同 HTTP 404）
  export WWW="${WORK}/www"
  mkdir -p "${WWW}/global" "${WWW}/cn" "${WORK}/mockbin"
  cat > "${WORK}/mockbin/wget" <<'EOF'
#!/bin/bash
out="" url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -O) out="$2"; shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
case "$url" in
  https://github.com/kekylin/debnas/raw/main/*) src="${WWW}/global/${url##*/raw/main/}" ;;
  https://gitee.com/kekylin/debnas/raw/main/*)  src="${WWW}/cn/${url##*/raw/main/}" ;;
  *) src="" ;;
esac
echo "$url" >> "${WWW}/requests.log"
: > "$out"
[[ -n "$src" && -f "$src" ]] || exit 8
cat "$src" > "$out"
EOF
  chmod +x "${WORK}/mockbin/wget"
  PATH="${WORK}/mockbin:${PATH}"
}

# 生成 LATEST + LATEST.asc 到指定目录
# 参数：$1 - 目录  $2 - tag  $3 - GNUPGHOME（签名用）
_mk_latest() {
  mkdir -p "$1"
  printf '%s\n' "$2" > "$1/LATEST"
  GNUPGHOME="$3" gpg --batch --yes --pinentry-mode loopback --passphrase '' \
    --detach-sign --armor -o "$1/LATEST.asc" "$1/LATEST" 2>/dev/null
}

# 在两个"下载源"都放上同一份已签名指针
_publish_latest() {
  _mk_latest "${WWW}/global" "$1" "$2"
  cp "${WWW}/global/LATEST" "${WWW}/global/LATEST.asc" "${WWW}/cn/"
}

# 回退来源：main 分支 install.sh 里的版本号
_publish_installer_tag() {
  printf 'readonly DEBNAS_RELEASE_TAG="%s"\n' "$1" > "${WWW}/global/install.sh"
  cp "${WWW}/global/install.sh" "${WWW}/cn/install.sh"
}

_load_key() {
  FPRS=$(installer_load_release_key "$INST" "${WORK}/keyring.gpg")
}

# 在仓库副本上运行 tools/release.sh
_mk_repo() {
  REPO="${WORK}/repo"
  mkdir -p "${REPO}/tools" "${REPO}/keys" "${REPO}/lib/system"
  cp "${DEBNAS_ROOT}/install.sh" "${REPO}/install.sh"
  cp "${DEBNAS_ROOT}/tools/release.sh" "${REPO}/tools/release.sh"
  cp "${DEBNAS_ROOT}/lib/system/installer.sh" "${DEBNAS_ROOT}/lib/system/args.sh" "${REPO}/lib/system/"
}

# ==================== installer_verify_latest ====================

@test "LATEST: 发布密钥签名 → 通过并输出 tag（签名由子密钥完成，匹配主密钥指纹）" {
  _load_key
  _mk_latest "${WORK}/p" v9.9.9 "$GNUPGHOME_OLD"
  run installer_verify_latest "${WORK}/p" "${WORK}/keyring.gpg" "$FPRS"
  [[ "$status" -eq 0 && "$output" == "v9.9.9" ]]
}

@test "LATEST: 内容被篡改 → 拒绝" {
  _load_key
  _mk_latest "${WORK}/p" v9.9.9 "$GNUPGHOME_OLD"
  echo "v1.0.0" > "${WORK}/p/LATEST"
  run installer_verify_latest "${WORK}/p" "${WORK}/keyring.gpg" "$FPRS"
  [[ "$status" -ne 0 && "$output" == *"LATEST 签名验证失败"* && "$output" != "v1.0.0" ]]
}

@test "LATEST: 换成另一把密钥签名 → 拒绝（公钥不在 keyring / 指纹不在期望列表）" {
  _load_key
  _mk_latest "${WORK}/p" v9.9.9 "$GNUPGHOME_NEW"
  run installer_verify_latest "${WORK}/p" "${WORK}/keyring.gpg" "$FPRS"
  [[ "$status" -ne 0 && "$output" == *"签名验证失败"* ]]
  # 即使 keyring 被换成那把密钥，指纹也对不上
  run installer_verify_latest "${WORK}/p" "${RL_ROOT}/new.gpg" "$FPRS"
  [[ "$status" -ne 0 && "$output" == *"签名者指纹不匹配"* ]]
}

@test "LATEST: 签名有效但内容不是一行合法 tag → 拒绝" {
  _load_key
  local bad
  for bad in $'v1.0.0\nv2.0.0' "../../etc/passwd" "v1 0" "abc  debnas-v1.tar.gz"; do
    mkdir -p "${WORK}/p"
    printf '%s\n' "$bad" > "${WORK}/p/LATEST"
    GNUPGHOME="$GNUPGHOME_OLD" gpg --batch --yes --pinentry-mode loopback --passphrase '' \
      --detach-sign --armor -o "${WORK}/p/LATEST.asc" "${WORK}/p/LATEST" 2>/dev/null
    run installer_verify_latest "${WORK}/p" "${WORK}/keyring.gpg" "$FPRS"
    [[ "$status" -ne 0 && "$output" == *"LATEST 内容无效"* ]]
  done
}

@test "LATEST: 不能拿 SHA256SUMS 的签名冒充（签名与文件一一对应）" {
  _load_key
  mkdir -p "${WORK}/p"
  echo v9.9.9 > "${WORK}/p/LATEST"
  cp "${RL_ROOT}/dist-old/SHA256SUMS.asc" "${WORK}/p/LATEST.asc"
  run installer_verify_latest "${WORK}/p" "${WORK}/keyring.gpg" "$FPRS"
  [[ "$status" -ne 0 ]]
}

# ==================== installer_latest_tag ====================

@test "installer_latest_tag: 已签名指针通过 → 采用，不再读 install.sh" {
  _load_key
  _publish_latest v9.9.9 "$GNUPGHOME_OLD"
  _publish_installer_tag v1.0.0
  run installer_latest_tag global "$WORK" "${WORK}/keyring.gpg" "$FPRS"
  [[ "$status" -eq 0 && "$output" == "v9.9.9" ]]
  run grep -c 'install.sh' "${WWW}/requests.log"
  [[ "$output" == "0" ]]
  [[ ! -e "${WORK}/latest.d" ]]
}

@test "installer_latest_tag: region=cn 优先 Gitee；主源缺文件时从备用源成对取" {
  _load_key
  _mk_latest "${WWW}/global" v9.9.9 "$GNUPGHOME_OLD"
  run installer_latest_tag cn "$WORK" "${WORK}/keyring.gpg" "$FPRS"
  [[ "$status" -eq 0 && "$output" == "v9.9.9" ]]
  [[ "$(head -n 1 "${WWW}/requests.log")" == "https://gitee.com/kekylin/debnas/raw/main/LATEST" ]]
}

@test "installer_latest_tag: LATEST 被篡改 → 返回 2，不回退到 install.sh" {
  _load_key
  _publish_latest v9.9.9 "$GNUPGHOME_OLD"
  echo "v1.0.0" > "${WWW}/global/LATEST"
  _publish_installer_tag v9.9.9
  run installer_latest_tag global "$WORK" "${WORK}/keyring.gpg" "$FPRS"
  [[ "$status" -eq 2 ]]
  [[ "$output" == *"签名校验未通过"* ]]
  run grep -c 'install.sh' "${WWW}/requests.log"
  [[ "$output" == "0" ]]
}

@test "installer_latest_tag: 指针换成另一把密钥签名 → 返回 2" {
  _load_key
  _publish_latest v9.9.9 "$GNUPGHOME_NEW"
  _publish_installer_tag v9.9.9
  run installer_latest_tag global "$WORK" "${WORK}/keyring.gpg" "$FPRS"
  [[ "$status" -eq 2 ]]
}

@test "installer_latest_tag: 只有 LATEST 没有 LATEST.asc → 返回 2（不当作"未发布"回退）" {
  _load_key
  echo v9.9.9 > "${WWW}/global/LATEST"
  _publish_installer_tag v9.9.9
  run installer_latest_tag global "$WORK" "${WORK}/keyring.gpg" "$FPRS"
  [[ "$status" -eq 2 && "$output" == *"LATEST.asc"* ]]
}

@test "installer_latest_tag: 两个文件都取不到 → 告警并回退读 install.sh 的版本号" {
  _load_key
  _publish_installer_tag v8.8.8
  run installer_latest_tag global "$WORK" "${WORK}/keyring.gpg" "$FPRS"
  [[ "$status" -eq 0 ]]
  [[ "${lines[-1]}" == "v8.8.8" ]]
  [[ "$output" == *"未取到已签名的版本指针"* && "$output" == *"未签名"* ]]
  # 只有 tag 走 stdout（调用方用 $(…) 取值），告警在 stderr
  local out
  out=$(installer_latest_tag global "$WORK" "${WORK}/keyring.gpg" "$FPRS" 2>/dev/null)
  [[ "$out" == "v8.8.8" ]]
}

@test "installer_latest_tag: 指针与 install.sh 都取不到 → 返回 1" {
  _load_key
  run installer_latest_tag global "$WORK" "${WORK}/keyring.gpg" "$FPRS"
  [[ "$status" -eq 1 ]]
}

# ==================== cmd_update ====================

# 运行真实 cmd_update 到"确定目标版本"为止（下载发布包处用桩拦住）
# 参数：$1 - 已安装版本
_run_update_until_download() {
  run bash -c '
    set -euo pipefail
    SRC="$1"; R="$2"; INSTALLED="$3"
    # 与 lib/core/logging.sh 一样写 stderr（installer_latest_tag 的 stdout 只有 tag）
    log_info() { echo "INFO: $*" >&2; }; log_success() { echo "OK: $*" >&2; }
    log_warning() { echo "WARN: $*" >&2; }; log_error() { echo "ERROR: $*" >&2; }
    config_read() { echo "global"; }
    create_temp_dir() { mktemp -d "$R/tmp.XXXXXX"; }
    DEBNAS_VERSION="$INSTALLED"
    export DEBNAS_UPDATE_LOCK="$R/update.lock"
    source "$SRC/lib/system/installer.sh"
    installer_download_release() { echo "DOWNLOAD $2"; return 1; }
    eval "$(sed -n "/^cmd_update()/,/^}/p" "$SRC/bin/debnas" | sed "s#/usr/local/bin/debnas#$R/ulb/debnas#g; s#/opt/debnas#$R/inst#g")"
    cmd_update
  ' _ "${DEBNAS_ROOT}" "$WORK" "$1"
}

@test "cmd_update: 已签名指针通过 → 以它为目标版本" {
  _publish_latest v9.9.9 "$GNUPGHOME_OLD"
  _publish_installer_tag v1.0.0
  _run_update_until_download v9.0.0
  [[ "$output" == *"目标版本：v9.9.9"* && "$output" == *"DOWNLOAD v9.9.9"* ]]
  [[ "$output" != *"未签名"* ]]
}

@test "cmd_update: 指针被篡改 → 拒绝自动更新，不下载任何版本" {
  _publish_latest v9.9.9 "$GNUPGHOME_OLD"
  echo "v9.9.8" > "${WWW}/global/LATEST"
  cp "${WWW}/global/LATEST" "${WWW}/cn/LATEST"
  _publish_installer_tag v9.9.9
  _run_update_until_download v9.0.0
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"拒绝自动更新"* && "$output" != *"DOWNLOAD"* ]]
  # 没有残留临时目录
  run bash -c 'ls -d "$1"/tmp.* 2>/dev/null | wc -l' _ "$WORK"
  [[ "$output" == "0" ]]
}

@test "cmd_update: 已签名的旧指针被重放 → 仍拒绝降级" {
  _publish_latest v8.0.0 "$GNUPGHOME_OLD"
  _run_update_until_download v9.0.0
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"拒绝自动降级"* && "$output" != *"DOWNLOAD"* ]]
}

@test "cmd_update: 指针未发布 → 回退到 install.sh 版本号并告警，只升不降" {
  _publish_installer_tag v9.9.9
  _run_update_until_download v9.0.0
  [[ "$output" == *"WARN: 未取到已签名的版本指针"* && "$output" == *"DOWNLOAD v9.9.9"* ]]
  _publish_installer_tag v8.0.0
  _run_update_until_download v9.0.0
  [[ "$status" -eq 1 && "$output" == *"拒绝自动降级"* && "$output" != *"DOWNLOAD"* ]]
}

# ==================== tools/release.sh --sign-latest ====================

@test "release.sh --sign-latest: 生成的 LATEST / LATEST.asc 能通过 debnas update 的验证" {
  _mk_repo
  run env GNUPGHOME="$GNUPGHOME_OLD" bash "${REPO}/tools/release.sh" --embed-key "${RL_ROOT}/old.asc"
  [[ "$status" -eq 0 ]]
  run env GNUPGHOME="$GNUPGHOME_OLD" bash "${REPO}/tools/release.sh" --sign-latest v9.9.9 "$FPR_OLD"
  [[ "$status" -eq 0 ]]
  [[ "$(cat "${REPO}/LATEST")" == "v9.9.9" ]]
  grep -q 'BEGIN PGP SIGNATURE' "${REPO}/LATEST.asc"
  _load_key
  mkdir -p "${WORK}/p"
  cp "${REPO}/LATEST" "${REPO}/LATEST.asc" "${WORK}/p/"
  run installer_verify_latest "${WORK}/p" "${WORK}/keyring.gpg" "$FPRS"
  [[ "$status" -eq 0 && "$output" == "v9.9.9" ]]
}

@test "release.sh --sign-latest: 签名密钥不在 keys/ 指纹之内 / tag 非法 → 拒绝且不写文件" {
  _mk_repo
  run env GNUPGHOME="$GNUPGHOME_OLD" bash "${REPO}/tools/release.sh" --embed-key "${RL_ROOT}/old.asc"
  [[ "$status" -eq 0 ]]
  run env GNUPGHOME="$GNUPGHOME_NEW" bash "${REPO}/tools/release.sh" --sign-latest v9.9.9 "$FPR_NEW"
  [[ "$status" -ne 0 && "$output" == *"不在 keys/debnas-release.fpr"* ]]
  [[ ! -e "${REPO}/LATEST" && ! -e "${REPO}/LATEST.asc" ]]
  run env GNUPGHOME="$GNUPGHOME_OLD" bash "${REPO}/tools/release.sh" --sign-latest "../x" "$FPR_OLD"
  [[ "$status" -ne 0 && ! -e "${REPO}/LATEST" ]]
  run env GNUPGHOME="$GNUPGHOME_OLD" bash "${REPO}/tools/release.sh" --sign-latest v9.9.9
  [[ "$status" -ne 0 ]]
}

@test "release.sh 构建发布：正式版本自动生成 LATEST，预发布版本与较旧版本不动指针" {
  local body
  body=$(sed -n '/^build_release()/,/^}/p' "${DEBNAS_ROOT}/tools/release.sh")
  [[ "$body" == *'sign_latest "$tag" "$keyid"'* && "$body" == *'is_stable_tag "$tag"'* ]]
  [[ "$body" == *"debnas/keys/debnas-release.asc"* ]]
  run bash -c 'eval "$(sed -n "/^is_stable_tag()/,/^}/p" "$1")"
    is_stable_tag v2026.11.0 && is_stable_tag 3.1.0 && ! is_stable_tag v3.1.0-rc1 && ! is_stable_tag v3.1.0rc1 && ! is_stable_tag "v3.1.0~beta" && ! is_stable_tag ""' \
    _ "${DEBNAS_ROOT}/tools/release.sh"
  [[ "$status" -eq 0 ]]
}

# ==================== 换发布密钥：--embed-key --keep-old ====================

# 用仓库副本里的 install.sh（内嵌公钥）验证一份产物
# 参数：$1 - 产物目录（dist-old / dist-new）
_inst_verify() {
  local d="${WORK}/v.$RANDOM"
  mkdir -p "$d"
  cp "${RL_ROOT}/$1/${REL_NAME}" "${RL_ROOT}/$1/SHA256SUMS" "${RL_ROOT}/$1/SHA256SUMS.asc" "$d/"
  bash -c 'source "$1"; set +e
    dearmor_pubkey "$DEBNAS_RELEASE_PUBKEY" "$2/k.gpg" || exit 9
    verify_release "$2" "$3" "$2/k.gpg" "$DEBNAS_RELEASE_KEY_FPR"' _ "${REPO}/install.sh" "$d" "$REL_NAME"
}

# 用仓库副本里的 keys/（即安装后 debnas update 用的那份）验证一份产物
_lib_verify() {
  local d="${WORK}/v.$RANDOM" fprs
  mkdir -p "$d"
  cp "${RL_ROOT}/$1/${REL_NAME}" "${RL_ROOT}/$1/SHA256SUMS" "${RL_ROOT}/$1/SHA256SUMS.asc" "$d/"
  fprs=$(installer_load_release_key "$REPO" "$d/k.gpg") || return 9
  installer_verify_release "$d" "$REL_NAME" "$d/k.gpg" "$fprs"
}

@test "换钥过渡版: --embed-key <新> --keep-old 后 keys/ 与内嵌区块含两把公钥，新旧钥签的包都通过" {
  _mk_repo
  run bash "${REPO}/tools/release.sh" --embed-key "${RL_ROOT}/old.asc"
  [[ "$status" -eq 0 ]]
  run bash "${REPO}/tools/release.sh" --embed-key "${RL_ROOT}/new.asc" --keep-old
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"同时保留旧公钥: ${FPR_OLD}"* ]]

  # 指纹文件两行（新钥在前），公钥文件两个块，内嵌指纹逗号分隔
  [[ "$(cat "${REPO}/keys/debnas-release.fpr")" == "${FPR_NEW}"$'\n'"${FPR_OLD}" ]]
  [[ "$(grep -c 'BEGIN PGP PUBLIC KEY BLOCK' "${REPO}/keys/debnas-release.asc")" -eq 2 ]]
  grep -qx "readonly DEBNAS_RELEASE_KEY_FPR=\"${FPR_NEW},${FPR_OLD}\"" "${REPO}/install.sh"
  bash -n "${REPO}/install.sh"
  # 解码出的 keyring = 两把公钥二进制依次拼接
  release_dearmor "${WORK}/both.gpg" < "${REPO}/keys/debnas-release.asc"
  cmp -s "${WORK}/both.gpg" <(cat "${RL_ROOT}/new.gpg" "${RL_ROOT}/old.gpg")

  run bash "${REPO}/tools/release.sh" --check-keys
  [[ "$status" -eq 0 ]]

  # install.sh（内嵌公钥）与 debnas update（keys/）两条路径，新旧钥签的包都认
  run _inst_verify dist-old; [[ "$status" -eq 0 ]]
  run _inst_verify dist-new; [[ "$status" -eq 0 ]]
  run _lib_verify dist-old;  [[ "$status" -eq 0 ]]
  run _lib_verify dist-new;  [[ "$status" -eq 0 ]]

  # 版本指针同理：过渡版上旧钥、新钥签的 LATEST 都通过
  local fprs
  fprs=$(installer_load_release_key "$REPO" "${WORK}/k2.gpg")
  [[ "$fprs" == "${FPR_NEW},${FPR_OLD}" ]]
  _mk_latest "${WORK}/p-old" v9.9.9 "$GNUPGHOME_OLD"
  _mk_latest "${WORK}/p-new" v9.9.9 "$GNUPGHOME_NEW"
  run installer_verify_latest "${WORK}/p-old" "${WORK}/k2.gpg" "$fprs"; [[ "$status" -eq 0 ]]
  run installer_verify_latest "${WORK}/p-new" "${WORK}/k2.gpg" "$fprs"; [[ "$status" -eq 0 ]]
  # 过渡版里两把钥都可以签 LATEST
  run env GNUPGHOME="$GNUPGHOME_NEW" bash "${REPO}/tools/release.sh" --sign-latest v9.9.9 "$FPR_NEW"
  [[ "$status" -eq 0 ]]
}

@test "换钥第二步: 不带 --keep-old 重新 --embed-key 移除旧钥后，旧钥签的包被拒、新钥签的包通过" {
  _mk_repo
  run bash "${REPO}/tools/release.sh" --embed-key "${RL_ROOT}/old.asc"
  [[ "$status" -eq 0 ]]
  run bash "${REPO}/tools/release.sh" --embed-key "${RL_ROOT}/new.asc" --keep-old
  [[ "$status" -eq 0 ]]
  run bash "${REPO}/tools/release.sh" --embed-key "${RL_ROOT}/new.asc"
  [[ "$status" -eq 0 ]]
  [[ "$(cat "${REPO}/keys/debnas-release.fpr")" == "$FPR_NEW" ]]
  [[ "$(grep -c 'BEGIN PGP PUBLIC KEY BLOCK' "${REPO}/keys/debnas-release.asc")" -eq 1 ]]
  grep -qx "readonly DEBNAS_RELEASE_KEY_FPR=\"${FPR_NEW}\"" "${REPO}/install.sh"
  run bash "${REPO}/tools/release.sh" --check-keys
  [[ "$status" -eq 0 ]]

  run _inst_verify dist-new; [[ "$status" -eq 0 ]]
  run _lib_verify dist-new;  [[ "$status" -eq 0 ]]
  run _inst_verify dist-old
  [[ "$status" -ne 0 && "$output" == *"签名验证失败"* ]]
  run _lib_verify dist-old
  [[ "$status" -ne 0 ]]
}

@test "换钥前（只有旧钥）: 新钥签的包被拒 —— 所以必须先发过渡版" {
  _mk_repo
  run bash "${REPO}/tools/release.sh" --embed-key "${RL_ROOT}/old.asc"
  [[ "$status" -eq 0 ]]
  run _inst_verify dist-old; [[ "$status" -eq 0 ]]
  run _inst_verify dist-new; [[ "$status" -ne 0 ]]
  run _lib_verify dist-new;  [[ "$status" -ne 0 ]]
}

@test "--embed-key --keep-old: 重复执行幂等；没有现成 keys/ 时报错；参数位置错误报用法" {
  _mk_repo
  run bash "${REPO}/tools/release.sh" --embed-key "${RL_ROOT}/new.asc" --keep-old
  [[ "$status" -ne 0 && "$output" == *"--keep-old 需要现有的"* ]]
  run bash "${REPO}/tools/release.sh" --embed-key "${RL_ROOT}/old.asc"
  [[ "$status" -eq 0 ]]
  run bash "${REPO}/tools/release.sh" --embed-key "${RL_ROOT}/new.asc" --keep-old
  [[ "$status" -eq 0 ]]
  cp "${REPO}/install.sh" "${WORK}/install.1"; cp "${REPO}/keys/debnas-release.asc" "${WORK}/asc.1"
  run bash "${REPO}/tools/release.sh" --embed-key "${RL_ROOT}/new.asc" --keep-old
  [[ "$status" -eq 0 ]]
  cmp -s "${REPO}/install.sh" "${WORK}/install.1"
  cmp -s "${REPO}/keys/debnas-release.asc" "${WORK}/asc.1"
  [[ "$(cat "${REPO}/keys/debnas-release.fpr")" == "${FPR_NEW}"$'\n'"${FPR_OLD}" ]]
  run bash "${REPO}/tools/release.sh" --embed-key --keep-old "${RL_ROOT}/new.asc"
  [[ "$status" -ne 0 ]]
}

@test "--check-keys（多钥）: 指纹文件、公钥文件、内嵌区块三者任一对不上都报错" {
  _mk_repo
  run bash "${REPO}/tools/release.sh" --embed-key "${RL_ROOT}/old.asc"
  [[ "$status" -eq 0 ]]
  run bash "${REPO}/tools/release.sh" --embed-key "${RL_ROOT}/new.asc" --keep-old
  [[ "$status" -eq 0 ]]
  cp -R "${REPO}/keys" "${WORK}/keys.good"
  # 指纹文件少一行
  echo "$FPR_NEW" > "${REPO}/keys/debnas-release.fpr"
  run bash "${REPO}/tools/release.sh" --check-keys
  [[ "$status" -ne 0 && "$output" == *"不一致"* ]]
  # 指纹文件顺序不同不算错
  printf '%s\n%s\n' "$FPR_OLD" "$FPR_NEW" > "${REPO}/keys/debnas-release.fpr"
  run bash "${REPO}/tools/release.sh" --check-keys
  [[ "$status" -eq 0 ]]
  # 公钥文件少一把
  cp "${RL_ROOT}/new.asc" "${REPO}/keys/debnas-release.asc"
  run bash "${REPO}/tools/release.sh" --check-keys
  [[ "$status" -ne 0 && "$output" == *"不一致"* ]]
  # 恢复后通过
  cp "${WORK}/keys.good/"* "${REPO}/keys/"
  run bash "${REPO}/tools/release.sh" --check-keys
  [[ "$status" -eq 0 ]]
}
