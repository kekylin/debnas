#!/bin/bash
# 功能：APT Pinning 配置管理模块，提供统一的软件源优先级配置

set -euo pipefail
IFS=$'\n\t'

# 获取库文件目录
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 加载核心模块
source "$LIB_DIR/core/logging.sh"
source "$LIB_DIR/system/utils.sh"

# APT Pinning 配置目录
APT_PREFERENCES_DIR="/etc/apt/preferences.d"

write_pinning_file() {
  # 用法: write_pinning_file <pinning_file> <os_codename> <packages_group_1> [<packages_group_2> ...]
  local pinning_file="$1"
  local os_codename="$2"
  shift 2

  mkdir -p "${APT_PREFERENCES_DIR}"

  {
    echo "# 优先从 backports 安装/更新"
    echo "# 配置时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "# 系统版本: ${os_codename}"
    for pkg_group in "$@"; do
      echo "Package: ${pkg_group}"
      echo "Pin: release n=${os_codename}-backports"
      echo "Pin-Priority: 500"
      echo
    done
  } > "${pinning_file}"

  chmod 644 "${pinning_file}"
}

# 写入 Cockpit 相关组件的 APT Pinning（始终覆盖为最新）
configure_cockpit_pinning() {
  local os_codename="$1"
  local pinning_file="${APT_PREFERENCES_DIR}/cockpit-backports.pref"
  write_pinning_file "${pinning_file}" "${os_codename}" \
    "cockpit cockpit-*"
  log_success "Cockpit APT Pinning 配置已写入: ${pinning_file}"
  return 0
}

# 配置特定组件的 APT Pinning
configure_component_pinning() {
  local os_codename="$1"
  local component="$2"
  local packages="$3"
  local pinning_file="${APT_PREFERENCES_DIR}/${component}-backports.pref"

  log_info "写入 ${component} APT Pinning 配置..."
  write_pinning_file "${pinning_file}" "${os_codename}" "${packages}"
  log_success "${component} APT Pinning 配置已写入: ${pinning_file}"
  return 0
}

# 应用 APT Pinning 配置
apply_pinning_config() {
  log_info "正在应用 APT Pinning 配置..."
  
  if ! apt update; then
    log_error "软件源更新失败，APT Pinning 配置可能未生效"
    return 1
  fi
  
  log_success "APT Pinning 配置已生效"
  return 0
}

# 检查 APT Pinning 配置状态
check_pinning_status() {
  local pinning_file="$1"
  
  if [[ -f "${pinning_file}" ]]; then
    log_info "APT Pinning 配置文件存在: ${pinning_file}"
    return 0
  else
    log_warning "APT Pinning 配置文件不存在: ${pinning_file}"
    return 1
  fi
}

# 清理 APT Pinning 配置
cleanup_pinning_config() {
  local pinning_file="$1"
  
  if [[ -f "${pinning_file}" ]]; then
    rm -f "${pinning_file}"
    log_info "已清理 APT Pinning 配置: ${pinning_file}"
    return 0
  fi
  
  return 0
}

# 显示所有 APT Pinning 配置状态
show_all_pinning_status() {
  log_info "检查所有 APT Pinning 配置状态..."
  
  local found_configs=0
  
  for config_file in "${APT_PREFERENCES_DIR}"/*.pref; do
    if [[ -f "${config_file}" ]]; then
      echo "配置文件: ${config_file}"
      echo "内容预览:"
      head -5 "${config_file}" | sed 's/^/  /'
      echo ""
      found_configs=$((found_configs + 1))
    fi
  done
  
  if [[ $found_configs -eq 0 ]]; then
    log_info "未发现任何 APT Pinning 配置文件"
  else
    log_info "共发现 ${found_configs} 个 APT Pinning 配置文件"
  fi
}
