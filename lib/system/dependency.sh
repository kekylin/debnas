#!/bin/bash
# 功能：依赖检测与自动/手动安装模块

set -euo pipefail
IFS=$'\n\t'

# 获取库文件目录
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$LIB_DIR/core/logging.sh"

# 命令到包名映射表
declare -A cmd_to_pkg=(
  ["grep"]="grep"
  ["awk"]="gawk"
  ["sed"]="sed"
  ["curl"]="curl"
  ["wget"]="wget"
  ["apt"]="apt"
  ["bash"]="bash"
  ["systemctl"]="systemd"
  ["hostname"]="hostname"
  ["dpkg"]="dpkg"
  ["cp"]="coreutils"
  ["mv"]="coreutils"
  ["docker"]="docker.io"
  ["tar"]="tar"
  ["rsync"]="rsync"
  ["msmtp"]="msmtp"
  ["mail"]="mailutils"
  ["firewall-cmd"]="firewalld"
  ["exim4"]="exim4"
  ["update-exim4.conf"]="exim4-config"
  ["sysctl"]="procps"
  ["dig"]="dnsutils"
  ["ping"]="iputils-ping"
  ["sipcalc"]="sipcalc"
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
  if ! has_valid_main_apt_source; then
    log_error "未检测到有效主软件源（/etc/apt/sources.list 或 /etc/apt/sources.list.d/debian.sources），请先配置软件源后再安装依赖：${missing_cmds[*]}"
    return 1
  fi
  for cmd in "${missing_cmds[@]}"; do
    # 使用 ${var:-} 避免 unbound variable 错误（set -u 环境下）
    local pkg_name="${cmd_to_pkg[$cmd]:-}"
    if [[ -n "$pkg_name" ]]; then
      log_info "尝试安装 $cmd 对应的包：$pkg_name"
      if apt update && apt install -y "$pkg_name"; then
        log_success "成功安装 $cmd"
      else
        log_error "安装 $cmd 失败，请手动安装"
      fi
    else
      log_error "无法自动安装 $cmd，请手动安装"
    fi
  done
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
    # 使用 ${var:-} 避免 unbound variable 错误（set -u 环境下）
    local pkg_name="${cmd_to_pkg[$cmd]:-}"
    if [[ -n "$pkg_name" ]]; then
      echo "apt install $pkg_name"
    else
      echo "# 无法确定 $cmd 的包名，请手动查找并安装"
    fi
  done
}
