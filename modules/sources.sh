#!/bin/bash
# @module: sources
# @name: 配置 APT 软件源
# @category: 基础系统
# @depends:
# 说明：使用 smart library 实现幂等写入，内容未变更时跳过 apt update
# @version: 1.0.0
# @order: 10
# 功能：自动配置 Debian 软件源（DEB822 格式）

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/bootstrap.sh"

# ==================== 常量 ====================

DEB822_PATH="/etc/apt/sources.list.d/debian.sources"
TRADITIONAL_PATH="/etc/apt/sources.list"

# wget/curl 用于镜像站连通性探测；如果不可用则跳过探测，使用默认镜像
# 检测放在 main 中执行（_sources_detect_probe_tool），加载/只读探测阶段不输出日志
_HAS_PROBE_TOOL=1
_sources_detect_probe_tool() {
  if ! command -v wget &>/dev/null && ! command -v curl &>/dev/null; then
    log_warning "无 wget/curl，使用默认镜像"
    _HAS_PROBE_TOOL=0
  fi
  return 0
}

CODENAME=$(get_system_codename)

# 检测 APT 镜像站连通性（基于 urls.sh 的 probe_url，追加 Release 路径验证）
probe_mirror() {
  local mirror_url="$1"
  probe_url "${mirror_url}/debian/dists/${CODENAME}/Release"
}

# 选择可用镜像站
# 返回：选定的镜像站 URL
detect_best_mirror() {
  local selected_mirror=""

  # 无探测工具时，直接使用第一个国内镜像（不探测）
  if [[ "${_HAS_PROBE_TOOL}" -eq 0 ]]; then
    log_info "使用默认镜像"
    echo "${APT_MIRRORS[0]}"
    return 0
  fi

  for mirror in "${APT_MIRRORS[@]}"; do
    if probe_mirror "${mirror}"; then
      selected_mirror="${mirror}"
      break
    fi
  done

  if [[ -z "${selected_mirror}" ]]; then
    log_warning "镜像不可用，使用官方源"
    if probe_mirror "${APT_OFFICIAL_MIRROR}"; then
      selected_mirror="${APT_OFFICIAL_MIRROR}"
    else
      log_warning "官方源连接失败"
      selected_mirror="${APT_OFFICIAL_MIRROR}"
    fi
  fi

  echo "${selected_mirror}"
}

# 备份配置文件到集中备份目录（/var/backups/debnas，见 lib/system/backup.sh；
# 首次被改前的原件另存 original/，不会被后续运行覆盖）
# 参数：$1 - 文件路径；$2 - mv（备份后移除原文件，APT 不再读取）或 cp（仅备份，默认）
# 说明：mv 模式下若集中备份已关闭或失败，回退为同目录改名 <file>.<时间戳>.bak
#       （APT 静默忽略 .bak 后缀），保证原内容不丢失且 APT 不再读取它。
_backup_file() {
  local file="$1"
  local op="${2:-cp}"
  local rc=0 dest

  [[ -n "${file}" && -f "${file}" ]] || return 0
  debnas_backup_file "${file}" || rc=$?
  if [[ "${op}" != "mv" ]]; then
    case "${rc}" in
      0) log_info "已备份 ${file} → ${DEBNAS_BACKUP_ROOT}/${DEBNAS_BACKUP_RUN_ID}${file}" ;;
      1) log_warning "备份失败：${file}" ;;
    esac
    return 0
  fi

  if [[ "${rc}" -eq 0 ]] && rm -f -- "${file}"; then
    log_info "已移除 ${file}（备份 → ${DEBNAS_BACKUP_ROOT}/${DEBNAS_BACKUP_RUN_ID}${file}）"
    return 0
  fi
  dest="${file}.$(date +%Y%m%d%H%M%S).bak"
  mv -- "${file}" "${dest}"
  log_info "已备份 ${file} → ${dest}"
}

# 备份旧配置文件（不覆盖已有的原始 .bak）
backup_config_files() {
  _backup_file "${TRADITIONAL_PATH}" mv
  _backup_file "${DEB822_PATH}" mv
}

# 构建 DEB822 格式的软件源配置内容
# 参数：mirror_url - 镜像站 URL
# 输出：DEB822 配置内容（stdout）
# 说明：sid 不存在 -updates/-backports/-security；testing 不存在 -backports
build_deb822_content() {
  local mirror_url="$1"
  local suites="${CODENAME} ${CODENAME}-updates ${CODENAME}-backports"

  case "${CODENAME}" in
    sid) suites="${CODENAME}" ;;
    testing) suites="${CODENAME} ${CODENAME}-updates" ;;
  esac

  cat <<EOF
# Standard Repository
Types: deb
URIs: ${mirror_url}/debian
Suites: ${suites}
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF

  # sid 无安全更新仓库
  [[ "${CODENAME}" != "sid" ]] || return 0

  cat <<EOF

# Security Repository
Types: deb
URIs: ${mirror_url}/debian-security
Suites: ${CODENAME}-security
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
}

# 执行 apt update 更新软件包列表（带连通性检查）
# 参数：mirror_url - 镜像站 URL
# 返回：0 表示成功，1 表示失败
update_package_lists() {
  local mirror_url="$1"
  local is_offline=false

  # 有探测工具时才进行连通性检查
  if [[ "${_HAS_PROBE_TOOL}" -eq 1 ]] && ! probe_mirror "${mirror_url}"; then
    is_offline=true
  fi

  if [[ "${is_offline}" == "true" ]]; then
    log_warning "已写入源，网络检测失败"
    log_info "请检查网络，恢复后 apt update"
    return 1
  fi

  if ! apt_update_safe; then
    log_warning "apt update 失败"
    return 1
  fi
  return 0
}

# ==================== 只读探测契约（docs/ARCHITECTURE.md §4.5） ====================

# 读取 /etc/os-release 字段（子 shell，不污染全局；只读）
# 参数：$1 - 字段名（ID / VERSION_CODENAME）
_sources_os_field() {
  local field="$1"
  [[ -r /etc/os-release ]] || return 0
  # shellcheck source=/dev/null
  (. /etc/os-release 2>/dev/null && printf '%s' "${!field:-}") || true
}

# 由源地址得到镜像显示名（去掉 /debian 后缀后查 urls.sh 名称表）
# 参数：$1 - URI（如 https://mirrors.ustc.edu.cn/debian）
_sources_mirror_label() {
  local uri="${1%/}" base name
  base="${uri%/debian}"
  name=$(get_mirror_name "$base" 2>/dev/null) || name="$base"
  if [[ "$base" == "$APT_OFFICIAL_MIRROR" || "$base" == "http://deb.debian.org" ]]; then
    name="$APT_OFFICIAL_MIRROR_NAME"
  fi
  printf '%s' "${name:-$uri}"
}

# DEB822 文件第一个启用段落的指定字段值（URIs/Suites）
# 参数：$1 - 字段名（小写），$2 - 文件
_sources_deb822_field() {
  local key="$1" file="$2"
  awk -v k="$key" '
    /^[[:space:]]*#/ { next }
    {
      line = $0; low = tolower(line)
      if (index(low, k ":") == 1) { sub(/^[^:]*:[[:space:]]*/, "", line); print line; exit }
    }' "$file" 2>/dev/null || true
}

# sources.list 中第一条生效 deb 行的 URI（无则空）
_sources_legacy_uri() {
  [[ -r "$TRADITIONAL_PATH" ]] || return 0
  awk '/^[[:space:]]*deb[[:space:]]/ {
         for (i = 2; i <= NF; i++) if ($i ~ /^[a-z]+:\/\//) { print $i; exit }
       }' "$TRADITIONAL_PATH" 2>/dev/null || true
}

# 当前状态：一行 "状态码|说明"（只读、不联网）
module_status() {
  local codename uri suites label legacy_uri
  codename=$(_sources_os_field VERSION_CODENAME)
  legacy_uri=$(_sources_legacy_uri)

  if [[ ! -f "$DEB822_PATH" ]]; then
    if [[ -n "$legacy_uri" ]]; then
      echo "absent|仍为传统 sources.list（$(_sources_mirror_label "$legacy_uri")），未切换 DEB822"
    else
      echo "warn|未找到 debian.sources，sources.list 也无生效条目"
    fi
    return 0
  fi
  if [[ ! -r "$DEB822_PATH" ]]; then
    echo "unknown|无权限读取 ${DEB822_PATH}"
    return 0
  fi

  uri=$(_sources_deb822_field uris "$DEB822_PATH")
  uri="${uri%% *}"
  suites=$(_sources_deb822_field suites "$DEB822_PATH")
  if [[ -z "$uri" ]]; then
    echo "warn|${DEB822_PATH} 中没有 URIs 条目"
    return 0
  fi
  label=$(_sources_mirror_label "$uri")
  if [[ -n "$codename" && " ${suites} " != *" ${codename} "* ]]; then
    echo "warn|DEB822 指向 ${label}，套件（${suites:-空}）与系统 ${codename} 不符"
  elif [[ -n "$legacy_uri" ]]; then
    echo "partial|DEB822 指向 ${label}，但 sources.list 仍有生效条目（可能重复）"
  else
    echo "applied|DEB822 · ${label}"
  fi
}

# 预演：每行 "类型|目标|备注"（只读：不探测镜像站、不 apt update）
module_plan() {
  local IFS=$' \n\t'
  local os_id codename current="" uri mirror
  local -a names=()
  os_id=$(_sources_os_field ID)
  codename=$(_sources_os_field VERSION_CODENAME)
  if [[ "$os_id" != "debian" ]]; then
    echo "info|-|当前系统不是 Debian（${os_id:-未知}），执行时直接跳过，不修改系统"
    return 0
  fi

  for mirror in "${APT_MIRRORS[@]}"; do
    names+=("$(get_mirror_name "$mirror")")
  done
  echo "info|镜像站|执行时联网按顺序探测 ${names[*]}，均不可用则使用 ${APT_OFFICIAL_MIRROR_NAME}"

  if [[ -r "$DEB822_PATH" ]]; then
    uri=$(_sources_deb822_field uris "$DEB822_PATH")
    [[ -n "$uri" ]] && current=$(_sources_mirror_label "${uri%% *}")
  fi
  if [[ -z "$current" ]]; then
    uri=$(_sources_legacy_uri)
    [[ -n "$uri" ]] && current="sources.list：$(_sources_mirror_label "$uri")"
  fi

  echo "write|${DEB822_PATH}|写入 DEB822 源（${codename:-当前版本} 主仓库+安全仓库，main contrib non-free non-free-firmware）；内容未变则跳过；旧文件备份到 /var/backups/debnas/"
  if [[ -f "$TRADITIONAL_PATH" ]]; then
    echo "write|${TRADITIONAL_PATH}|源内容变化时备份到 /var/backups/debnas/ 后移除（备份不可用时同目录改名 .bak）"
  fi
  echo "info|apt update|源内容变化时执行（需联网）"
  echo "risk|APT 软件源|替换系统主软件源（当前：${current:-未配置}）；debian.sources 中的手工修改会被覆盖，sources.list 中的条目停用"
  return 0
}

main() {
  local selected_mirror
  local mirror_name
  local new_content

  if ! verify_debian_12_13_support; then
    return 0
  fi

  _sources_detect_probe_tool

  selected_mirror=$(detect_best_mirror)
  mirror_name=$(get_mirror_name "${selected_mirror}")
  if [[ "${mirror_name}" == "${selected_mirror}" ]]; then
    mirror_name="${APT_OFFICIAL_MIRROR_NAME}"
  fi
  log_success "${mirror_name}"

  # 构建 DEB822 内容，使用 write_file_if_changed 实现幂等写入
  new_content=$(build_deb822_content "${selected_mirror}")
  # 内容变更时 write_file_if_changed 会先把现有 debian.sources 备份到 /var/backups/debnas
  if write_file_if_changed "$DEB822_PATH" "$new_content"; then
    # 内容变更：备份并移除传统 sources.list（避免与 DEB822 源重复，APT 不再读取）
    _backup_file "${TRADITIONAL_PATH}" mv
    log_success "源已写入"
    if ! update_package_lists "${selected_mirror}"; then
      log_warning "apt update 失败，源已写入"
      return 1
    fi
  else
    log_info "源未变更，跳过更新"
  fi

  # 状态由 module-runner.sh 的 run_report() 统一管理
}

# 契约守卫：DEBNAS_MODULE_ACTION=status|plan 时只加载函数供只读探测，不执行 main（docs/ARCHITECTURE.md §4.5）
if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi
