#!/bin/bash
# 功能：自动配置 Debian 软件源（DEB822 格式）

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/core/constants.sh"
source "${SCRIPT_DIR}/lib/core/logging.sh"
source "${SCRIPT_DIR}/lib/system/dependency.sh"
source "${SCRIPT_DIR}/lib/system/utils.sh"
source "${SCRIPT_DIR}/lib/system/mirrors.sh"

readonly DEB822_PATH="/etc/apt/sources.list.d/debian.sources"
readonly TRADITIONAL_PATH="/etc/apt/sources.list"
readonly PROBE_TIMEOUT=5

REQUIRED_CMDS=(wget apt)
if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
  log_info "检测到依赖缺失，执行自动安装"
  install_missing_dependencies "${REQUIRED_CMDS[@]}"
  if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
    log_error "依赖安装失败，请手动安装：${REQUIRED_CMDS[*]}"
    exit "${ERROR_DEPENDENCY}"
  fi
fi

if ! verify_debian_12_13_support; then
  exit 0
fi

CODENAME=$(get_system_codename)

# 检测镜像站连通性
# 参数：mirror_url - 镜像站 URL
# 返回：0 表示可达，1 表示不可达
probe_mirror() {
  local mirror_url="$1"
  local check_url="${mirror_url}/debian/dists/${CODENAME}/Release"
  
  if wget --spider --quiet --timeout="${PROBE_TIMEOUT}" --tries=1 "${check_url}" 2>/dev/null; then
    return 0
  else
    return 1
  fi
}

# 选择可用镜像站
# 返回：选定的镜像站 URL
detect_best_mirror() {
  local selected_mirror=""
  
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
      # 即使探测失败，也使用官方镜像站作为回退配置（网络可能在后续恢复）
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
  
  if ! probe_mirror "${mirror_url}"; then
    is_offline=true
  fi
  
  if [[ "${is_offline}" == "true" ]]; then
    log_warning "软件源已配置为官方地址，但当前网络检测失败"
    log_warning "请检查网络连接、DNS 配置或网关设置。网络恢复后执行 'apt update' 验证"
    return 1
  fi
  
  log_info "执行 apt update 更新软件包列表"
  if apt update; then
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

main
