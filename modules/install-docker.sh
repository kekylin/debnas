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
  log_error "缺少 apt 或 curl，请先手动安装。"
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
  log_warning "内存不足，Docker 可能无法正常运行。"
fi

# 检查磁盘空间（Docker 建议至少 10GB）
if ! check_disk_space "/" 10; then
  log_warning "磁盘空间不足，可能影响 Docker 使用。"
fi

# 定义基础镜像源 URL，便于后续统一管理
BASE_MIRROR="https://mirrors.tuna.tsinghua.edu.cn"

# 检查网络连接，避免安装中断
if ! check_network_connectivity "$BASE_MIRROR"; then
  log_warning "网络连接异常，可能影响 Docker 安装。"
fi

# 检查容器环境，提示用户注意
if is_container; then
  log_warning "检测到容器环境，Docker 安装可能受限。"
fi

# 获取系统名称和版本
. /etc/os-release
OS_NAME=$(echo "$NAME" | tr '[:upper:]' '[:lower:]')
VERSION_CODENAME=$(echo "$VERSION_CODENAME")

# 获取 Docker 镜像源地址
get_docker_mirror() {
  echo "${BASE_MIRROR}/docker-ce/linux/debian"
}

log_info "开始安装 Docker CE..."

# 获取镜像源地址
log_info "获取 Docker 镜像源地址..."
DOCKER_MIRROR=$(get_docker_mirror)

# 更新包列表并安装必要软件，确保依赖完整
log_info "更新包列表并安装必要软件..."
apt update
apt install -y ca-certificates curl

# 添加 Docker 官方 GPG 密钥，保障软件包安全
install -m 0755 -d /etc/apt/keyrings
log_info "下载 Docker GPG 密钥..."
curl -fsSL "${DOCKER_MIRROR}/gpg" -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

# 添加 Docker 存储库到 sources.list.d，便于后续升级
log_info "添加 Docker 存储库到 sources.list.d..."
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] ${DOCKER_MIRROR} \
$(. /etc/os-release && echo "${VERSION_CODENAME}") stable" | \
tee /etc/apt/sources.list.d/docker.list > /dev/null

apt update

# 安装 Docker 及相关组件，确保功能完整
log_info "安装 Docker..."
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# 自动将首个普通用户（UID>=1000，排除 nobody）加入 docker 组，便于后续管理
log_info "添加用户到 docker 组..."
first_user=$(awk -F: '$3>=1000 && $1 != "nobody" {print $1}' /etc/passwd | sort | head -n 1)
usermod -aG docker "$first_user"

# 启动并启用 Docker 服务，确保服务可用
if systemctl is-active --quiet docker; then
  log_success "Docker 安装完成，用户 $first_user 已添加到 docker 组。"
else
  systemctl enable --now docker
  log_success "Docker 安装完成，用户 $first_user 已添加到 docker 组，服务已启动并设置为开机自启。"
fi
