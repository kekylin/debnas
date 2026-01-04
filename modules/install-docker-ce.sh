#!/bin/bash
# 功能：安装 Docker CE 社区版

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/core/constants.sh"
source "${SCRIPT_DIR}/lib/core/logging.sh"
source "${SCRIPT_DIR}/lib/system/utils.sh"
source "${SCRIPT_DIR}/lib/system/mirrors.sh"

# ==================== 函数定义 ====================

# 检测镜像站连通性
# 参数：$1 - 镜像站 URL
# 返回：0 表示可达，1 表示不可达
probe_mirror() {
  local mirror_url="$1"
  
  if wget --spider --quiet --timeout=5 --tries=1 "${mirror_url}" 2>/dev/null; then
    return 0
  else
    return 1
  fi
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
      log_info "检测到 Debian 官方源，Docker 使用官方源: ${DOCKER_OFFICIAL_MIRROR}" >&2
      echo "$DOCKER_OFFICIAL_MIRROR" >&1
      return 0
    else
      if probe_mirror "$base_mirror"; then
        docker_mirror="${base_mirror}/docker-ce/linux/debian"
        log_info "使用系统配置的镜像源: ${base_mirror}" >&2
        echo "$docker_mirror" >&1
        return 0
      else
        log_warning "系统镜像源不可用 (${base_mirror})，尝试备用镜像源" >&2
      fi
    fi
  else
    log_info "未检测到系统镜像源配置，使用备用镜像源" >&2
  fi
  
  for fallback in "${DOCKER_FALLBACK_MIRRORS[@]}"; do
    if probe_mirror "$fallback"; then
      docker_mirror="${fallback}/docker-ce/linux/debian"
      log_info "使用备用镜像源: ${fallback}" >&2
      echo "$docker_mirror" >&1
      return 0
    fi
  done
  
  log_warning "所有备用镜像源均不可用，尝试使用 Docker 官方源" >&2
  if probe_mirror "$DOCKER_OFFICIAL_MIRROR"; then
    log_info "Docker 官方源可用，使用官方源: ${DOCKER_OFFICIAL_MIRROR}" >&2
    echo "$DOCKER_OFFICIAL_MIRROR" >&1
    return 0
  else
    log_error "Docker 官方源也不可用，无法继续安装" >&2
    return 1
  fi
}

# ==================== 主执行逻辑 ====================

if ! verify_system_support; then
  exit "${ERROR_UNSUPPORTED_OS}"
fi

. /etc/os-release
OS_NAME=$(echo "$NAME" | tr '[:upper:]' '[:lower:]')
VERSION_CODENAME=$(echo "$VERSION_CODENAME")

log_info "检测镜像源可用性..."
DOCKER_MIRROR=$(get_docker_mirror)
mirror_status=$?

if [[ $mirror_status -ne 0 ]] || [[ -z "$DOCKER_MIRROR" ]]; then
  log_error "无法获取有效的 Docker 镜像源，安装终止"
  exit "${ERROR_DEPENDENCY}"
fi

log_info "开始安装 Docker CE..."

log_info "更新软件包列表并安装依赖..."
apt update
apt install -y ca-certificates curl

install -m 0755 -d /etc/apt/keyrings
log_info "下载 GPG 密钥..."

gpg_downloaded=0
max_retries=3
retry_count=0

while [[ $retry_count -lt $max_retries ]]; do
  if curl -fsSL --max-time 30 --connect-timeout 10 "${DOCKER_MIRROR}/gpg" -o /etc/apt/keyrings/docker.asc 2>/dev/null; then
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
  log_error "GPG 密钥下载失败，请检查网络连接或镜像源可用性"
  exit "${ERROR_DEPENDENCY}"
fi

chmod a+r /etc/apt/keyrings/docker.asc

log_info "配置 Docker 软件源..."

# 备份旧格式文件（sources.list 格式）
readonly OLD_DOCKER_LIST="/etc/apt/sources.list.d/docker.list"
if [[ -f "$OLD_DOCKER_LIST" ]]; then
  log_info "检测到旧格式文件，重命名为备份文件"
  mv "$OLD_DOCKER_LIST" "${OLD_DOCKER_LIST}.bak"
fi

# 使用 DEB822 格式写入软件源配置
tee /etc/apt/sources.list.d/docker.sources > /dev/null <<EOF
Types: deb
URIs: ${DOCKER_MIRROR}
Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF

apt update

log_info "安装 Docker 组件..."
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# 获取 UID 1000 的用户（通常是 Debian 系统安装时创建的第一个用户）
first_user=$(awk -F: '$3==1000 && $1 != "nobody" {print $1; exit}' /etc/passwd)

if [[ -n "$first_user" ]]; then
  log_info "将系统第一个用户（UID 1000）添加到 docker 组..."
  usermod -aG docker "$first_user"
  
  if systemctl is-active --quiet docker; then
    log_success "Docker 安装完成，用户 $first_user（UID 1000）已添加到 docker 组"
  else
    systemctl enable --now docker
    log_success "Docker 安装完成，用户 $first_user（UID 1000）已添加到 docker 组，服务已启动并设置为开机自启"
  fi
else
  log_info "未检测到 UID 1000 的用户，跳过 docker 组添加"
  
  if systemctl is-active --quiet docker; then
    log_success "Docker 安装完成"
  else
    systemctl enable --now docker
    log_success "Docker 安装完成，服务已启动并设置为开机自启"
  fi
fi
