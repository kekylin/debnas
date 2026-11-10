#!/bin/bash
# 功能：统一 URL 配置库
# 说明：统一管理软件源、镜像站、服务端点等 URL 配置，供各模块引用
# 依赖：Bash 4.0 或更高版本（需要关联数组支持）

set -euo pipefail
IFS=$'\n\t'

# ==================== 通用镜像站配置（基础数据） ====================

# 镜像站列表（按优先级排序）：URL=中文名称
# 设计说明：使用 = 作为分隔符而非 |，避免与 URL 查询参数中的 | 字符冲突
readonly MIRROR_LIST=(
  "https://mirrors.cernet.edu.cn=校园网联合镜像站"
  "https://mirrors.tuna.tsinghua.edu.cn=清华大学开源软件镜像站"
  "https://mirrors.ustc.edu.cn=中国科学技术大学开源软件镜像站"
  "https://mirrors.aliyun.com=阿里云开源镜像站"
  "https://mirrors.huaweicloud.com=华为云开源镜像站"
)

# 初始化镜像站数据结构
# 设计说明：将 MIRROR_LIST 解析为数组和关联数组，实现 O(1) 时间复杂度的 URL 到名称映射
init_mirror_data() {
  local mirror_entry mirror_url mirror_name

  declare -g -A MIRROR_NAMES=()
  declare -g -a MIRRORS=()

  for mirror_entry in "${MIRROR_LIST[@]}"; do
    mirror_url="${mirror_entry%%=*}"
    mirror_name="${mirror_entry#*=}"
    MIRRORS+=("$mirror_url")
    MIRROR_NAMES["$mirror_url"]="$mirror_name"
  done
}

init_mirror_data
readonly -a MIRRORS
readonly -A MIRROR_NAMES

# ==================== Debian APT 镜像源配置 ====================

# shellcheck disable=SC2034  # 被 modules/sources.sh、modules/sys-check.sh 使用
readonly APT_OFFICIAL_MIRROR="https://deb.debian.org"
# shellcheck disable=SC2034  # 被 modules/sources.sh、modules/sys-check.sh 使用
readonly APT_OFFICIAL_MIRROR_NAME="Debian 官方"
# shellcheck disable=SC2034  # 被 modules/sources.sh、modules/sys-check.sh 使用
readonly -a APT_MIRRORS=("${MIRRORS[@]}")

# ==================== Docker 镜像源配置 ====================

# Docker 官方下载地址（用于安装 Docker）
# shellcheck disable=SC2034  # 被 modules/docker-ce.sh 使用
readonly DOCKER_OFFICIAL_MIRROR="https://download.docker.com/linux/debian"
# shellcheck disable=SC2034  # 被 modules/docker-ce.sh 使用
readonly -a DOCKER_FALLBACK_MIRRORS=("${MIRRORS[@]}")

# Docker 镜像加速地址（用于配置 daemon.json 的 registry-mirrors）
# shellcheck disable=SC2034  # 被 modules/docker-mirror.sh 使用
readonly -a DOCKER_REGISTRY_MIRRORS=(
  "https://docker.m.ixdev.cn"
  "https://docker.1ms.run"
  "https://docker.1panel.live"
)

# ==================== 公共接口函数 ====================

# 根据镜像站 URL 获取中文名称
# 设计说明：使用关联数组实现 O(1) 查找，性能优于循环遍历
get_mirror_name() {
  local mirror_url="$1"
  echo "${MIRROR_NAMES[$mirror_url]:-$mirror_url}"
}

# ==================== 网络探测函数 ====================

# 探测 URL 连通性（通用函数）
# 参数：$1 - 探测目标 URL
# 返回：0 表示可达，1 表示不可达
probe_url() {
  local target_url="$1"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --head --max-time 5 --connect-timeout 5 \
      -o /dev/null "${target_url}" 2>/dev/null
  elif command -v wget >/dev/null 2>&1; then
    wget --spider --quiet --timeout=5 --tries=1 \
      "${target_url}" 2>/dev/null
  else
    return 1
  fi
}
