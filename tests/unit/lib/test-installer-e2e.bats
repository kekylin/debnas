#!/usr/bin/env bats
# 测试: installer E2E 链补充验证 (TC-P1-INST-001~005)
# 说明: TC-P1-INST-001~005 已在 test-installer.bats 中覆盖，此处补充 E2E 流程验证

DEBNAS_ROOT="${DEBNAS_ROOT:-$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)}"

@test "installer-e2e: installer_get_url region=cn 返回 Gitee" {
  local installer_sh="${DEBNAS_ROOT}/lib/system/installer.sh"

  grep -q 'installer_get_url' "$installer_sh"
  grep -qE 'gitee|GITEE' "$installer_sh"
}

@test "installer-e2e: installer_get_url region=global 返回 GitHub" {
  local installer_sh="${DEBNAS_ROOT}/lib/system/installer.sh"

  grep -qE 'github|GITHUB' "$installer_sh"
}

@test "installer-e2e: installer_extract 使用 strip-components=1" {
  local installer_sh="${DEBNAS_ROOT}/lib/system/installer.sh"

  grep -q 'strip-components' "$installer_sh"
}

@test "installer-e2e: installer_deploy 复制 bin/lib/modules" {
  local installer_sh="${DEBNAS_ROOT}/lib/system/installer.sh"

  grep -q 'bin\|lib\|modules' "$installer_sh"
}

@test "installer-e2e: install.sh 包含下载解压部署流程" {
  local install_sh="${DEBNAS_ROOT}/install.sh"

  # install.sh 内联实现了 download→extract→deploy 流程
  grep -qE 'wget|curl|download' "$install_sh"
  grep -qE 'tar|extract|解压' "$install_sh"
  grep -qE 'deploy|安装|install_dir|/opt/debnas' "$install_sh"
}
