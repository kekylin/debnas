#!/usr/bin/env bats
# 测试: 发布校验逻辑单一来源
#   - lib/system/installer.sh 与 install.sh 的 DEBNAS-RELEASE-VERIFY 区块逐字一致
#   - tools/release.sh --sync-verify 能把 install.sh 中被改动的区块恢复为 lib 版本
#   - install.sh 仍可单文件运行（不依赖 lib）
# 技术: 临时仓库副本，绝不修改工作区文件

load '../../helpers/common-setup'

# 提取区块（含起止标记行）
_block() {
  awk '/^# >>> DEBNAS-RELEASE-VERIFY-BEGIN/ { p = 1 } p { print } /^# <<< DEBNAS-RELEASE-VERIFY-END/ { p = 0 }' "$1"
}

setup() {
  export NO_COLOR=1
  WORK="$(mktemp -d "${BATS_TMPDIR}/sync.XXXXXX")"
}

teardown() {
  [[ -n "${WORK:-}" ]] && rm -rf -- "$WORK"
}

@test "release-sync: 两份发布校验区块逐字一致" {
  local a b
  a=$(_block "${DEBNAS_ROOT}/lib/system/installer.sh")
  b=$(_block "${DEBNAS_ROOT}/install.sh")
  [[ -n "$a" ]]
  [[ "$a" == *"release_verify()"* && "$a" == *"release_dearmor()"* && "$a" == *"release_check_sig()"* ]]
  [[ "$a" == "$b" ]]
}

@test "release-sync: 起止标记在两个文件中各恰好一个" {
  local f
  for f in "${DEBNAS_ROOT}/lib/system/installer.sh" "${DEBNAS_ROOT}/install.sh"; do
    [[ "$(grep -c '^# >>> DEBNAS-RELEASE-VERIFY-BEGIN' "$f")" -eq 1 ]]
    [[ "$(grep -c '^# <<< DEBNAS-RELEASE-VERIFY-END' "$f")" -eq 1 ]]
  done
}

@test "release-sync: --sync-verify 恢复被手改的 install.sh 区块，已一致时不改文件" {
  local repo="${WORK}/repo"
  mkdir -p "${repo}/tools" "${repo}/lib/system"
  cp "${DEBNAS_ROOT}/install.sh" "${repo}/install.sh"
  cp "${DEBNAS_ROOT}/tools/release.sh" "${repo}/tools/release.sh"
  cp "${DEBNAS_ROOT}/lib/system/installer.sh" "${repo}/lib/system/installer.sh"
  sed -i 's/SHA256 校验失败/SHA256 被手改/' "${repo}/install.sh"
  run cmp -s <(_block "${repo}/install.sh") <(_block "${repo}/lib/system/installer.sh")
  [[ "$status" -ne 0 ]]

  run bash "${repo}/tools/release.sh" --sync-verify
  [[ "$status" -eq 0 ]]
  cmp -s <(_block "${repo}/install.sh") <(_block "${repo}/lib/system/installer.sh")
  cmp -s "${repo}/install.sh" "${DEBNAS_ROOT}/install.sh"

  run bash "${repo}/tools/release.sh" --sync-verify
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"一致"* ]]
}

@test "release-sync: --sync-verify 缺少 lib 单一来源时报错且不改 install.sh" {
  local repo="${WORK}/repo"
  mkdir -p "${repo}/tools"
  cp "${DEBNAS_ROOT}/install.sh" "${repo}/install.sh"
  cp "${DEBNAS_ROOT}/tools/release.sh" "${repo}/tools/release.sh"
  run bash "${repo}/tools/release.sh" --sync-verify
  [[ "$status" -ne 0 ]]
  cmp -s "${repo}/install.sh" "${DEBNAS_ROOT}/install.sh"
}

@test "release-sync: install.sh 单文件可运行（不加载 lib 即有全部校验函数）" {
  cp "${DEBNAS_ROOT}/install.sh" "${WORK}/install.sh"
  run bash -c 'source "$1"; for f in release_verify release_check_sig release_dearmor release_discard deploy_install_wrapper release_valid_tag release_valid_branch verify_release dearmor_pubkey is_valid_tag is_valid_branch release_fetch release_fetch_assets release_extract; do declare -F "$f" >/dev/null || { echo "缺少 $f"; exit 1; }; done; declare -F log_error >/dev/null && exit 2; is_valid_tag v3.1.0 && ! is_valid_tag ../x' _ "${WORK}/install.sh"
  [[ "$status" -eq 0 ]]
}

