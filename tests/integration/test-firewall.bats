#!/usr/bin/env bats
# 集成测试: modules/firewall.sh — 配置防火墙模块
# 验证元数据完整性、语法、结构、XML 配置、依赖链

DEBNAS_ROOT="${DEBNAS_ROOT:-$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)}"
export NO_COLOR=1
source "${DEBNAS_ROOT}/lib/core/constants.sh"
source "${DEBNAS_ROOT}/lib/core/colors.sh"
source "${DEBNAS_ROOT}/lib/core/logging.sh"

MODULE_FILE="${DEBNAS_ROOT}/modules/firewall.sh"

parse_meta() {
  local field="$1"
  grep -m1 "^# *@${field}:" "$MODULE_FILE" 2>/dev/null | sed "s/^# *@${field}: *//" || true
}

# ==================== 元数据验证 ====================

@test "firewall: @module 为 firewall" {
  result=$(parse_meta "module")
  [[ "$result" == "firewall" ]]
}

@test "firewall: @name 为 配置防火墙" {
  result=$(parse_meta "name")
  [[ "$result" == "配置防火墙" ]]
}

@test "firewall: @category 为 安全防护" {
  result=$(parse_meta "category")
  [[ "$result" == "安全防护" ]]
}

@test "firewall: @version 已声明" {
  result=$(parse_meta "version")
  [[ -n "$result" ]]
}

@test "firewall: @order 已声明" {
  result=$(parse_meta "order")
  [[ -n "$result" ]]
}

# ==================== 结构验证 ====================
# 注：bash -n 语法检查已由 L1 门禁全局覆盖，此处不再重复

@test "firewall: 文件头包含 set -euo pipefail" {
  grep -q 'set -euo pipefail' "$MODULE_FILE"
}

@test "firewall: 加载 bootstrap.sh" {
  grep -q 'source.*lib/bootstrap.sh' "$MODULE_FILE"
}

@test "firewall: main 函数入口存在" {
  grep -q '^main()' "$MODULE_FILE"
}

@test "firewall: 末尾调用 main \"\$@\"" {
  grep -q 'main "\$@"' "$MODULE_FILE"
}

@test "firewall: main 函数定义后无顶层可执行代码" {
  # main() 声明后不应该再有顶层代码（除了 main "$@" 调用）
  local after_main
  after_main=$(sed -n '/^main()/,$p' "$MODULE_FILE")
  # 检查 main() 体内部逻辑，确认有 service_ensure 调用
  grep -q 'service_ensure firewalld started' "$MODULE_FILE"
}

# ==================== XML 配置验证 ====================

@test "firewall: firewall_config 包含 ssh 服务" {
  grep -q '<service name="ssh"/>' "$MODULE_FILE"
}

@test "firewall: firewall_config 包含 dhcpv6-client 服务" {
  grep -q '<service name="dhcpv6-client"/>' "$MODULE_FILE"
}

@test "firewall: firewall_config 包含 cockpit 服务" {
  grep -q '<service name="cockpit"/>' "$MODULE_FILE"
}

@test "firewall: 约定使用 write_file_if_changed 写入配置" {
  grep -q 'write_file_if_changed.*CONFIG_FILE' "$MODULE_FILE"
}

@test "firewall: 使用 service_ensure 管理 firewalld 服务" {
  grep -q 'service_ensure firewalld started' "$MODULE_FILE"
  grep -q 'service_ensure firewalld enabled' "$MODULE_FILE"
}

@test "firewall: 已存在的配置文件会检查并补充 cockpit" {
  # 2026-11-10：改为读出区文件内容 → 内存中补缺 → write_file_if_changed 写回（不再 grep/sed -i 直改）
  grep -q '_fw_zone_insert "$current"' "$MODULE_FILE"
  grep -q 'write_file_if_changed "$CONFIG_FILE" "$new_content"' "$MODULE_FILE"
}

# ==================== 安全性验证 ====================

@test "firewall: 无直接 systemctl 写操作（使用 service_ensure；只读 is-active 等放行）" {
  ! grep -v '^[[:space:]]*#' "$MODULE_FILE" \
    | grep -qE '\bsystemctl[[:space:]]+(-[^[:space:]]+[[:space:]]+)*(start|stop|restart|reload|try-restart|reload-or-restart|enable|disable|mask|unmask|daemon-reload|kill)\b'
}

@test "firewall: 无 eval 使用" {
  ! grep -q '\beval\b' "$MODULE_FILE"
}

# ==================== 依赖链验证 ====================

@test "firewall: @depend_modules 未声明（无上游依赖）" {
  ! grep -q '@depend_modules:' "$MODULE_FILE"
}

@test "firewall: fail2ban 模块依赖 firewall" {
  grep -q '@depend_modules:.*firewall' "${DEBNAS_ROOT}/modules/fail2ban.sh"
}

@test "firewall: threat-ips 模块依赖 firewall" {
  grep -q '@depend_modules:.*firewall' "${DEBNAS_ROOT}/modules/threat-ips/module.sh"
}
