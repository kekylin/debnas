#!/bin/bash
# 功能：配置基础系统安全防护（如SSH加固、禁用root远程、自动登出等）
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

# 检查依赖
REQUIRED_CMDS=(sed grep systemctl)
if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
  log_error "依赖缺失，请先安装必备命令：${REQUIRED_CMDS[*]}"
  exit "${ERROR_DEPENDENCY}"
fi

# 禁用root远程登录
if grep -q '^PermitRootLogin' /etc/ssh/sshd_config; then
  sed -i 's/^PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
else
  echo 'PermitRootLogin no' >> /etc/ssh/sshd_config
fi
log_success "已禁用root远程登录"

# 设置SSH空闲超时自动登出（10分钟）
if grep -q '^ClientAliveInterval' /etc/ssh/sshd_config; then
  sed -i 's/^ClientAliveInterval.*/ClientAliveInterval 600/' /etc/ssh/sshd_config
else
  echo 'ClientAliveInterval 600' >> /etc/ssh/sshd_config
fi
if grep -q '^ClientAliveCountMax' /etc/ssh/sshd_config; then
  sed -i 's/^ClientAliveCountMax.*/ClientAliveCountMax 1/' /etc/ssh/sshd_config
else
  echo 'ClientAliveCountMax 1' >> /etc/ssh/sshd_config
fi
log_success "已设置SSH空闲超时自动登出"

# 重启SSH服务
if systemctl restart ssh || systemctl restart sshd; then
  log_success "SSH服务已重启，安全配置生效"
else
  log_error "SSH服务重启失败，请手动检查配置"
  exit "${ERROR_GENERAL}"
fi

# 可选优化建议：
# 1. 支持自定义超时时间和安全策略
# 2. 检查并提示防火墙状态
