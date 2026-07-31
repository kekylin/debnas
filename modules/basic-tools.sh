#!/bin/bash
# @module: basic-tools
# @name: 基础工具包
# @category: 基础系统
# @depends:
# @version: 1.0.0
# @order: 11
# 功能：安装必备软件包（如 curl、wget、sudo 等）

set -euo pipefail
IFS=$'\n\t'

# 加载公共模块，确保依赖函数和常量可用
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/bootstrap.sh"
main() {
source "${SCRIPT_DIR}/lib/system/state.sh"

# 检查 apt、awk 依赖，确保后续操作可用
REQUIRED_CMDS=(apt awk)
if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
  log_error "缺少 apt 或 awk，请先手动安装。"
  exit "${ERROR_DEPENDENCY}"
fi

# 检查系统兼容性，防止在不支持的平台运行# 安装基础软件包（智能过滤已装包 + apt update 去重 + 锁等待）
log_info "安装基础工具包..."

if apt_install_packages sudo curl git vim wget exim4 gnupg apt-transport-https ca-certificates udisks2-lvm2 smartmontools; then
  log_success "基础工具包 就绪"
else
  log_error "基础工具包 安装失败"
  exit "${ERROR_GENERAL}"
fi

# 自动将首个普通用户（UID>=1000，排除 nobody）加入 sudo 组，便于后续管理
first_user=$(get_first_regular_user)

if [[ -n "${first_user:-}" ]]; then
  # 验证用户是否真实存在
  if id "$first_user" &>/dev/null; then
    # 检查用户是否已在 sudo 组中
    if id -nG "$first_user" 2>/dev/null | grep -qw "sudo"; then
      log_info "$first_user 已在 sudo 组"
    elif usermod -aG sudo "$first_user" 2>/dev/null; then
      log_info "$first_user → sudo 组"
    else
      log_warning "$first_user sudo 组添加失败"
    fi
  else
    log_warning "$first_user 不存在，跳过 sudo 组"
  fi
else
  log_warning "无普通用户，跳过 sudo 组"
fi


}

main "$@"
