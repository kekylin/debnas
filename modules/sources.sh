#!/bin/bash
# @module: sources
# @name: APT 软件源
# @category: 基础系统
# @depends:
# 说明：使用 smart library 实现幂等写入，内容未变更时跳过 apt update
# @version: 1.0.0
# @order: 10
# 功能：自动配置 Debian 软件源（DEB822 格式）

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/bootstrap.sh"

# ==================== 常量 ====================

DEB822_PATH="/etc/apt/sources.list.d/debian.sources"
TRADITIONAL_PATH="/etc/apt/sources.list"

# wget/curl 用于镜像站连通性探测；如果不可用则跳过探测，使用默认镜像
_HAS_PROBE_TOOL=1
if ! command -v wget &>/dev/null && ! command -v curl &>/dev/null; then
  log_warning "无 wget/curl，使用默认镜像"
  _HAS_PROBE_TOOL=0
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
    log_info "使用默认镜像"
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
    log_warning "镜像不可用，使用官方源"
    if probe_mirror "${APT_OFFICIAL_MIRROR}"; then
      selected_mirror="${APT_OFFICIAL_MIRROR}"
    else
      log_warning "官方源连接失败"
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

# 构建 DEB822 格式的软件源配置内容
# 参数：mirror_url - 镜像站 URL
# 输出：DEB822 配置内容（stdout）
build_deb822_content() {
  local mirror_url="$1"

  cat <<EOF
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

# 执行 apt update 更新软件包列表（带连通性检查）
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
    log_warning "已写入源，网络检测失败"
    log_info "请检查网络，恢复后 apt update"
    return 1
  fi

  if ! apt_update_safe; then
    log_warning "apt update 失败"
    return 1
  fi
  return 0
}

main() {
  local selected_mirror
  local mirror_name
  local new_content

  if ! verify_debian_12_13_support; then
    return 0
  fi

  selected_mirror=$(detect_best_mirror)
  mirror_name=$(get_mirror_name "${selected_mirror}")
  if [[ "${mirror_name}" == "${selected_mirror}" ]]; then
    mirror_name="${APT_OFFICIAL_MIRROR_NAME}"
  fi
  log_success "${mirror_name}"

  # 构建 DEB822 内容，使用 write_file_if_changed 实现幂等写入
  new_content=$(build_deb822_content "${selected_mirror}")
  if write_file_if_changed "$DEB822_PATH" "$new_content"; then
    # 内容变更：备份旧配置（传统 sources.list）
    if [[ -f "${TRADITIONAL_PATH}" ]]; then
      mv "${TRADITIONAL_PATH}" "${TRADITIONAL_PATH}.bak"
    fi
    log_success "源已写入"
    if ! update_package_lists "${selected_mirror}"; then
      log_warning "apt update 失败，源已写入"
      return 1
    fi
  else
    log_info "源未变更，跳过更新"
  fi

  # 状态由 module-runner.sh 的 run_report() 统一管理
}

main "$@"
