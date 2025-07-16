#!/bin/bash
# 功能：安装 Docker CE 社区版
# 参数：无
# 返回值：0成功，非0失败
# 作者：kekylin
# 创建时间：2025-07-11
# 修改时间：2025-07-12

set -euo pipefail
IFS=$'\n\t'

# 加载公共模块
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/core/constants.sh"
source "${SCRIPT_DIR}/lib/core/logging.sh"
source "${SCRIPT_DIR}/lib/system/dependency.sh"
source "${SCRIPT_DIR}/lib/system/utils.sh"

# 检查依赖
REQUIRED_CMDS=(apt curl)
if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
  log_error "依赖缺失，请先安装 apt 和 curl"
  exit "${ERROR_DEPENDENCY}"
fi

# 检查系统兼容性
if ! verify_system_support; then
  exit "${ERROR_UNSUPPORTED_OS}"
fi

# Docker 安装前的系统检查
log_info "执行 Docker 安装前系统检查..."

# 检查内存（Docker 建议至少 1GB）
if ! check_memory_requirements 1024; then
  log_warn "内存不足，Docker 可能无法正常运行"
fi

# 检查磁盘空间（Docker 建议至少 10GB）
if ! check_disk_space "/" 10; then
  log_warn "磁盘空间不足，可能影响 Docker 使用"
fi

# 定义基础镜像源URL（提前）
BASE_MIRROR="https://mirrors.tuna.tsinghua.edu.cn"

# 检查网络连接
if ! check_network_connectivity "$BASE_MIRROR"; then
  log_warn "网络连接异常，可能影响 Docker 安装"
fi

# 检查容器环境
if is_container; then
  log_warn "检测到容器环境，Docker 安装可能受限"
fi

# 检查系统版本并获取系统名称
. /etc/os-release
OS_NAME=$(echo "$NAME" | tr '[:upper:]' '[:lower:]')
VERSION_CODENAME=$(echo "$VERSION_CODENAME")

# 定义镜像源地址函数
get_docker_mirror() {
  echo "${BASE_MIRROR}/docker-ce/linux/debian"
}

log_info "开始安装 Docker CE ..."

# 获取镜像源地址
log_info "获取 Docker 镜像源地址..."
DOCKER_MIRROR=$(get_docker_mirror)

# 更新包列表并安装必要软件
log_info "更新包列表并安装必要软件..."
apt update
apt install -y ca-certificates curl

# 添加 Docker 的官方 GPG 密钥
install -m 0755 -d /etc/apt/keyrings
log_info "下载 Docker GPG 密钥..."
curl -fsSL "${DOCKER_MIRROR}/gpg" -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

# 将存储库添加到 Apt
log_info "添加 Docker 存储库到 sources.list.d..."
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] ${DOCKER_MIRROR} \
$(. /etc/os-release && echo "${VERSION_CODENAME}") stable" | \
tee /etc/apt/sources.list.d/docker.list > /dev/null

apt update

# 安装 Docker
log_info "安装 Docker..."
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# 添加第一个创建的用户（ID>=1000）至docker组
log_info "添加用户到 docker 组..."
first_user=$(awk -F: '$3>=1000 && $1 != "nobody" {print $1}' /etc/passwd | sort | head -n 1)
usermod -aG docker "$first_user"

# 启动并启用 Docker 服务
if systemctl is-active --quiet docker; then
  log_success "Docker 安装完成，用户 $first_user 已添加到 docker 组"
else
  systemctl enable --now docker
  log_success "Docker 安装完成，用户 $first_user 已添加到 docker 组，服务已启动并设置为开机自启"
fi