@test "release-sync: install.sh 中区块错误输出保持 [FAIL] 格式" {
  run bash -c 'source "$1"; verify_release /nonexistent debnas-v1.tar.gz /nonexistent ""' _ "${DEBNAS_ROOT}/install.sh"
  [[ "$status" -ne 0 ]]
  [[ "$output" == "[FAIL] 发布公钥指纹无效或未配置"* ]]
}

# ==================== DEBNAS-DEPLOY 区块（安装目录整树替换，install.sh 与 update 共用） ====================

_dblock() {
  awk '/^# >>> DEBNAS-DEPLOY-BEGIN/ { p = 1 } p { print } /^# <<< DEBNAS-DEPLOY-END/ { p = 0 }' "$1"
}

@test "release-sync: 两份部署区块逐字一致、标记各恰好一个" {
  local a b f
  a=$(_dblock "${DEBNAS_ROOT}/lib/system/installer.sh")
  b=$(_dblock "${DEBNAS_ROOT}/install.sh")
  [[ "$a" == *"deploy_tree()"* && "$a" == *"deploy_recover()"* && "$a" == *"deploy_lock()"* && "$a" == *"deploy_install_wrapper()"* ]]
  [[ "$a" == "$b" ]]
  for f in "${DEBNAS_ROOT}/lib/system/installer.sh" "${DEBNAS_ROOT}/install.sh"; do
    [[ "$(grep -c '^# >>> DEBNAS-DEPLOY-BEGIN' "$f")" -eq 1 && "$(grep -c '^# <<< DEBNAS-DEPLOY-END' "$f")" -eq 1 ]]
  done
}

@test "release-sync: --sync-verify 同时恢复被手改的部署区块" {
  local repo="${WORK}/repo"
  mkdir -p "${repo}/tools" "${repo}/lib/system"
  cp "${DEBNAS_ROOT}/install.sh" "${repo}/install.sh"
  cp "${DEBNAS_ROOT}/tools/release.sh" "${repo}/tools/release.sh"
  cp "${DEBNAS_ROOT}/lib/system/installer.sh" "${repo}/lib/system/installer.sh"
  sed -i 's/组装新版本失败/被手改/' "${repo}/install.sh"
  run bash "${repo}/tools/release.sh" --sync-verify
  [[ "$status" -eq 0 ]]
  cmp -s "${repo}/install.sh" "${DEBNAS_ROOT}/install.sh"
}

@test "install.sh: 覆盖安装改用 deploy_tree 整树替换，失败即中止（不再 cp -rf … || true）" {
  local body
  body=$(sed -n '/^extract_repo()/,/^}/p' "${DEBNAS_ROOT}/install.sh")
  [[ "$body" == *'deploy_tree "$extract_dir" "$DEBNAS_INSTALL_DIR"'* ]]
  [[ "$body" == *"exit 1"* ]]
  run grep -cE '^[[:space:]]*cp -rf .*\|\| true' "${DEBNAS_ROOT}/install.sh"
  [[ "$output" == "0" ]]
}

@test "install.sh: 单文件运行 deploy_tree（不加载 lib），旧模块不残留、错误为 [FAIL] 格式" {
  local src="${WORK}/src" inst="${WORK}/opt/debnas"
  mkdir -p "$src/bin" "$src/lib" "$src/modules" "$inst/modules"
  echo new > "$src/bin/debnas"; echo old > "$inst/modules/gone.sh"
  run bash -c 'source "$1"; declare -F log_error >/dev/null && exit 9
    export DEBNAS_UPDATE_LOCK="$4/lock"; deploy_tree "$2" "$3"' _ "${DEBNAS_ROOT}/install.sh" "$src" "$inst" "$WORK"
  [[ "$status" -eq 0 && -f "$inst/bin/debnas" && ! -e "$inst/modules/gone.sh" ]]
  run bash -c 'source "$1"; deploy_tree "$2/nosuch" "$3"' _ "${DEBNAS_ROOT}/install.sh" "$WORK" "$inst"
  [[ "$status" -ne 0 && "$output" == "[FAIL] "* ]]
}

