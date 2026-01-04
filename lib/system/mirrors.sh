#!/bin/bash
# 功能：通用镜像站配置库
# 说明：统一管理镜像站列表，供 Debian APT、Docker 等引用
# 要求：Bash 4.0 或更高版本（需要关联数组支持）

set -euo pipefail
IFS=$'\n\t'

# ==================== 镜像站配置源数据 ====================

# 镜像站列表（按优先级排序）：URL|中文名称
readonly MIRROR_LIST=(
  "https://mirrors.cernet.edu.cn|校园网联合镜像站"
  "https://mirrors.tuna.tsinghua.edu.cn|清华大学开源软件镜像站"
  "https://mirrors.ustc.edu.cn|中国科学技术大学开源软件镜像站"
  "https://mirrors.aliyun.com|阿里云开源镜像站"
  "https://mirrors.huaweicloud.com|华为云开源镜像站"
)

# ==================== 初始化函数 ====================

# 初始化镜像站数据结构
# 说明：从 MIRROR_LIST 生成 MIRRORS 数组和 MIRROR_NAMES 关联数组
_init_mirror_data() {
  local entry url name

  declare -g -A MIRROR_NAMES=()
  declare -g -a MIRRORS=()

  for entry in "${MIRROR_LIST[@]}"; do
    url="${entry%%|*}"
    name="${entry#*|}"
    MIRRORS+=("$url")
    MIRROR_NAMES["$url"]="$name"
  done
}

# ==================== 初始化执行 ====================

_init_mirror_data
readonly -a MIRRORS
readonly -A MIRROR_NAMES

# ==================== Debian APT 镜像源配置 ====================

# APT 镜像站列表（引用通用镜像站配置）
readonly -a APT_MIRRORS=("${MIRRORS[@]}")

# APT 官方镜像站
readonly APT_OFFICIAL_MIRROR="https://deb.debian.org"
readonly APT_OFFICIAL_MIRROR_NAME="Debian 官方"

# ==================== Docker 镜像源配置 ====================

# Docker 备用镜像源列表（引用通用镜像站配置）
readonly -a DOCKER_FALLBACK_MIRRORS=("${MIRRORS[@]}")

# Docker 官方源
readonly DOCKER_OFFICIAL_MIRROR="https://download.docker.com/linux/debian"

# ==================== 公共接口函数 ====================

# 根据镜像站 URL 获取中文名称
# 参数：$1 - 镜像站 URL
# 返回：中文名称，如果不存在则返回 URL
get_mirror_name() {
  local mirror_url="$1"
  echo "${MIRROR_NAMES[$mirror_url]:-$mirror_url}"
}
