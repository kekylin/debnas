#!/bin/bash
# 功能：安装必备软件包（如curl、wget、sudo等）
# 参数：无（可根据需要扩展）
# 返回值：0成功，非0失败
# 作者：kekylin
# 创建时间：2025-07-11
# 修改时间：2025-07-12

set -euo pipefail
IFS=$'\n\t'

# 加载公共模块
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/core/constants.sh"
source "${SCRIPT_DIR}/lib/core/logging.sh"
source "${SCRIPT_DIR}/lib/system/dependency.sh"
source "${SCRIPT_DIR}/lib/system/utils.sh"

# 检查依赖
REQUIRED_CMDS=(apt awk)
if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
  log_fail "依赖缺失，请先安装 apt 和 awk"
  exit "${ERROR_DEPENDENCY}"
fi

# 检查系统兼容性
if ! verify_system_support; then
  exit "${ERROR_UNSUPPORTED_OS}"
fi

# 检查磁盘空间（至少需要 2GB）
if ! check_disk_space "/" 2; then
  log_warning "磁盘空间不足，可能影响软件安装"
fi

# 安装基础软件包（第一部分：解决依赖问题）
log_action "开始安装基础软件包..."

# 更新软件源
if apt update; then
  log_success "软件源更新成功"
else
  log_fail "软件源更新失败"
  exit "${ERROR_GENERAL}"
fi

# 安装必备软件
if apt install -y sudo curl git vim wget exim4 gnupg apt-transport-https ca-certificates smartmontools; then
  log_success "必备软件包安装完成"
else
  log_fail "必备软件包安装失败"
  exit "${ERROR_GENERAL}"
fi

# 添加第一个创建的用户（ID>=1000）至sudo组（第二部分：解决权限问题）
first_user=$(awk -F: '$3>=1000 && $1 != "nobody" {print $1}' /etc/passwd | sort | head -n 1)

if [ -n "$first_user" ]; then
  if usermod -aG sudo "$first_user"; then
    log_success "用户 $first_user 已添加到 sudo 组"
  else
    log_warning "添加用户 $first_user 到 sudo 组失败"
  fi
else
  log_warning "未找到符合条件的用户，跳过 sudo 组配置"
fi

log_success "所有必备软件包和权限配置已全部完成。"