@test "install.sh: 非 TTY 未加 --yes 时覆盖安装/卸载以非 0 退出并提示 --yes" {
  run bash -c 'source "$1"; require_tty_or_yes "覆盖更新"; echo REACHED' _ "${DEBNAS_ROOT}/install.sh" < /dev/null
  [[ "$status" -ne 0 && "$output" != *REACHED* && "$output" == *"--yes"* ]]
  local f
  for f in check_existing_install do_uninstall; do
    sed -n "/^${f}()/,/^}/p" "${DEBNAS_ROOT}/install.sh" | grep -q 'require_tty_or_yes'
  done
  # 卸载在 read 之前检查（否则 EOF 被当作"取消"并以 0 退出）
  sed -n '/^do_uninstall()/,/^}/p' "${DEBNAS_ROOT}/install.sh" | awk '/require_tty_or_yes/ { t = NR } /read -rp/ { r = NR } END { exit !(t && r && t < r) }'
}

@test "install.sh: --uninstall 删除整个 /var/lib/debnas（与 debnas uninstall 一致）" {
  run bash -c 'source "$1"; echo "$DEBNAS_LIB_DIR"' _ "${DEBNAS_ROOT}/install.sh"
  [[ "$output" == "/var/lib/debnas" ]]
  sed -n '/^do_uninstall()/,/^}/p' "${DEBNAS_ROOT}/install.sh" | grep -q 'rm -rf "$DEBNAS_LIB_DIR"'
}

# 全局命令包装脚本（deploy_install_wrapper，同在 DEBNAS-DEPLOY 区块）的用例见 test-installer-compat.bats

# ==================== DEBNAS-DOWNLOAD 区块（下载与解压，install.sh 与 update 共用） ====================

_dlblock() {
  awk '/^# >>> DEBNAS-DOWNLOAD-BEGIN/ { p = 1 } p { print } /^# <<< DEBNAS-DOWNLOAD-END/ { p = 0 }' "$1"
}

@test "release-sync: 两份下载区块逐字一致、标记各恰好一个" {
  local a b f
  a=$(_dlblock "${DEBNAS_ROOT}/lib/system/installer.sh")
  b=$(_dlblock "${DEBNAS_ROOT}/install.sh")
  [[ "$a" == *"release_fetch()"* && "$a" == *"release_fetch_assets()"* && "$a" == *"release_extract()"* ]]
  [[ "$a" == "$b" ]]
  for f in "${DEBNAS_ROOT}/lib/system/installer.sh" "${DEBNAS_ROOT}/install.sh"; do
    [[ "$(grep -c '^# >>> DEBNAS-DOWNLOAD-BEGIN' "$f")" -eq 1 && "$(grep -c '^# <<< DEBNAS-DOWNLOAD-END' "$f")" -eq 1 ]]
  done
}

@test "release-sync: --sync-download 恢复被手改的下载区块" {
  local repo="${WORK}/repo"
  mkdir -p "${repo}/tools" "${repo}/lib/system"
  cp "${DEBNAS_ROOT}/install.sh" "${repo}/install.sh"
  cp "${DEBNAS_ROOT}/tools/release.sh" "${repo}/tools/release.sh"
  cp "${DEBNAS_ROOT}/lib/system/installer.sh" "${repo}/lib/system/installer.sh"
  sed -i 's/尝试备用源/被手改/' "${repo}/install.sh"
  run cmp -s <(_dlblock "${repo}/install.sh") <(_dlblock "${repo}/lib/system/installer.sh")
  [[ "$status" -ne 0 ]]
  run bash "${repo}/tools/release.sh" --sync-download
  [[ "$status" -eq 0 ]]
  cmp -s "${repo}/install.sh" "${DEBNAS_ROOT}/install.sh"
}

@test "install.sh: 下载与解压走 DEBNAS-DOWNLOAD 区块函数" {
  sed -n '/^download_release()/,/^}/p' "${DEBNAS_ROOT}/install.sh" | grep -q 'release_fetch_assets'
  sed -n '/^download_repo()/,/^}/p' "${DEBNAS_ROOT}/install.sh" | grep -q 'release_fetch '
  sed -n '/^extract_repo()/,/^}/p' "${DEBNAS_ROOT}/install.sh" | grep -q 'release_extract'
  run bash -c 'source "$1"; for f in release_fetch release_fetch_assets release_extract; do declare -F "$f" >/dev/null || { echo "缺少 $f"; exit 1; }; done; declare -F log_error >/dev/null && exit 2; echo OK' _ "${DEBNAS_ROOT}/install.sh"
  [[ "$status" -eq 0 && "$output" == *OK* ]]
}

@test "release-sync: 下载区块日志在 install.sh 下为 [FAIL]/[WARNING] 格式" {
  run bash -c 'source "$1"; _release_msg error "x"; _release_msg warn "y"' _ "${DEBNAS_ROOT}/install.sh"
  [[ "$output" == *"[FAIL] x"* && "$output" == *"[WARNING] y"* ]]
}
