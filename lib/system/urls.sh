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

readonly APT_OFFICIAL_MIRROR="https://deb.debian.org"
readonly APT_OFFICIAL_MIRROR_NAME="Debian 官方"
readonly -a APT_MIRRORS=("${MIRRORS[@]}")

# ==================== Docker 镜像源配置 ====================

readonly DOCKER_OFFICIAL_MIRROR="https://download.docker.com/linux/debian"
readonly -a DOCKER_FALLBACK_MIRRORS=("${MIRRORS[@]}")

# ==================== GitHub 配置 ====================

readonly GITHUB_OFFICIAL_URL="https://github.com"
readonly GITHUB_OFFICIAL_NAME="GitHub 官方"
readonly -a GITHUB_PROXY_ENDPOINTS=(
  "https://ghfast.top"
  "https://hubproxy.jiaozi.live"
  "https://gh-proxy.top"
)

# ==================== 公共接口函数 ====================

# 根据镜像站 URL 获取中文名称
# 设计说明：使用关联数组实现 O(1) 查找，性能优于循环遍历
get_mirror_name() {
  local mirror_url="$1"
  echo "${MIRROR_NAMES[$mirror_url]:-$mirror_url}"
}

# 获取 GitHub 官方地址
get_github_official_url() {
  echo "${GITHUB_OFFICIAL_URL}"
}

# 获取 GitHub 代理镜像站列表
# 设计说明：使用函数封装，便于未来添加过滤或排序逻辑
get_github_proxy_endpoints() {
  local endpoint
  for endpoint in "${GITHUB_PROXY_ENDPOINTS[@]}"; do
    echo "$endpoint"
  done
}
