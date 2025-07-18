#!/bin/bash
# 功能：配置基础系统安全防护（su限制、超时登出、操作日志等）

set -euo pipefail
IFS=$'\n\t'

# 加载公共模块，确保依赖函数和常量可用
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/core/constants.sh"
source "${SCRIPT_DIR}/lib/core/logging.sh"
source "${SCRIPT_DIR}/lib/system/dependency.sh"

# 检查依赖，确保必备命令已安装
REQUIRED_CMDS=(sed grep systemctl mkdir chmod)
if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
  log_error "依赖缺失，请先安装必备命令：${REQUIRED_CMDS[*]}。"
  exit "${ERROR_DEPENDENCY}"
fi

# 配置 su 权限限制，提升系统安全性
configure_su_restrictions() {
  log_info "配置 su 权限限制..."
  if grep -q "sudo" /etc/pam.d/su; then
    log_info "已配置 su 限制，跳过配置。"
  else
    sed -i '1i auth required pam_wheel.so group=sudo' /etc/pam.d/su
    log_success "已添加 su 限制配置。"
  fi
}

# 配置超时自动注销和命令历史记录，提升安全与审计能力
configure_timeout_and_logging() {
  log_info "配置超时自动登出和操作日志记录..."
  if [ ! -d /var/log/history ]; then
    mkdir -p /var/log/history
    chmod 1733 /var/log/history
    chown root:root /var/log/history
    log_success "已创建 /var/log/history 目录并设置权限为 1733（sticky bit，所有用户可写，防止互删）。"
  else
    current_mode=$(stat -c "%a" /var/log/history)
    if [ "$current_mode" -ne 1733 ]; then
      chmod 1733 /var/log/history
      chown root:root /var/log/history
      log_success "/var/log/history 目录权限已由 $current_mode 调整为 1733（sticky bit，所有用户可写，防止互删）。"
    else
      log_info "/var/log/history 目录权限为 $current_mode，已满足要求，无需调整。"
    fi
  fi
  if grep -q "TMOUT\|history" /etc/profile; then
    log_info "已配置超时和命令记录日志，跳过配置。"
  else
    cat << 'EOF' >> /etc/profile

# 超时自动退出（15分钟）
TMOUT=900
# 在历史命令中启用人类可读时间戳
export HISTTIMEFORMAT="%Y-%m-%d %H:%M:%S "
# 记录所有用户的登录和操作日志
export HISTSIZE=4096
USER=$(whoami)
USER_IP=$(who -u am i 2>/dev/null | awk '{print $NF}' | sed -e 's/[()]//g')
if [ "$USER_IP" = "" ]; then
    USER_IP=$(hostname)
fi
HISTDIR="/var/log/history/${LOGNAME}"
if [ ! -d "$HISTDIR" ]; then
    mkdir -m 300 -p "$HISTDIR"
    chown "$USER:$USER" "$HISTDIR"
fi
export HISTFILE="${HISTDIR}/${USER}@${USER_IP}_$(date +"%Y%m%d_%H:%M:%S")"
EOF
    log_success "已添加超时和命令记录日志配置。"
  fi
}

main() {
  log_info "开始配置系统安全防护..."
  configure_su_restrictions
  configure_timeout_and_logging
  log_success "系统安全防护配置完成。"
  return 0
}

main "$@"
