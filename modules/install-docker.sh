#!/bin/bash
# 功能：安装 Docker CE 社区版

set -euo pipefail
IFS=$'\n\t'

# 加载公共模块，确保依赖函数和常量可用
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/core/constants.sh"
source "${SCRIPT_DIR}/lib/core/logging.sh"
source "${SCRIPT_DIR}/lib/system/dependency.sh"
source "${SCRIPT_DIR}/lib/system/utils.sh"

# 检查 apt、curl 依赖，确保后续操作可用
REQUIRED_CMDS=(apt curl)
if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
  log_error "缺少必需依赖：apt 或 curl"
  exit "${ERROR_DEPENDENCY}"
fi

# 检查系统兼容性，防止在不支持的平台运行
if ! verify_system_support; then
  exit "${ERROR_UNSUPPORTED_OS}"
fi

# Docker 安装前的系统检查，提前发现潜在问题
log_info "正在执行 Docker 安装前系统检查..."

# 检查内存（Docker 建议至少 1GB）
if ! check_memory_requirements 1024; then
  log_warning "内存不足，可能影响 Docker 运行"
fi

if ! check_disk_space "/" 10; then
  log_warning "磁盘空间不足，可能影响 Docker 运行"
fi

# 验证 URL 格式
# 参数：$1 - URL 字符串
# 返回：0有效，非0无效
is_valid_url() {
  local url="$1"
  
  if [[ "$url" =~ ^https?://[a-zA-Z0-9][a-zA-Z0-9._-]*[a-zA-Z0-9](:[0-9]+)?(/.*)?$ ]]; then
    return 0
  fi
  
  return 1
}

# 从 debian.sources 文件中提取镜像源地址
# 参数：无
# 返回：镜像源基础 URL（不含路径），失败返回空字符串
extract_mirror_from_sources() {
  local sources_file="/etc/apt/sources.list.d/debian.sources"
  
  if [[ ! -f "$sources_file" ]] || [[ ! -r "$sources_file" ]]; then
    return 1
  fi
  
  local uri_line
  uri_line=$(grep -E '^[[:space:]]*URIs:[[:space:]]+' "$sources_file" 2>/dev/null | grep -vE '^[[:space:]]*#' | head -n 1 | sed 's/^[[:space:]]*URIs:[[:space:]]*//')
  
  if [[ -z "$uri_line" ]]; then
    return 1
  fi
  
  local first_uri
  first_uri=$(echo "$uri_line" | awk '{print $1}')
  
  if [[ -z "$first_uri" ]]; then
    return 1
  fi
  
  local base_url
  base_url=$(echo "$first_uri" | sed -E 's|(https?://[^/]+).*|\1|')
  
  if ! is_valid_url "$base_url"; then
    return 1
  fi
  
  echo "$base_url"
}

# 测试镜像源可用性
# 参数：$1 - 镜像源基础 URL，$2 - 是否为官方源（可选，默认否）
# 返回：0可用，非0不可用
test_mirror_availability() {
  local mirror_url="$1"
  local is_official="${2:-0}"
  local docker_path="${mirror_url}/docker-ce/linux/debian"
  local max_retries=2
  local retry_count=0
  
  if ! is_valid_url "$mirror_url"; then
    return 1
  fi
  
  while [[ $retry_count -lt $max_retries ]]; do
    if check_network_connectivity "$mirror_url" 10; then
      break
    fi
    ((retry_count++))
    if [[ $retry_count -lt $max_retries ]]; then
      sleep 1
    fi
  done
  
  if [[ $retry_count -ge $max_retries ]]; then
    return 1
  fi
  
  if [[ "$is_official" == "1" ]]; then
    return 0
  fi
  
  retry_count=0
  while [[ $retry_count -lt $max_retries ]]; do
    if command -v curl >/dev/null 2>&1; then
      if curl -s --max-time 10 --connect-timeout 10 --head "$docker_path" >/dev/null 2>&1; then
        return 0
      fi
    elif command -v wget >/dev/null 2>&1; then
      if wget -q --timeout=10 --tries=1 --spider "$docker_path" 2>/dev/null; then
        return 0
      fi
    else
      return 0
    fi
    ((retry_count++))
    if [[ $retry_count -lt $max_retries ]]; then
      sleep 1
    fi
  done
  
  return 1
}

# 检测是否为 Debian 官方源
# 参数：$1 - 镜像源基础 URL
# 返回：0是官方源，非0不是官方源
is_official_debian_source() {
  local mirror_url="$1"
  
  if [[ "$mirror_url" =~ ^https?://(deb\.debian\.org|ftp\.debian\.org) ]]; then
    return 0
  fi
  
  return 1
}

# 获取 Docker 镜像源（优先从系统源提取，失败则使用备用源）
# 参数：无
# 返回：Docker 镜像源完整 URL（仅输出 URL，日志输出到 stderr）
get_docker_mirror() {
  local base_mirror=""
  local docker_mirror=""
  
  local docker_official="https://download.docker.com/linux/debian"
  
  local -a fallback_mirrors=(
    "https://mirrors.tuna.tsinghua.edu.cn"
    "https://mirrors.ustc.edu.cn"
    "https://mirrors.aliyun.com"
    "https://mirrors.cloud.tencent.com"
    "https://mirrors.huaweicloud.com"
  )
  
  base_mirror=$(extract_mirror_from_sources)
  
  if [[ -n "$base_mirror" ]]; then
    if is_official_debian_source "$base_mirror"; then
      if test_mirror_availability "$docker_official" 1; then
        log_info "检测到 Debian 官方源，Docker 使用官方源: ${docker_official}" >&2
        echo "$docker_official" >&1
        return 0
      else
        log_warning "Docker 官方源不可用，尝试备用镜像源" >&2
      fi
    else
      if check_network_connectivity "$base_mirror" 10; then
        local docker_path="${base_mirror}/docker-ce/linux/debian"
        local docker_path_exists=0
        
        if command -v curl >/dev/null 2>&1; then
          if curl -s --max-time 10 --connect-timeout 10 --head "$docker_path" >/dev/null 2>&1; then
            docker_path_exists=1
          fi
        elif command -v wget >/dev/null 2>&1; then
          if wget -q --timeout=10 --tries=1 --spider "$docker_path" 2>/dev/null; then
            docker_path_exists=1
          fi
        fi
        
        if [[ $docker_path_exists -eq 1 ]]; then
          docker_mirror="${base_mirror}/docker-ce/linux/debian"
          if is_valid_url "$docker_mirror"; then
            log_info "使用系统配置的镜像源: ${base_mirror}" >&2
            echo "$docker_mirror" >&1
            return 0
          else
            log_warning "系统镜像源 URL 格式无效，尝试备用镜像源" >&2
          fi
        else
          log_warning "系统镜像源 (${base_mirror}) 基础 URL 可访问，但 Docker 镜像路径不存在，尝试备用镜像源" >&2
        fi
      else
        log_warning "系统镜像源不可用 (${base_mirror})，尝试备用镜像源" >&2
      fi
    fi
  else
    log_info "未检测到系统镜像源配置，使用备用镜像源" >&2
  fi
  
  local best_fallback=""
  for fallback in "${fallback_mirrors[@]}"; do
    if check_network_connectivity "$fallback" 10; then
      local docker_path="${fallback}/docker-ce/linux/debian"
      local docker_path_exists=0
      
      if command -v curl >/dev/null 2>&1; then
        if curl -s --max-time 10 --connect-timeout 10 --head "$docker_path" >/dev/null 2>&1; then
          docker_path_exists=1
        fi
      elif command -v wget >/dev/null 2>&1; then
        if wget -q --timeout=10 --tries=1 --spider "$docker_path" 2>/dev/null; then
          docker_path_exists=1
        fi
      fi
      
      if [[ $docker_path_exists -eq 1 ]]; then
        docker_mirror="${fallback}/docker-ce/linux/debian"
        if is_valid_url "$docker_mirror"; then
          log_info "使用备用镜像源: ${fallback}" >&2
          echo "$docker_mirror" >&1
          return 0
        fi
      else
        if [[ -z "$best_fallback" ]]; then
          best_fallback="$fallback"
        fi
      fi
    fi
  done
  
  if [[ -n "$best_fallback" ]]; then
    docker_mirror="${best_fallback}/docker-ce/linux/debian"
    if is_valid_url "$docker_mirror"; then
      log_warning "使用备用镜像源（Docker 路径可能不存在）: ${best_fallback}" >&2
      echo "$docker_mirror" >&1
      return 0
    fi
  fi
  
  log_warning "所有镜像源均不可用，使用默认镜像源: ${fallback_mirrors[0]}" >&2
  docker_mirror="${fallback_mirrors[0]}/docker-ce/linux/debian"
  if is_valid_url "$docker_mirror"; then
    echo "$docker_mirror" >&1
    return 1
  else
    log_error "默认镜像源 URL 格式无效: ${docker_mirror}" >&2
    return 2
  fi
}

log_info "检测镜像源可用性..."
DOCKER_MIRROR=$(get_docker_mirror)

if [[ -z "$DOCKER_MIRROR" ]] || ! is_valid_url "$DOCKER_MIRROR"; then
  log_error "无法获取有效的 Docker 镜像源，安装终止"
  exit "${ERROR_DEPENDENCY}"
fi

if is_container; then
  log_warning "检测到容器环境，Docker 安装可能受限"
fi

. /etc/os-release
OS_NAME=$(echo "$NAME" | tr '[:upper:]' '[:lower:]')
VERSION_CODENAME=$(echo "$VERSION_CODENAME")

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
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] ${DOCKER_MIRROR} \
$(. /etc/os-release && echo "${VERSION_CODENAME}") stable" | \
tee /etc/apt/sources.list.d/docker.list > /dev/null

apt update

log_info "安装 Docker 组件..."
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

first_user=$(awk -F: '$3>=1000 && $1 != "nobody" {print $1}' /etc/passwd | sort | head -n 1)

if [[ -n "$first_user" ]]; then
  log_info "将用户添加到 docker 组..."
  usermod -aG docker "$first_user"
  
  if systemctl is-active --quiet docker; then
    log_success "Docker 安装完成，用户 $first_user 已添加到 docker 组"
  else
    systemctl enable --now docker
    log_success "Docker 安装完成，用户 $first_user 已添加到 docker 组，服务已启动并设置为开机自启"
  fi
else
  log_info "未检测到普通用户，跳过用户组添加"
  
  if systemctl is-active --quiet docker; then
    log_success "Docker 安装完成"
  else
    systemctl enable --now docker
    log_success "Docker 安装完成，服务已启动并设置为开机自启"
  fi
fi
