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

# 必备命令（依赖检查在 main 中执行，保证只读探测时顶层无副作用）
REQUIRED_CMDS=(sed grep systemctl mkdir chmod)

# /etc/profile 中 DebNAS 审计配置块的标识（configure_* 与 module_status/plan 共用同一判据）
_SECURITY_PROFILE_MARKER="# DebNAS 安全审计配置"
# 旧版 HISTDIR 片段：/var/log/history 为 1733，任何用户都能抢先建出别人（含 root）
# 名字的目录并窃取其命令历史；整段匹配才会迁移为新版（只在目录为本人所有的真实目录时才使用）
# shellcheck disable=SC2016  # 变量写入 /etc/profile 后在用户登录时展开
_SECURITY_LEGACY_HISTDIR_SIG='HISTDIR="/var/log/history/${LOGNAME}"
if [ ! -d "$HISTDIR" ]; then
    mkdir -m 300 -p "$HISTDIR"
    chown "$USER:$USER" "$HISTDIR"
fi
export HISTFILE="${HISTDIR}/${USER}@${USER_IP}_$(date +"%Y%m%d_%H:%M:%S")"'

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
  local current_content
  current_content=$(cat /etc/profile 2>/dev/null) || current_content=""

  # shellcheck disable=SC2016
  # 故意使用单引号：$(whoami)、${USER} 等变量不应在此处展开，
  # 而是写入 /etc/profile 后在用户登录时展开
  local new_histdir_block
  new_histdir_block='HISTDIR="/var/log/history/${USER}"
if [ ! -e "$HISTDIR" ] && [ ! -L "$HISTDIR" ]; then
    mkdir -m 300 "$HISTDIR" 2>/dev/null
fi
if [ -d "$HISTDIR" ] && [ ! -L "$HISTDIR" ] && [ "$(stat -c %u "$HISTDIR" 2>/dev/null)" = "$(id -u)" ]; then
    export HISTFILE="${HISTDIR}/${USER}@${USER_IP}_$(date +"%Y%m%d_%H:%M:%S")"
fi'

  if [[ "$current_content" == *"$_SECURITY_PROFILE_MARKER"* ]]; then
    if [[ "$current_content" == *"$_SECURITY_LEGACY_HISTDIR_SIG"* ]]; then
      # 迁移旧版审计配置块中的不安全 HISTDIR 片段
      if write_file_if_changed "/etc/profile" "${current_content/"$_SECURITY_LEGACY_HISTDIR_SIG"/"$new_histdir_block"}"; then
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

# ==================== 只读探测契约（docs/ARCHITECTURE.md §4.5） ====================

# su 限制是否在 /etc/pam.d/su 中真正生效（未注释的 auth ... pam_wheel.so 行）
# 返回：0 生效，1 未生效，2 无法读取
_security_su_state() {
  [[ -r /etc/pam.d/su ]] || return 2
  grep -qE '^[[:space:]]*auth[[:space:]].*pam_wheel\.so' /etc/pam.d/su 2>/dev/null && return 0
  return 1
}

# 当前状态：一行 "状态码|说明"
module_status() {
  local -a done_items=() todo_items=()
  local su_rc=0 profile="" mode=""

  _security_su_state || su_rc=$?
  case "$su_rc" in
    0) done_items+=("su 限制") ;;
    1) todo_items+=("su 限制") ;;
    *) todo_items+=("su 限制(需 root 查看)") ;;
  esac

  if [[ -r /etc/profile ]]; then
    profile=$(cat /etc/profile 2>/dev/null) || profile=""
    if [[ "$profile" == *"$_SECURITY_PROFILE_MARKER"* ]]; then
      if [[ "$profile" == *"$_SECURITY_LEGACY_HISTDIR_SIG"* ]]; then
        todo_items+=("审计配置为旧版(HISTDIR 待升级)")
      else
        done_items+=("超时登出/命令审计")
      fi
    else
      todo_items+=("超时登出/命令审计")
    fi
  else
    todo_items+=("/etc/profile(需 root 查看)")
  fi

  mode=$(stat -c '%a' /var/log/history 2>/dev/null) || mode=""
  if [[ "$mode" == "1733" ]]; then
    done_items+=("history 目录")
  else
    todo_items+=("history 目录${mode:+(权限 ${mode})}")
  fi

  # 多字节分隔符不放进 IFS（非 UTF-8 locale 下只取首字节），手工拼接
  local done_str="" todo_str="" item
  for item in "${done_items[@]}"; do done_str+="${done_str:+、}${item}"; done
  for item in "${todo_items[@]}"; do todo_str+="${todo_str:+、}${item}"; done
  if [[ ${#todo_items[@]} -eq 0 ]]; then
    echo "applied|已生效：${done_str}"
  elif [[ ${#done_items[@]} -eq 0 ]]; then
    if [[ "$su_rc" -eq 2 ]]; then
      echo "unknown|未检测到加固配置（部分文件需 root 查看）"
    else
      echo "absent|未配置 su 限制/超时登出/命令审计"
    fi
  else
    echo "partial|已生效：${done_str}；待处理：${todo_str}"
  fi
}

# 预演：每行 "类型|目标|备注"（无副作用；与 main 的判断保持一致）
module_plan() {
  local IFS=$' \n\t'
  local su_rc=0 su_content="" profile="" mode=""

  _security_su_state || su_rc=$?
  if [[ "$su_rc" -eq 0 ]]; then
    echo "info|/etc/pam.d/su|su 限制已生效（已满足）"
  elif [[ "$su_rc" -eq 2 ]]; then
    echo "write|/etc/pam.d/su|当前无权读取；未配置时在 pam_rootok 之后插入 pam_wheel.so group=sudo；旧文件备份到 /var/backups/debnas/"
    echo "risk|su 限制|启用后仅 sudo 组成员可 su 到 root；当前管理员不在 sudo 组时自动跳过"
  else
    su_content=$(cat /etc/pam.d/su 2>/dev/null) || su_content=""
    if ! grep -qE '^[[:space:]]*auth[[:space:]].*pam_rootok\.so' <<< "$su_content"; then
      echo "risk|/etc/pam.d/su|未找到 pam_rootok 行（非标准配置），将跳过 su 限制，需手动配置"
    elif su_restriction_safe_to_apply "$su_content" >/dev/null 2>&1; then
      echo "write|/etc/pam.d/su|在 pam_rootok 之后插入 pam_wheel.so group=sudo use_uid；旧文件备份到 /var/backups/debnas/"
      echo "risk|su 限制|启用后仅 sudo 组成员可 su 到 root（root 自身不受影响）"
    else
      echo "risk|su 限制|当前管理员不在 sudo 组（或 sudo 组无成员），将跳过 su 限制以防锁死"
    fi
  fi

  mode=$(stat -c '%a' /var/log/history 2>/dev/null) || mode=""
  if [[ "$mode" == "1733" ]]; then
    echo "info|/var/log/history|目录权限 1733（已满足）"
  else
    echo "write|/var/log/history|${mode:+现权限 ${mode}，}创建目录并设为 1733 root:root（命令审计日志目录）"
  fi

  if [[ ! -r /etc/profile ]]; then
    echo "write|/etc/profile|当前无权读取；未配置时追加 DebNAS 审计配置块；旧文件备份到 /var/backups/debnas/"
    echo "risk|TMOUT=900|所有登录 shell 空闲 15 分钟自动退出（下次登录生效）"
    return 0
  fi
  profile=$(cat /etc/profile 2>/dev/null) || profile=""
  if [[ "$profile" == *"$_SECURITY_PROFILE_MARKER"* ]]; then
    if [[ "$profile" == *"$_SECURITY_LEGACY_HISTDIR_SIG"* ]]; then
      echo "write|/etc/profile|升级旧版 HISTDIR 片段（防抢建他人历史目录）；旧文件备份到 /var/backups/debnas/"
    else
      echo "info|/etc/profile|超时登出与命令审计已配置（已满足）"
    fi
  else
    echo "write|/etc/profile|追加 DebNAS 审计配置块（TMOUT/HISTTIMEFORMAT/HISTFILE）；旧文件备份到 /var/backups/debnas/"
    echo "risk|TMOUT=900|所有登录 shell 空闲 15 分钟自动退出（下次登录生效）"
  fi
  return 0
}

main() {
  check_dependencies "${REQUIRED_CMDS[@]}" || { log_error "依赖缺失，请先安装必备命令：${REQUIRED_CMDS[*]}。"; exit "${ERROR_DEPENDENCY}"; }
  log_info "配置系统安全..."
  configure_su_restrictions
  configure_timeout_and_logging
  log_success "安全加固 就绪"
}

# 契约守卫：DEBNAS_MODULE_ACTION=status|plan 时只加载函数供只读探测，不执行 main（docs/ARCHITECTURE.md §4.5）
if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi
