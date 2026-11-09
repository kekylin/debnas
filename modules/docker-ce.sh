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

# 检测镜像站连通性（基于 urls.sh 的 probe_url）
probe_mirror() {
  probe_url "$1"
}

# 从传统 sources.list 提取镜像源基础 URL（deb [opts] URI suite ...）
# 返回：镜像源基础 URL（不含路径），失败返回非 0
extract_mirror_from_legacy_list() {
  local legacy_file="${DOCKER_SOURCES_DIR%/*}/sources.list"
  local legacy_uri

  [[ -f "$legacy_file" && -r "$legacy_file" ]] || return 1
  legacy_uri=$(awk '
    /^[[:space:]]*deb[[:space:]]/ && !/^[[:space:]]*#/ {
      for (i = 2; i <= NF; i++) if ($i ~ /^https?:\/\//) { print $i; exit }
    }
  ' "$legacy_file" 2>/dev/null)
  if [[ "$legacy_uri" =~ ^(https?://[^/]+) ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

# 从 debian.sources（DEB822）中提取镜像源基础 URL，不存在时回退传统 sources.list
# 返回：镜像源基础 URL（不含路径），失败返回非 0
extract_mirror_from_sources() {
  local sources_file="${DOCKER_SOURCES_DIR}/debian.sources"

  if [[ ! -f "$sources_file" ]] || [[ ! -r "$sources_file" ]]; then
    extract_mirror_from_legacy_list
    return
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
  install -m 0755 -d "$DOCKER_KEYRINGS_DIR"
  # gpg 用于校验 Docker 公钥指纹
  command -v gpg &>/dev/null || apt_install_packages gnupg
}

# 校验公钥文件：只允许包含一个主密钥，且指纹等于 Docker 官方指纹
# 参数：$1 - 公钥文件路径
# 返回：0 校验通过，1 失败
verify_docker_gpg_fingerprint() {
  local key_file="$1"
  local gpg_home fprs

  gpg_home=$(create_temp_dir "docker-gpg") || return 1
  # --with-colons 输出中 pub 行之后的第一条 fpr 为主密钥指纹（跳过子密钥）
  fprs=$(gpg --homedir "$gpg_home" --batch --quiet --show-keys --with-colons "$key_file" 2>/dev/null \
    | awk -F: '$1 == "pub" { want = 1; next } $1 == "fpr" && want { print $10; want = 0 }') || return 1

  if [[ "$fprs" != "$DOCKER_GPG_FINGERPRINT" ]]; then
    log_error "Docker GPG 公钥指纹不匹配（期望 ${DOCKER_GPG_FINGERPRINT}，实际 ${fprs:-无}）"
    return 1
  fi
  return 0
}

# 下载 Docker GPG 签名密钥（含 3 次重试）
# 参数：$1 - Docker 镜像源 URL
download_docker_gpg_key() {
  local docker_mirror="$1"

  log_info "获取 GPG 密钥..."

  local gpg_downloaded=0
  local max_retries=3
  local retry_count=0
  local tmp_key
  tmp_key=$(create_temp_file "docker-gpg" ".asc") || exit "${ERROR_DEPENDENCY}"

  # 先下载到临时文件，校验指纹后再原子替换，失败时不破坏已有 keyring
  while [[ $retry_count -lt $max_retries ]]; do
    if curl -fsSL --max-time 30 --connect-timeout 10 "${docker_mirror}/gpg" -o "$tmp_key" 2>/dev/null; then
      if [[ -s "$tmp_key" ]] && grep -q "BEGIN PGP PUBLIC KEY BLOCK" "$tmp_key" 2>/dev/null \
        && verify_docker_gpg_fingerprint "$tmp_key"; then
        install -m 0644 "$tmp_key" "${DOCKER_KEYRINGS_DIR}/docker.asc"
        gpg_downloaded=1
        break
      fi
    fi
    ((retry_count++)) || true
    if [[ $retry_count -lt $max_retries ]]; then
      log_warning "GPG 密钥下载失败，重试中 ($retry_count/$max_retries)"
      sleep 2
    fi
  done

  if [[ $gpg_downloaded -eq 0 ]]; then
    log_error "GPG 密钥下载失败"
    exit "${ERROR_DEPENDENCY}"
  fi

  chmod a+r "${DOCKER_KEYRINGS_DIR}/docker.asc"
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
  write_file_if_changed "${DOCKER_SOURCES_DIR}/docker.sources" "$docker_sources_content" || true

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

  # 可在 /etc/debnas/debnas.conf 设置 add_user_to_docker=0 关闭（默认 1，保持原有用法）
  if [[ "$(config_read "global" "add_user_to_docker" "1" 2>/dev/null || echo 1)" == "0" ]]; then
    log_info "已配置 add_user_to_docker=0，跳过 docker 组"
    log_success "Docker CE 就绪"
  elif [[ -n "$first_user" ]]; then
    usermod -aG docker "$first_user"
    log_warning "已将用户 ${first_user} 加入 docker 组：docker 组成员等同于 root 权限（可挂载宿主机任意目录）"
    log_warning "如不需要请执行：gpasswd -d ${first_user} docker；并在 /etc/debnas/debnas.conf 设置 add_user_to_docker=0"
    log_success "Docker CE 就绪"
  else
    log_info "无普通用户，跳过 docker 组"
    log_success "Docker CE 就绪"
  fi
}

# ==================== 只读探测契约（docs/ARCHITECTURE.md §4.5） ====================

# 包是否已安装（只读查询 dpkg 数据库）
_docker_pkg_installed() {
  [[ "$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null)" == "installed" ]]
}

# 当前状态：一行 "状态码|说明"（只读、不联网）
module_status() {
  if _docker_pkg_installed docker-ce; then
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
    _docker_pkg_installed "$pkg" || missing+=("$pkg")
  done
  [[ ${#missing[@]} -gt 0 ]] && echo "pkg|${missing[*]}|apt 安装"

  echo "info|镜像源|执行时按系统源探测镜像站，失败回退备用镜像/官方源（需联网）"
  echo "write|${DOCKER_KEYRINGS_DIR}/docker.asc|下载 GPG 公钥，指纹校验通过后覆盖写入"
  if [[ -f "${DOCKER_SOURCES_DIR}/docker.list" ]]; then
    echo "write|${DOCKER_SOURCES_DIR}/docker.list|旧格式源集中备份到 /var/backups/debnas 后移除"
  fi
  echo "write|${DOCKER_SOURCES_DIR}/docker.sources|DEB822 源（内容未变则跳过），随后 apt update"
  echo "service|docker|启动并设为开机自启"

  local first_user add_flag
  first_user=$(get_first_regular_user 2>/dev/null) || first_user=""
  add_flag=$(config_read "global" "add_user_to_docker" "1" 2>/dev/null) || add_flag="1"
  if [[ "$add_flag" != "0" && -n "$first_user" ]]; then
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
  local DOCKER_MIRROR
  DOCKER_MIRROR=$(get_docker_mirror) || {
    log_error "无法获取 Docker 源"
    exit "${ERROR_DEPENDENCY}"
  }

  local first_user
  first_user=$(get_first_regular_user)

  ui_progress_step $((++step)) "$total" "安装系统依赖"
  install_docker_prerequisites

  ui_progress_step $((++step)) "$total" "下载 GPG 签名密钥"
  download_docker_gpg_key "$DOCKER_MIRROR"

  ui_progress_step $((++step)) "$total" "配置 APT 软件源"
  write_docker_apt_source "$DOCKER_MIRROR"

  ui_progress_step $((++step)) "$total" "安装 Docker 组件"
  install_docker_packages

  ui_progress_step $((++step)) "$total" "启动 Docker 服务"
  service_ensure docker started
  service_ensure docker enabled

  ui_progress_step $((++step)) "$total" "添加用户到 docker 组"
  add_user_to_docker_group "$first_user"

  ui_progress_step "$step" "$total" "Docker CE 安装完成" "done"
  log_info "Docker $(docker --version 2>/dev/null | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
}

# 契约守卫：DEBNAS_MODULE_ACTION=status|plan 时只加载函数供只读探测，不执行 main（docs/ARCHITECTURE.md §4.5）
if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi
