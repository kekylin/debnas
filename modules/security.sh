#!/bin/bash
# @module: security
# @name: 配置安全加固
# @category: 安全防护
# @depends:
# @version: 1.0.0
# @order: 40
# 功能：配置基础系统安全防护（su限制、超时登出、操作日志等）

set -euo pipefail
IFS=$'\n\t'

# 加载公共模块，确保依赖函数和常量可用
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/bootstrap.sh"

# 检查依赖，确保必备命令已安装
REQUIRED_CMDS=(sed grep systemctl mkdir chmod)
if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
  log_error "依赖缺失，请先安装必备命令：${REQUIRED_CMDS[*]}。"
  exit "${ERROR_DEPENDENCY}"
fi

# 配置 su 权限限制，提升系统安全性
configure_su_restrictions() {
  log_info "配置 su 权限限制..."
  local current_content
  current_content=$(cat /etc/pam.d/su 2>/dev/null) || current_content=""

  # 检测 PAM 文件是否已损坏（含 NUL 字节等非文本内容）
  if [[ -f /etc/pam.d/su ]] && grep -qP '\x00' /etc/pam.d/su 2>/dev/null; then
    log_error "/etc/pam.d/su 已损坏（含二进制内容），请手动修复"
    return 1
  fi

  if echo "$current_content" | grep -q "pam_wheel"; then
    log_info "已配置 su 限制，跳过配置。"
    return 0
  fi

  local new_content="auth required pam_wheel.so group=sudo
${current_content}"

  if write_file_if_changed "/etc/pam.d/su" "$new_content"; then
    log_success "已添加 su 限制配置。"
  else
    log_info "su 限制配置未变更。"
  fi
}

# 配置超时自动注销和命令历史记录，提升安全与审计能力
configure_timeout_and_logging() {
  log_info "配置超时自动登出和操作日志记录..."

  # 确保审计日志目录存在且权限正确
  mkdir -p /var/log/history
  local current_mode
  current_mode=$(stat -c "%a" /var/log/history 2>/dev/null) || current_mode=""
  if [[ "$current_mode" != "1733" ]]; then
    chmod 1733 /var/log/history
    chown root:root /var/log/history
    log_success "history 目录权限已配置"
  else
    log_info "/var/log/history 目录权限为 $current_mode，已满足要求。"
  fi

  # 读取当前 /etc/profile 内容，检查 DebNAS 审计配置块是否已存在
  local debnas_marker="# DebNAS 安全审计配置"
  local current_content
  current_content=$(cat /etc/profile 2>/dev/null) || current_content=""

  if echo "$current_content" | grep -qF "${debnas_marker}"; then
    log_info "已配置超时和命令记录日志，跳过配置。"
    return 0
  fi

  # 构建新的 /etc/profile 内容（原内容 + DebNAS 审计配置块）
  # shellcheck disable=SC2016
  # 故意使用单引号：$(whoami)、${LOGNAME} 等变量不应在此处展开，
  # 而是写入 /etc/profile 后在用户登录时展开
  local profile_addition
  profile_addition='
# DebNAS 安全审计配置
# 超时自动退出（15分钟）
TMOUT=900
# 在历史命令中启用人类可读时间戳
export HISTTIMEFORMAT="%Y-%m-%d %H:%M:%S "
# 记录所有用户的登录和操作日志
export HISTSIZE=4096
USER=$(whoami)
USER_IP=$(who -u am i 2>/dev/null | awk '\''{print $NF}'\'' | sed -e '\''s/[()]//g'\'')
if [ "$USER_IP" = "" ]; then
    USER_IP=$(hostname)
fi
HISTDIR="/var/log/history/${LOGNAME}"
if [ ! -d "$HISTDIR" ]; then
    mkdir -m 300 -p "$HISTDIR"
    chown "$USER:$USER" "$HISTDIR"
fi
export HISTFILE="${HISTDIR}/${USER}@${USER_IP}_$(date +"%Y%m%d_%H:%M:%S")"'

  local new_content="${current_content}${profile_addition}"

  if write_file_if_changed "/etc/profile" "$new_content"; then
    log_success "已添加超时和命令记录日志配置。"
  else
    log_info "超时和命令记录日志配置未变更。"
  fi
}

main() {
  log_info "配置系统安全..."
  configure_su_restrictions
  configure_timeout_and_logging
  log_success "安全加固 就绪"

  return 0
}

main "$@"
