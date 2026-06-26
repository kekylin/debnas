#!/bin/bash
# @module: sources
# @name: 配置软件源
# @category: 基础系统
# @depends: wget,apt
# @version: 1.0.0
# @order: 10
# 功能：自动配置 Debian 软件源（DEB822 格式）

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/bootstrap.sh"

# ==================== 幂等性检查 ====================
if [[ -f "/etc/apt/sources.list.d/debian.sources" ]]; then
  if grep -q "^URIs:" /etc/apt/sources.list.d/debian.sources 2>/dev/null; then
    if state_is_installed "sources" 2>/dev/null; then
      log_info "APT 软件源已配置，跳过（如需重新配置，请先删除 /etc/apt/sources.list.d/debian.sources）"
      exit 0
    fi
  fi
fi

readonly DEB822_PATH="/etc/apt/sources.list.d/debian.sources"
readonly TRADITIONAL_PATH="/etc/apt/sources.list"
readonly PROBE_TIMEOUT=5

# wget 用于镜像站连通性探测；如果不可用则跳过探测，使用默认镜像
_HAS_PROBE_TOOL=1
if ! command -v wget &>/dev/null && ! command -v curl &>/dev/null; then
  log_info "wget/curl 不可用，尝试安装..."
  install_missing_dependencies wget 2>/dev/null || true
  if ! command -v wget &>/dev/null && ! command -v curl &>/dev/null; then
    log_warning "wget/curl 无法安装，将跳过镜像站探测，直接使用默认镜像"
    _HAS_PROBE_TOOL=0
  fi
fi

if ! verify_debian_12_13_support; then
  exit 0
fi

CODENAME=$(get_system_codename)

# 检测 APT 镜像站连通性（基于 urls.sh 的 probe_url，追加 Release 路径验证）
probe_mirror() {
  local mirror_url="$1"
  probe_url "${mirror_url}/debian/dists/${CODENAME}/Release"
}

# 选择可用镜像站
# 返回：选定的镜像站 URL
detect_best_mirror() {
  local selected_mirror=""

  # 无探测工具时，直接使用第一个国内镜像（不探测）
  if [[ "${_HAS_PROBE_TOOL}" -eq 0 ]]; then
    log_info "跳过镜像站探测，使用默认国内镜像"
    echo "${APT_MIRRORS[0]}"
    return 0
  fi

  for mirror in "${APT_MIRRORS[@]}"; do
    if probe_mirror "${mirror}"; then
      selected_mirror="${mirror}"
      break
    fi
  done

  if [[ -z "${selected_mirror}" ]]; then
    log_warning "未检测到可用的国内镜像站，使用官方镜像站"
    if probe_mirror "${APT_OFFICIAL_MIRROR}"; then
      selected_mirror="${APT_OFFICIAL_MIRROR}"
    else
      log_warning "官方镜像站连接失败，网络可能异常"
      selected_mirror="${APT_OFFICIAL_MIRROR}"
    fi
  fi

  echo "${selected_mirror}"
}

# 备份旧配置文件（原子操作，防止多次运行产生 .bak.bak）
backup_config_files() {
  if [[ -f "${TRADITIONAL_PATH}" ]]; then
    mv "${TRADITIONAL_PATH}" "${TRADITIONAL_PATH}.bak"
  fi
  
  if [[ -f "${DEB822_PATH}" ]]; then
    mv "${DEB822_PATH}" "${DEB822_PATH}.bak"
  fi
}

# 写入 DEB822 格式的软件源配置
# 参数：mirror_url - 镜像站 URL
write_deb822_config() {
  local mirror_url="$1"
  
  cat <<EOF > "${DEB822_PATH}"
# Standard Repository
Types: deb
URIs: ${mirror_url}/debian
Suites: ${CODENAME} ${CODENAME}-updates ${CODENAME}-backports
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

# Security Repository
Types: deb
URIs: ${mirror_url}/debian-security
Suites: ${CODENAME}-security
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
}

# 执行 apt update 更新软件包列表
# 参数：mirror_url - 镜像站 URL
# 返回：0 表示成功，1 表示失败
update_package_lists() {
  local mirror_url="$1"
  local is_offline=false

  # 有探测工具时才进行连通性检查
  if [[ "${_HAS_PROBE_TOOL}" -eq 1 ]] && ! probe_mirror "${mirror_url}"; then
    is_offline=true
  fi

  if [[ "${is_offline}" == "true" ]]; then
    log_warning "软件源已配置为官方地址，但当前网络检测失败"
    log_warning "请检查网络连接、DNS 配置或网关设置。网络恢复后执行 'apt update' 验证"
    return 1
  fi
  
  if [[ "${_DEBNAS_APT_UPDATED:-0}" -eq 1 ]]; then
    log_info "已全局更新过软件包列表，跳过 apt update。"
    return 0
  fi
  log_info "执行 apt update 更新软件包列表"
  if apt update; then
    export _DEBNAS_APT_UPDATED=1
    local mirror_name
    mirror_name=$(get_mirror_name "${mirror_url}")
    if [[ "${mirror_name}" == "${mirror_url}" ]]; then
      mirror_name="${APT_OFFICIAL_MIRROR_NAME}"
    fi
    log_success "软件包列表更新完成"
    return 0
  else
    log_warning "apt update 执行失败，网络连接可能异常"
    return 1
  fi
}

main() {
  local selected_mirror
  local mirror_name
  
  selected_mirror=$(detect_best_mirror)
  mirror_name=$(get_mirror_name "${selected_mirror}")
  if [[ "${mirror_name}" == "${selected_mirror}" ]]; then
    mirror_name="${APT_OFFICIAL_MIRROR_NAME}"
  fi
  log_success "已选择镜像站：${mirror_name}"
  
  backup_config_files
  write_deb822_config "${selected_mirror}"
  update_package_lists "${selected_mirror}"
}

# ==================== 记录状态 ====================
state_mark_success "sources"

main
