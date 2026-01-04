#!/bin/bash
# 功能：安装必备软件包（如 curl、wget、sudo 等）

set -euo pipefail
IFS=$'\n\t'

# 加载公共模块，确保依赖函数和常量可用
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/core/constants.sh"
source "${SCRIPT_DIR}/lib/core/logging.sh"
source "${SCRIPT_DIR}/lib/system/dependency.sh"
source "${SCRIPT_DIR}/lib/system/utils.sh"

# 检查 apt、awk 依赖，确保后续操作可用
REQUIRED_CMDS=(apt awk)
if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
  log_fail "缺少 apt 或 awk，请先手动安装。"
  exit "${ERROR_DEPENDENCY}"
fi

# 检查系统兼容性，防止在不支持的平台运行
if ! verify_system_support; then
  exit "${ERROR_UNSUPPORTED_OS}"
fi

# 安装基础软件包，分两步：先解决依赖，再配置权限
log_action "正在安装基础软件包..."

# 更新软件源，确保获取最新包信息
if apt update; then
  log_success "软件源更新成功。"
else
  log_fail "软件源更新失败。"
  exit "${ERROR_GENERAL}"
fi

# 安装常用必备软件，保障系统基础功能
if apt install -y sudo curl git vim wget exim4 gnupg apt-transport-https ca-certificates udisks2-lvm2 smartmontools; then
  log_success "必备软件包安装完成。"
else
  log_fail "必备软件包安装失败。"
  exit "${ERROR_GENERAL}"
fi

# 自动将首个普通用户（UID>=1000，排除 nobody）加入 sudo 组，便于后续管理
first_user=$(awk -F: '$3>=1000 && $1 != "nobody" {print $1}' /etc/passwd | sort | head -n 1)

if [[ -n "${first_user:-}" ]]; then
  # 验证用户是否真实存在
  if id "$first_user" &>/dev/null; then
    # 检查用户是否已在 sudo 组中
    if id -nG "$first_user" 2>/dev/null | grep -qw "sudo"; then
      log_info "用户 $first_user 已在 sudo 组中，跳过操作。"
    elif usermod -aG sudo "$first_user" 2>/dev/null; then
      log_success "用户 $first_user 已加入 sudo 组。"
    else
      log_warning "添加用户 $first_user 到 sudo 组失败，跳过操作。"
    fi
  else
    log_warning "检测到的用户 $first_user 不存在，跳过 sudo 组配置。"
  fi
else
  log_info "未找到符合条件的普通用户，跳过 sudo 组配置。"
fi
