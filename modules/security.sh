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

# 判断启用 su 限制是否安全（不会锁死 root 或当前管理员）
# 参数：$1 - /etc/pam.d/su 当前内容；返回：0 可以启用，1 应跳过（已输出原因）
su_restriction_safe_to_apply() {
  local current_content="$1"
  # pam_rootok 是 root 免密 su 的前提，规则必须插在它之后；找不到则不改，避免锁死 root
  if ! grep -qE '^[[:space:]]*auth[[:space:]].*pam_rootok\.so' <<< "$current_content"; then
    log_warning "/etc/pam.d/su 中未找到 pam_rootok 行（非标准配置），跳过 su 限制，请手动配置。"
    return 1
  fi

  # 防锁死：当前管理员必须在 sudo 组，否则启用后其将无法 su 到 root
  local admin_user="${SUDO_USER:-}"
  if [[ -z "$admin_user" || "$admin_user" == "root" ]]; then
    admin_user=$(logname 2>/dev/null) || admin_user=""
  fi
  if [[ -n "$admin_user" && "$admin_user" != "root" ]]; then
    local admin_groups
    admin_groups=$(id -nG "$admin_user" 2>/dev/null) || admin_groups=""
    if [[ " ${admin_groups} " != *" sudo "* ]]; then
      log_warning "当前管理员 ${admin_user} 不在 sudo 组，启用 su 限制后将无法 su 到 root，已跳过。"
      log_warning "请先执行 usermod -aG sudo ${admin_user} 后重新运行本模块。"
      return 1
    fi
  else
    local sudo_members
    sudo_members=$(getent group sudo 2>/dev/null | cut -d: -f4) || sudo_members=""
    if [[ -z "$sudo_members" ]]; then
      log_warning "sudo 组没有任何成员，启用 su 限制后普通用户将无法 su 到 root，已跳过。"
      return 1
    fi
  fi
  return 0
}

# 配置 su 权限限制，提升系统安全性
# 仅 sudo 组成员可 su 到 root；规则插在 pam_rootok 之后，保证 root 自身 su 不受影响
configure_su_restrictions() {
  log_info "配置 su 权限限制..."
  local current_content new_content
  current_content=$(cat /etc/pam.d/su 2>/dev/null) || current_content=""
  # 检测 PAM 文件是否已损坏（含 NUL 字节等非文本内容）
  if [[ -f /etc/pam.d/su ]] && grep -qP '\x00' /etc/pam.d/su 2>/dev/null; then
    log_error "/etc/pam.d/su 已损坏（含二进制内容），请手动修复"
    return 1
  fi
  # 只认未注释的 auth ... pam_wheel 行（Debian 默认自带被注释的示例行）
  if grep -qE '^[[:space:]]*auth[[:space:]].*pam_wheel\.so' <<< "$current_content"; then
    log_info "已配置 su 限制，跳过配置。"
    return 0
  fi
  su_restriction_safe_to_apply "$current_content" || return 0
  new_content=$(awk -v rule="auth       required   pam_wheel.so group=sudo use_uid" '
    { print } !done && /^[[:space:]]*auth[[:space:]].*pam_rootok\.so/ { print rule; done = 1 }' <<< "$current_content")
  if write_file_if_changed "/etc/pam.d/su" "$new_content"; then
    log_success "已添加 su 限制配置（仅 sudo 组成员可 su）。"
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

  # shellcheck disable=SC2016
  # 故意使用单引号：$(whoami)、${USER} 等变量不应在此处展开，
  # 而是写入 /etc/profile 后在用户登录时展开
  # 旧版 HISTDIR 片段：/var/log/history 为 1733，任何用户都能抢先建出别人（含 root）
  # 名字的目录并窃取其命令历史；新版只在目录为本人所有的真实目录时才使用
  local legacy_histdir_block new_histdir_block
  legacy_histdir_block='HISTDIR="/var/log/history/${LOGNAME}"
if [ ! -d "$HISTDIR" ]; then
    mkdir -m 300 -p "$HISTDIR"
    chown "$USER:$USER" "$HISTDIR"
fi
export HISTFILE="${HISTDIR}/${USER}@${USER_IP}_$(date +"%Y%m%d_%H:%M:%S")"'
  new_histdir_block='HISTDIR="/var/log/history/${USER}"
if [ ! -e "$HISTDIR" ] && [ ! -L "$HISTDIR" ]; then
    mkdir -m 300 "$HISTDIR" 2>/dev/null
fi
if [ -d "$HISTDIR" ] && [ ! -L "$HISTDIR" ] && [ "$(stat -c %u "$HISTDIR" 2>/dev/null)" = "$(id -u)" ]; then
    export HISTFILE="${HISTDIR}/${USER}@${USER_IP}_$(date +"%Y%m%d_%H:%M:%S")"
fi'

  if grep -qF "${debnas_marker}" <<< "$current_content"; then
    if [[ "$current_content" == *"$legacy_histdir_block"* ]]; then
      # 迁移旧版审计配置块中的不安全 HISTDIR 片段
      if write_file_if_changed "/etc/profile" "${current_content/"$legacy_histdir_block"/"$new_histdir_block"}"; then
        log_success "已升级命令记录日志目录的安全检查。"
      fi
      return 0
    fi
    log_info "已配置超时和命令记录日志，跳过配置。"
    return 0
  fi

  # 构建新的 /etc/profile 内容（原内容 + DebNAS 审计配置块）
  # shellcheck disable=SC2016
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
'"${new_histdir_block}"

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
