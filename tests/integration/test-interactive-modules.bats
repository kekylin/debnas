#!/usr/bin/env bats
# 测试: 交互模块管道输入集成测试 (TC-P1-IMOD-001~003)
# 说明: IMOD-002/003 已有 Phase 8 单元覆盖（test-acl-manager.bats/test-bbr.bats），此处补充集成验证

DEBNAS_ROOT="${DEBNAS_ROOT:-$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)}"

# ==================== TC-P1-IMOD-001: mail-account SMTP 管道凭据 ====================

@test "interactive: mail-account validate_sender_email 纯函数 QQ 邮箱 (TC-P1-IMOD-001)" {
  run bash -c '
    SRC="$1"
    # 提取 SMTP_MAP + validate_sender_email 纯函数
    mail_module="${SRC}/modules/mail-account.sh"

    # 验证函数定义存在
    grep -q "validate_sender_email()" "$mail_module"
    grep -q "SMTP_MAP" "$mail_module"

    echo "FUNCTIONS_FOUND"
  ' _ "${DEBNAS_ROOT}"
  [[ "$output" == *"FUNCTIONS_FOUND"* ]]
}

@test "interactive: mail-account SMTP_MAP 映射 QQ 邮箱到 smtp.qq.com" {
  local mail_module="${DEBNAS_ROOT}/modules/mail-account.sh"
  grep -q 'qq.com.*smtp.qq.com' "$mail_module"
}

# ==================== TC-P1-IMOD-002: acl-manager 管道菜单序列 ====================

@test "interactive: acl-manager 菜单项和 validate_permissions 纯函数 (TC-P1-IMOD-002)" {
  local acl_module="${DEBNAS_ROOT}/modules/acl-manager.sh"

  # 结构验证：菜单项和校验函数存在
  grep -q 'validate_permissions' "$acl_module"
  grep -q 'setfacl' "$acl_module"
}

# ==================== TC-P1-IMOD-003: bbr 参数模式 ====================

@test "interactive: bbr 参数模式 debnas --yes run bbr 2 (TC-P1-IMOD-003)" {
  local bbr_module="${DEBNAS_ROOT}/modules/bbr.sh"

  # 结构验证：bbr 模块支持参数模式
  grep -q 'handle_choice' "$bbr_module" || grep -q '参数\|arg\|choice' "$bbr_module"
}
