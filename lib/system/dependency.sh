#!/bin/bash
# 功能：依赖检测与自动/手动安装模块

set -euo pipefail
IFS=$'\n\t'

# 依赖: core/logging.sh（由 bootstrap-core.sh 加载）

# 命令到包名映射表
# 空字符串表示系统自带命令，无需安装
declare -A cmd_to_pkg=(
  ["grep"]=""
  ["awk"]="gawk"
  ["sed"]=""
  ["curl"]="curl"
  ["wget"]="wget"
  ["apt"]="apt"
  ["bash"]=""
  ["systemctl"]=""
  ["hostname"]=""
  ["dpkg"]=""
  ["cp"]=""
  ["mv"]=""
  ["mkdir"]=""
  ["chmod"]=""
  ["cat"]=""
  ["cut"]=""
  ["head"]=""
  ["tail"]=""
  ["sort"]=""
  ["tr"]=""
  ["wc"]=""
  ["date"]=""
  ["docker"]="docker.io"
  ["tar"]=""
  ["rsync"]="rsync"
  ["msmtp"]="msmtp"
  ["mail"]="mailutils"
  ["firewall-cmd"]="firewalld"
  ["exim4"]="exim4-daemon-light"
  ["update-exim4.conf"]="exim4-config"
  ["sysctl"]=""
  ["dig"]="dnsutils"
  ["ping"]="iputils-ping"
  ["sipcalc"]="sipcalc"
  ["getfacl"]="acl"
  ["setfacl"]="acl"
  ["nmcli"]="network-manager"
  # 可根据需要扩展
)

# 检查依赖命令是否存在
check_dependencies() {
  # 参数：命令列表
  for cmd in "$@"; do
    command -v "$cmd" &>/dev/null || return 1
  done
  return 0
}

# 检查主软件源是否已配置（只认 /etc/apt/sources.list 和 /etc/apt/sources.list.d/debian.sources）
has_valid_main_apt_source() {
  # 检查 /etc/apt/sources.list
  if grep -E '^[[:space:]]*deb[[:space:]]+' /etc/apt/sources.list 2>/dev/null | grep -vqE '^[[:space:]]*#'; then
    return 0
  fi
  # 检查新版主源 /etc/apt/sources.list.d/debian.sources
  if [ -f /etc/apt/sources.list.d/debian.sources ]; then
    if grep -E '^[[:space:]]*Types:[[:space:]]*deb' /etc/apt/sources.list.d/debian.sources 2>/dev/null | grep -vqE '^[[:space:]]*#'; then
      return 0
    fi
  fi
  return 1
}

# 自动安装缺失依赖（需 root 权限，主源未配置时不自动安装）
install_missing_dependencies() {
  local missing_cmds=()
  for cmd in "$@"; do
    if ! command -v "$cmd" &>/dev/null; then
      missing_cmds+=("$cmd")
    fi
  done
  if [[ ${#missing_cmds[@]} -eq 0 ]]; then
    log_info "所有依赖命令均已安装"
    return 0
  fi
  log_warning "发现缺失的依赖命令：${missing_cmds[*]}"

  # 过滤掉系统自带命令（映射值为空的命令）
  local installable_cmds=()
  for cmd in "${missing_cmds[@]}"; do
    local pkg_name=""
    if [[ -v "cmd_to_pkg[$cmd]" ]]; then
      pkg_name="${cmd_to_pkg[$cmd]}"
    fi
    if [[ -n "$pkg_name" ]]; then
      installable_cmds+=("$cmd")
    else
      log_debug "跳过系统命令 $cmd（无需安装）"
    fi
  done

  if [[ ${#installable_cmds[@]} -eq 0 ]]; then
    log_debug "所有缺失命令均为系统自带，无需安装"
    return 0
  fi

  if ! has_valid_main_apt_source; then
    log_warning "未检测到有效主软件源，跳过自动安装（模块将自行处理）"
    return 1
  fi

  # apt update 只执行一次
  log_info "更新索引..."
  if ! DEBIAN_FRONTEND=noninteractive apt update -qq 2>/dev/null; then
    log_error "apt update 失败，跳过自动安装"
    return 1
  fi

  for cmd in "${installable_cmds[@]}"; do
    local pkg_name=""
    if [[ -v "cmd_to_pkg[$cmd]" ]]; then
      pkg_name="${cmd_to_pkg[$cmd]}"
    fi
    if [[ -n "$pkg_name" ]]; then
      log_debug "尝试安装 $cmd 对应的包：$pkg_name"
      if DEBIAN_FRONTEND=noninteractive apt install -y -qq "$pkg_name" 2>/dev/null; then
        log_success "${cmd} 就绪"
      else
        log_error "${cmd} 安装失败"
      fi
    fi
  done
}

# 确保命令可用（检测 + 自动安装一体化）
# 参数：$1 - 命令名
#       $2 - 包名（可选，默认从 cmd_to_pkg 映射获取）
# 返回：0 命令可用，1 不可用
ensure_command() {
  local cmd="${1:?ensure_command: 缺少命令名}"
  local pkg="${2:-}"

  # 如果未指定包名，从映射表查找
  if [[ -z "$pkg" ]]; then
    if [[ -v "cmd_to_pkg[$cmd]" ]]; then
      pkg="${cmd_to_pkg[$cmd]}"
    else
      pkg="$cmd"
    fi
  fi

  if command -v "$cmd" &>/dev/null; then
    return 0
  fi

  if [[ -z "$pkg" ]]; then
    log_debug "跳过系统命令 $cmd（无需安装）"
    return 0
  fi

  apt_update_safe
  DEBIAN_FRONTEND=noninteractive apt install -y -qq "$pkg" 2>/dev/null
}

# 列出缺失依赖并给出手动安装建议（主源未配置时高亮提示）
list_missing_dependencies() {
  local missing_cmds=()
  for cmd in "$@"; do
    if ! command -v "$cmd" &>/dev/null; then
      missing_cmds+=("$cmd")
    fi
  done
  if [[ ${#missing_cmds[@]} -eq 0 ]]; then
    log_info "所有依赖命令均已安装"
    return 0
  fi
  log_warning "以下依赖命令缺失："
  for cmd in "${missing_cmds[@]}"; do
    echo "- $cmd"
  done
  if ! has_valid_main_apt_source; then
    log_error "未检测到有效主软件源（/etc/apt/sources.list 或 /etc/apt/sources.list.d/debian.sources），请先配置软件源后再安装依赖。"
    return 1
  fi
  log_info "请使用以下命令安装缺失的依赖："
  for cmd in "${missing_cmds[@]}"; do
    # 安全访问关联数组，兼容 set -u
    local pkg_name=""
    if [[ -v "cmd_to_pkg[$cmd]" ]]; then
      pkg_name="${cmd_to_pkg[$cmd]}"
    fi
    if [[ -n "$pkg_name" ]]; then
      echo "apt install $pkg_name"
    else
      echo "# 无法确定 $cmd 的包名，请手动查找并安装"
    fi
  done
}
