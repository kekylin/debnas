#!/bin/bash
# @module: docker-ce
# @name: 安装 Docker CE
# @category: 容器管理
# @depends: wget,curl
# @version: 1.0.0
# @order: 50
# 功能：安装 Docker CE 社区版

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/bootstrap.sh"

# 可覆盖路径（测试时可注入临时目录）
DOCKER_KEYRINGS_DIR="${DOCKER_KEYRINGS_DIR:-/etc/apt/keyrings}"
DOCKER_SOURCES_DIR="${DOCKER_SOURCES_DIR:-/etc/apt/sources.list.d}"

# Docker 官方 APT 签名公钥指纹（https://docs.docker.com/engine/install/debian/）
# 无论从哪个镜像站下载 gpg 文件，都必须与此指纹一致才会被信任
DOCKER_GPG_FINGERPRINT="9DC858229FC7DD38854AE2D88D81803C0EBFCD88"

# ==================== 函数定义 ====================

# 从传统 sources.list 提取第一条 deb 行的 URI
# 输出：URI（可能为空）
_legacy_list_first_uri() {
  local legacy_file="${DOCKER_SOURCES_DIR%/*}/sources.list"
  [[ -f "$legacy_file" && -r "$legacy_file" ]] || return 0
  awk '
    /^[[:space:]]*deb[[:space:]]/ && !/^[[:space:]]*#/ {
      for (i = 2; i <= NF; i++) if ($i ~ /^https?:\/\//) { print $i; exit }
    }
  ' "$legacy_file" 2>/dev/null
}

# 从 debian.sources（DEB822）中提取镜像源基础 URL，不存在时回退传统 sources.list
# 输出：镜像源基础 URL（不含路径）
# 返回：0 成功，1 未找到
extract_mirror_from_sources() {
  local sources_file="${DOCKER_SOURCES_DIR}/debian.sources" first_uri=""

  if [[ -f "$sources_file" && -r "$sources_file" ]]; then
    first_uri=$(awk '
      /^[[:space:]]*URIs:[[:space:]]+/ && !/^[[:space:]]*#/ {
        sub(/^[[:space:]]*URIs:[[:space:]]+/, "")
        if ($1 ~ /^https?:\/\//) {
          print $1
          exit
        }
      }
    ' "$sources_file" 2>/dev/null)
  else
    first_uri=$(_legacy_list_first_uri)
  fi

  [[ "$first_uri" =~ ^(https?://[^/]+) ]] || return 1
  echo "${BASH_REMATCH[1]}"
}

# 检测是否为 Debian 官方源
# 参数：$1 - 镜像源基础 URL
# 返回：0 表示是官方源，非 0 表示不是官方源
is_official_debian_source() {
  [[ "${1:-}" =~ ^https?://(deb\.debian\.org|ftp\.debian\.org) ]]
}

# 获取 Docker 镜像源（优先从系统源提取，失败则使用备用源）
# 返回：Docker 镜像源完整 URL（标准输出），日志输出到标准错误
get_docker_mirror() {
  local base_mirror="" docker_mirror="" fallback

  base_mirror=$(extract_mirror_from_sources) || base_mirror=""
  if [[ -z "$base_mirror" ]]; then
    log_warning "无系统镜像配置"
  elif is_official_debian_source "$base_mirror"; then
    log_info "Docker 官方源"
    echo "$DOCKER_OFFICIAL_MIRROR"
    return 0
  else
    docker_mirror="${base_mirror}/docker-ce/linux/debian"
    if probe_url "${docker_mirror}/dists/"; then
      log_info "镜像: ${base_mirror}"
      echo "$docker_mirror"
      return 0
    fi
    log_warning "镜像 ${base_mirror} 不可用"
  fi

  for fallback in "${DOCKER_FALLBACK_MIRRORS[@]}"; do
    docker_mirror="${fallback}/docker-ce/linux/debian"
    if probe_url "${docker_mirror}/dists/"; then
      log_info "镜像: ${fallback}"
      echo "$docker_mirror"
      return 0
    fi
  done

  log_warning "备用镜像不可用"
  if probe_url "$DOCKER_OFFICIAL_MIRROR"; then
    log_info "Docker 官方源"
    echo "$DOCKER_OFFICIAL_MIRROR"
    return 0
  fi
  log_error "Docker 官方源也不可用，无法继续安装"
  return 1
}

# 安装 Docker 前置依赖（ca-certificates、curl；gpg 用于校验 Docker 公钥指纹）
install_docker_prerequisites() {
  log_info "安装依赖..."
  apt_install_packages ca-certificates curl
  command -v gpg &>/dev/null || apt_install_packages gnupg
}

# 写入 Docker APT 软件源（DEB822 格式，幂等）
# 参数：$1 - Docker 镜像源 URL
write_docker_apt_source() {
  local docker_mirror="$1"

  log_info "写入 Docker 源..."

  # 备份旧格式文件（sources.list 格式）
  local old_docker_list="${DOCKER_SOURCES_DIR}/docker.list"
  if [[ -f "$old_docker_list" ]]; then
    log_info "旧源文件已备份"
    # 集中备份到 /var/backups/debnas 后移除；备份失败则改名为 APT 会忽略的 .bak
    if debnas_backup_file "$old_docker_list"; then
      rm -f -- "$old_docker_list"
    else
      mv -- "$old_docker_list" "${old_docker_list}.$(date +%Y%m%d%H%M%S).bak"
    fi
  fi

  # 使用 DEB822 格式写入软件源配置（幂等：内容未变则跳过）
  local codename
  codename=$(get_system_codename)
  local docker_sources_content="Types: deb"$'\n'"URIs: ${docker_mirror}"$'\n'"Suites: ${codename}"$'\n'"Components: stable"$'\n'"Signed-By: /etc/apt/keyrings/docker.asc"
  local rc=0
  write_file_if_changed "${DOCKER_SOURCES_DIR}/docker.sources" "$docker_sources_content" || rc=$?
  if [[ $rc -eq 2 ]]; then
    log_error "写入 Docker 源失败"
    exit "${ERROR_GENERAL}"
  fi

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
# 说明：可在 /etc/debnas/debnas.conf 设置 add_user_to_docker=0 关闭（默认 1）
add_user_to_docker_group() {
  local first_user="$1"

  if ! config_get_bool add_user_to_docker 1; then
    log_info "已配置 add_user_to_docker=0，跳过 docker 组"
  elif [[ -n "$first_user" ]]; then
    usermod -aG docker "$first_user"
    log_warning "已将用户 ${first_user} 加入 docker 组：docker 组成员等同于 root 权限（可挂载宿主机任意目录）"
    log_warning "如不需要请执行：gpasswd -d ${first_user} docker；并在 /etc/debnas/debnas.conf 设置 add_user_to_docker=0"
  else
    log_info "无普通用户，跳过 docker 组"
  fi
  log_success "Docker CE 就绪"
}

# ==================== 只读探测契约（docs/ARCHITECTURE.md §4.5） ====================

# 当前状态：一行 "状态码|说明"（只读、不联网）
module_status() {
  if pkg_is_installed docker-ce; then
    local ver
    ver=$(dpkg-query -W -f='${Version}' docker-ce 2>/dev/null) || ver=""
    ver="${ver#*:}"
    ver="${ver%%[-~]*}"
    if systemctl is-active --quiet docker 2>/dev/null; then
      echo "running|Docker ${ver:-CE} 运行中"
    else
      echo "warn|Docker ${ver:-CE} 已安装，docker 服务未运行"
    fi
  elif command -v docker &>/dev/null; then
    echo "partial|检测到非 docker-ce 版 docker（如 docker.io），执行时会安装 docker-ce"
  else
    echo "absent|未安装"
  fi
}

# 预演：每行 "类型|目标|备注"（只读：不探测镜像站、不 apt update）
module_plan() {
  local IFS=$' \n\t'
  local -a want=(ca-certificates curl) missing=()
  local pkg
  command -v gpg &>/dev/null || want+=(gnupg)
  if command -v docker &>/dev/null; then
    echo "info|docker-ce docker-ce-cli containerd.io|已安装 docker，执行时 apt update 后尝试升级"
  else
    want+=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
  fi
  for pkg in "${want[@]}"; do
    pkg_is_installed "$pkg" || missing+=("$pkg")
  done
  [[ ${#missing[@]} -gt 0 ]] && echo "pkg|${missing[*]}|apt 安装"

  echo "info|镜像源|执行时按系统源探测镜像站，失败回退备用镜像/官方源（需联网）"
  echo "write|${DOCKER_KEYRINGS_DIR}/docker.asc|下载 GPG 公钥，指纹校验通过后原子替换（内容未变则跳过）"
  if [[ -f "${DOCKER_SOURCES_DIR}/docker.list" ]]; then
    echo "write|${DOCKER_SOURCES_DIR}/docker.list|旧格式源集中备份到 /var/backups/debnas 后移除"
  fi
  echo "write|${DOCKER_SOURCES_DIR}/docker.sources|DEB822 源（内容未变则跳过），随后 apt update"
  echo "service|docker|启动并设为开机自启"

  local first_user
  first_user=$(get_primary_user)
  if [[ -n "$first_user" ]] && config_get_bool add_user_to_docker 1; then
    echo "user|${first_user}|加入 docker 组"
    echo "risk|docker 组|docker 组成员等同 root 权限（可在 debnas.conf 设 add_user_to_docker=0 关闭）"
  fi
  if systemctl is-active --quiet firewalld 2>/dev/null; then
    echo "risk|防火墙|容器发布的端口由 Docker 自行放行，不受 firewalld public 区限制"
  fi
}

# ==================== 主入口 ====================

main() {
  local step=0 total=7

  ui_progress_step $((++step)) "$total" "检测镜像源"
  local docker_mirror
  docker_mirror=$(get_docker_mirror) || {
    log_error "无法获取 Docker 源"
    exit "${ERROR_DEPENDENCY}"
  }

  local first_user
  first_user=$(get_primary_user)

  ui_progress_step $((++step)) "$total" "安装系统依赖"
  install_docker_prerequisites

  ui_progress_step $((++step)) "$total" "下载 GPG 签名密钥"
  log_info "获取 GPG 密钥..."
  keyring_install_verified "${docker_mirror}/gpg" "$DOCKER_GPG_FINGERPRINT" "${DOCKER_KEYRINGS_DIR}/docker.asc" \
    --label Docker || exit "${ERROR_DEPENDENCY}"

  ui_progress_step $((++step)) "$total" "配置 APT 软件源"
  write_docker_apt_source "$docker_mirror"

  ui_progress_step $((++step)) "$total" "安装 Docker 组件"
  install_docker_packages

  ui_progress_step $((++step)) "$total" "启动 Docker 服务"
  service_ensure docker started
  service_ensure docker enabled

  ui_progress_step $((++step)) "$total" "添加用户到 docker 组"
  add_user_to_docker_group "$first_user"

  ui_progress_step "$step" "$total" "Docker CE 安装完成" "done"
  local ver
  ver=$(docker --version 2>/dev/null) || ver=""
  [[ "$ver" =~ [0-9]+\.[0-9]+\.[0-9]+ ]] && ver="${BASH_REMATCH[0]}" || ver=""
  log_info "Docker ${ver}"
}

# 契约守卫：DEBNAS_MODULE_ACTION=status|plan 时只加载函数供只读探测，不执行 main（docs/ARCHITECTURE.md §4.5）
if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi
