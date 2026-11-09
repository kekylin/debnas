#!/bin/bash
# @module: basic-tools
# @name: 安装基础工具
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

# 基础工具包清单（main 安装与只读探测共用）
BASIC_TOOLS_PACKAGES=(sudo curl git vim wget exim4 gnupg apt-transport-https ca-certificates udisks2-lvm2 smartmontools)

# ==================== 只读探测契约（docs/ARCHITECTURE.md §4.5） ====================

# 列出清单中未安装的包（一次 dpkg-query，只读）
_basic_tools_missing() {
  local IFS=$' \n\t'
  local installed pkg
  installed=$(dpkg-query -W -f='${Package} ${db:Status-Status}\n' "${BASIC_TOOLS_PACKAGES[@]}" 2>/dev/null \
    | awk '$2 == "installed" { print $1 }') || true
  for pkg in "${BASIC_TOOLS_PACKAGES[@]}"; do
    grep -qxF -- "$pkg" <<< "$installed" || printf '%s\n' "$pkg"
  done
}

# 当前状态：一行 "状态码|说明"
module_status() {
  local IFS=$' \n\t'
  local total=${#BASIC_TOOLS_PACKAGES[@]} missing_list
  local -a missing=()
  missing_list=$(_basic_tools_missing)
  [[ -n "$missing_list" ]] && mapfile -t missing <<< "$missing_list"
  local have=$(( total - ${#missing[@]} ))
  if [[ ${#missing[@]} -eq 0 ]]; then
    echo "applied|${total}/${total} 个基础工具已安装"
  elif [[ $have -eq 0 ]]; then
    echo "absent|0/${total} 个基础工具已安装"
  else
    echo "partial|已装 ${have}/${total}，缺 ${missing[*]}"
  fi
}

# 预演：每行 "类型|目标|备注"
module_plan() {
  local IFS=$' \n\t'
  local missing_list first_user add_sudo
  local -a missing=()
  missing_list=$(_basic_tools_missing)
  [[ -n "$missing_list" ]] && mapfile -t missing <<< "$missing_list"
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "pkg|${missing[*]}|apt 安装（先 apt update）"
    if printf '%s\n' "${missing[@]}" | grep -qx 'exim4'; then
      echo "info|exim4|安装本地邮件传输代理（默认仅本机投递）"
    fi
  else
    echo "info|基础工具|${#BASIC_TOOLS_PACKAGES[@]} 个包均已安装，跳过安装"
  fi

  first_user=$(get_first_regular_user 2>/dev/null) || first_user=""
  add_sudo=$(config_read "global" "add_user_to_sudo" "1" 2>/dev/null) || add_sudo="1"
  if [[ "$add_sudo" == "0" ]]; then
    echo "info|sudo 组|已配置 add_user_to_sudo=0，不改动用户组"
  elif [[ -z "$first_user" ]]; then
    echo "info|sudo 组|无普通用户（UID>=1000），跳过"
  elif id -nG "$first_user" 2>/dev/null | grep -qw "sudo"; then
    echo "info|${first_user}|已在 sudo 组"
  else
    echo "user|${first_user}|加入 sudo 组（usermod -aG sudo）"
    echo "risk|sudo 组|${first_user} 可经 sudo 获得完整 root 权限（可在 /etc/debnas/debnas.conf 设 add_user_to_sudo=0 关闭）"
  fi
  return 0
}

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

if apt_install_packages "${BASIC_TOOLS_PACKAGES[@]}"; then
  log_success "基础工具包 就绪"
else
  log_error "基础工具包 安装失败"
  exit "${ERROR_GENERAL}"
fi

# 自动将首个普通用户（UID>=1000，排除 nobody）加入 sudo 组，便于后续管理
# 安全提示：sudo 组成员可通过 sudo 获得完整 root 权限。
# 可在 /etc/debnas/debnas.conf 设置 add_user_to_sudo=0 关闭此行为（默认 1，保持原有用法）
first_user=$(get_first_regular_user)
add_sudo=$(config_read "global" "add_user_to_sudo" "1" 2>/dev/null || echo "1")

if [[ "${add_sudo}" == "0" ]]; then
  log_info "已配置 add_user_to_sudo=0，跳过 sudo 组"
elif [[ -n "${first_user:-}" ]]; then
  # 验证用户是否真实存在
  if id "$first_user" &>/dev/null; then
    # 检查用户是否已在 sudo 组中
    if id -nG "$first_user" 2>/dev/null | grep -qw "sudo"; then
      log_info "$first_user 已在 sudo 组"
    elif usermod -aG sudo "$first_user" 2>/dev/null; then
      log_warning "已将用户 $first_user 加入 sudo 组（该用户可通过 sudo 获得完整 root 权限）"
      log_warning "如不需要请执行：gpasswd -d $first_user sudo；并在 /etc/debnas/debnas.conf 设置 add_user_to_sudo=0"
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

# 契约守卫：DEBNAS_MODULE_ACTION=status|plan 时只加载函数供只读探测，不执行 main（docs/ARCHITECTURE.md §4.5）
if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi
