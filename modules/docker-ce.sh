#!/bin/bash
# @module: docker-ce
# @name: Docker CE
# @category: 容器管理
# @depends: wget,curl
# @version: 1.0.0
# @order: 50
# 功能：安装 Docker CE 社区版

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/bootstrap.sh"

# ==================== 函数定义 ====================

# 检测镜像站连通性（基于 urls.sh 的 probe_url）
probe_mirror() {
  probe_url "$1"
}

# 从 debian.sources 文件中提取镜像源基础 URL
# 返回：镜像源基础 URL（不含路径），失败返回非 0
extract_mirror_from_sources() {
  local sources_file="/etc/apt/sources.list.d/debian.sources"

  if [[ ! -f "$sources_file" ]] || [[ ! -r "$sources_file" ]]; then
    return 1
  fi

  local first_uri
  first_uri=$(awk '
    /^[[:space:]]*URIs:[[:space:]]+/ && !/^[[:space:]]*#/ {
      sub(/^[[:space:]]*URIs:[[:space:]]+/, "")
      if ($1 ~ /^https?:\/\//) {
        print $1
        exit
      }
    }
  ' "$sources_file" 2>/dev/null)

  if [[ -z "$first_uri" ]]; then
    return 1
  fi

  if [[ "$first_uri" =~ ^(https?://[^/]+) ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi

  return 1
}

# 检测是否为 Debian 官方源
# 参数：$1 - 镜像源基础 URL
# 返回：0 表示是官方源，非 0 表示不是官方源
is_official_debian_source() {
  local mirror_url="$1"

  if [[ "$mirror_url" =~ ^https?://(deb\.debian\.org|ftp\.debian\.org) ]]; then
    return 0
  fi

  return 1
}

# 获取 Docker 镜像源（优先从系统源提取，失败则使用备用源）
# 返回：Docker 镜像源完整 URL（标准输出），日志输出到标准错误
get_docker_mirror() {
  local base_mirror=""
  local docker_mirror=""

  base_mirror=$(extract_mirror_from_sources)

  if [[ -n "$base_mirror" ]]; then
    if is_official_debian_source "$base_mirror"; then
      log_info "Docker 官方源" >&2
      echo "$DOCKER_OFFICIAL_MIRROR" >&1
      return 0
    else
      docker_mirror="${base_mirror}/docker-ce/linux/debian"
      if probe_mirror "${docker_mirror}/dists/"; then
        log_info "镜像: ${base_mirror}" >&2
        echo "$docker_mirror" >&1
        return 0
      else
        log_warning "镜像 ${base_mirror} 不可用" >&2
      fi
    fi
  else
    log_warning "无系统镜像配置" >&2
  fi

  for fallback in "${DOCKER_FALLBACK_MIRRORS[@]}"; do
    docker_mirror="${fallback}/docker-ce/linux/debian"
    if probe_mirror "${docker_mirror}/dists/"; then
      log_info "镜像: ${fallback}" >&2
      echo "$docker_mirror" >&1
      return 0
    fi
  done

  log_warning "备用镜像不可用" >&2
  if probe_mirror "$DOCKER_OFFICIAL_MIRROR"; then
    log_info "Docker 官方源" >&2
    echo "$DOCKER_OFFICIAL_MIRROR" >&1
    return 0
  else
    log_error "Docker 官方源也不可用，无法继续安装" >&2
    return 1
  fi
}

# 安装 Docker 前置依赖（ca-certificates + keyring 目录）
install_docker_prerequisites() {
  log_info "安装依赖..."
  apt_install_packages ca-certificates curl
  install -m 0755 -d /etc/apt/keyrings
}

# 下载 Docker GPG 签名密钥（含 3 次重试）
# 参数：$1 - Docker 镜像源 URL
download_docker_gpg_key() {
  local docker_mirror="$1"

  log_info "获取 GPG 密钥..."

  local gpg_downloaded=0
  local max_retries=3
  local retry_count=0

  while [[ $retry_count -lt $max_retries ]]; do
    if curl -fsSL --max-time 30 --connect-timeout 10 "${docker_mirror}/gpg" -o /etc/apt/keyrings/docker.asc 2>/dev/null; then
      if [[ -s /etc/apt/keyrings/docker.asc ]] && grep -q "BEGIN PGP PUBLIC KEY BLOCK" /etc/apt/keyrings/docker.asc 2>/dev/null; then
        gpg_downloaded=1
        break
      else
        rm -f /etc/apt/keyrings/docker.asc
      fi
    fi
    ((retry_count++))
    if [[ $retry_count -lt $max_retries ]]; then
      log_warning "GPG 密钥下载失败，重试中 ($retry_count/$max_retries)"
      sleep 2
    fi
  done

  if [[ $gpg_downloaded -eq 0 ]]; then
    log_fail "GPG 密钥下载失败"
    exit "${ERROR_DEPENDENCY}"
  fi

  chmod a+r /etc/apt/keyrings/docker.asc
}

# 写入 Docker APT 软件源（DEB822 格式，幂等）
# 参数：$1 - Docker 镜像源 URL
write_docker_apt_source() {
  local docker_mirror="$1"

  log_info "写入 Docker 源..."

  # 备份旧格式文件（sources.list 格式）
  local old_docker_list="/etc/apt/sources.list.d/docker.list"
  if [[ -f "$old_docker_list" ]]; then
    log_info "旧源文件已备份"
    mv "$old_docker_list" "${old_docker_list}.bak"
  fi

  # 使用 DEB822 格式写入软件源配置（幂等：内容未变则跳过）
  local codename
  codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
  local docker_sources_content="Types: deb"$'\n'"URIs: ${docker_mirror}"$'\n'"Suites: ${codename}"$'\n'"Components: stable"$'\n'"Signed-By: /etc/apt/keyrings/docker.asc"
  write_file_if_changed "/etc/apt/sources.list.d/docker.sources" "$docker_sources_content" || true

  apt_update_safe
}

# 安装 Docker 软件包（已装则升级，未装则全新安装）
install_docker_packages() {
  log_info "安装 Docker 组件..."
  if command -v docker &>/dev/null; then
    log_info "$(docker --version)"
    # 已安装，尝试升级
    apt_update_safe
    apt_install_safe docker-ce docker-ce-cli containerd.io
  else
    # 全新安装
    apt_install_packages docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi
}

# 将第一个常规用户添加到 docker 组
# 参数：$1 - 用户名（空则跳过）
add_user_to_docker_group() {
  local first_user="$1"

  if [[ -n "$first_user" ]]; then
    log_info "添加用户到 docker 组..."
    usermod -aG docker "$first_user"
    log_success "Docker CE 就绪"
  else
    log_info "无普通用户，跳过 docker 组"
    log_success "Docker CE 就绪"
  fi
}

# ==================== 主入口 ====================

main() {
  if ! verify_system_support; then
    exit "${ERROR_UNSUPPORTED_OS}"
  fi

  . /etc/os-release

  log_info "检测镜像源"
  local DOCKER_MIRROR
  DOCKER_MIRROR=$(get_docker_mirror) || {
    log_fail "无法获取 Docker 源"
    exit "${ERROR_DEPENDENCY}"
  }

  local first_user
  first_user=$(get_first_regular_user)

  log_info "安装 Docker CE..."
  install_docker_prerequisites
  download_docker_gpg_key "$DOCKER_MIRROR"
  write_docker_apt_source "$DOCKER_MIRROR"
  install_docker_packages
  service_ensure docker started
  service_ensure docker enabled
  add_user_to_docker_group "$first_user"

  log_info "Docker $(docker --version 2>/dev/null | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
}

main "$@"
