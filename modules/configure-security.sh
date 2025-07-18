#!/bin/bash
# 功能：配置基础系统安全防护（su限制、超时登出、操作日志等）
# 参数：无（可根据需要扩展）
# 返回值：0成功，非0失败
# 作者：kekylin
# 创建时间：2025-07-11
# 修改时间：2025-07-18

set -euo pipefail
IFS=$'\n\t'

# 加载公共模块
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/core/constants.sh"
source "${SCRIPT_DIR}/lib/core/logging.sh"
source "${SCRIPT_DIR}/lib/system/dependency.sh"

# 检查依赖
REQUIRED_CMDS=(sed grep systemctl mkdir chmod)
if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
  log_error "依赖缺失，请先安装必备命令：${REQUIRED_CMDS[*]}"
  exit "${ERROR_DEPENDENCY}"
fi

# 1. 限制能su到root的用户
configure_su_restrictions() {
  log_info "配置su权限限制..."
  
  # 检查是否已经配置了对应的参数
  if grep -q "sudo" /etc/pam.d/su; then
    log_info "已配置su限制，跳过配置"
  else
    # 在文件首行插入内容
    sed -i '1i auth required pam_wheel.so group=sudo' /etc/pam.d/su
    log_success "已添加su限制配置"
  fi
}

# 2. 超时自动注销和记录所有用户的登录和操作日志
configure_timeout_and_logging() {
  log_info "配置超时自动登出和操作日志记录..."

  # 主动创建历史目录根目录，避免普通用户报错
  if [ ! -d /var/log/history ]; then
    mkdir -p /var/log/history
    chmod 700 /var/log/history
    chown root:root /var/log/history
    log_success "已创建 /var/log/history 目录并设置权限为700"
  fi

  # 检查是否已经配置了对应的参数
  if grep -q "TMOUT\|history" /etc/profile; then
    log_info "已配置超时和命令记录日志，跳过配置"
  else
    # 追加内容到文件末尾（自动为每个用户创建独立目录）
    cat << 'EOF' >> /etc/profile

# 超时自动退出（15分钟）
TMOUT=900
# 在历史命令中启用时间戳
export HISTTIMEFORMAT="%F %T "
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
    log_success "已添加超时和命令记录日志配置"
  fi
}



# 主程序入口
main() {
  log_info "开始配置系统安全防护..."
  
  # 配置su权限限制
  configure_su_restrictions
  
  # 配置超时和日志记录
  configure_timeout_and_logging
  
  log_success "系统安全防护配置完成"
  return 0
}

# 调用主函数
main "$@"
