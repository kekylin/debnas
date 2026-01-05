#!/bin/bash
# 功能：系统版本检查工具库

set -euo pipefail
IFS=$'\n\t'

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$LIB_DIR/core/logging.sh"

# ==================== 底层 OS 信息获取函数 ====================

# 获取操作系统 ID
# 参数：无
# 返回：操作系统 ID 字符串（小写）
_get_os_id() {
  local os_id

  if command -v lsb_release >/dev/null 2>&1; then
    os_id=$(lsb_release -is)
  else
    if [[ -f /etc/os-release ]]; then
      # shellcheck source=/dev/null
      . /etc/os-release
      os_id="${ID:-}"
    else
      return 1
    fi
  fi

  echo "${os_id,,}"
}

# 获取系统代号
# 参数：无
# 返回：系统代号字符串
_get_os_codename() {
  if command -v lsb_release >/dev/null 2>&1; then
    lsb_release -cs
  else
    if [[ -f /etc/os-release ]]; then
      # shellcheck source=/dev/null
      . /etc/os-release
      echo "${VERSION_CODENAME:-}"
    else
      return 1
    fi
  fi
}

# 获取系统版本号
# 参数：无
# 返回：系统版本号字符串
_get_os_version_id() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    echo "${VERSION_ID:-}"
  else
    return 1
  fi
}

# ==================== 版本验证函数 ====================

# 验证系统是否为 Debian
# 参数：无
# 返回：0 是 Debian，非 0 不是
_verify_os_is_debian() {
  local os_id
  os_id=$(_get_os_id)

  if [[ "$os_id" != "debian" ]]; then
    return 1
  fi

  return 0
}

# 检查 codename 是否为开发版本
# 参数：$1 - 系统代号
# 返回：0 是开发版本，非 0 不是
_is_development_codename() {
  local codename="$1"
  case "$codename" in
    "sid" | "testing")
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# 验证 Debian 最小版本（支持 sid 和 testing）
# 参数：$1 - 最小版本代号（如 "bookworm"）
# 返回：0 满足要求，非 0 不满足
_verify_debian_min_codename() {
  local min_codename="$1"
  local current_codename
  local codename_order=("bullseye" "bookworm" "trixie" "forky")
  local min_index=-1
  local current_index=-1

  current_codename=$(_get_os_codename)

  if _is_development_codename "$current_codename"; then
    return 0
  fi

  for i in "${!codename_order[@]}"; do
    if [[ "${codename_order[$i]}" == "$min_codename" ]]; then
      min_index=$i
    fi
    if [[ "${codename_order[$i]}" == "$current_codename" ]]; then
      current_index=$i
    fi
  done

  if [[ $min_index -ge 0 ]] && [[ $current_index -ge 0 ]]; then
    if [[ $current_index -ge $min_index ]]; then
      return 0
    else
      return 1
    fi
  fi

  local version_id
  version_id=$(_get_os_version_id)

  if [[ "$version_id" =~ ^([0-9]+) ]]; then
    local major_version="${BASH_REMATCH[1]}"
    local min_major=12

    case "$min_codename" in
      "bookworm")
        min_major=12
        ;;
      "trixie")
        min_major=13
        ;;
      *)
        min_major=12
        ;;
    esac

    if [[ $major_version -ge $min_major ]]; then
      return 0
    else
      return 1
    fi
  fi

  return 1
}

# ==================== 公共接口函数 ====================

# 验证系统支持，支持 Debian 12 及以上版本（包括 sid 和 testing）
# 参数：无
# 返回：0 成功，非 0 失败
verify_system_support() {
  if ! _verify_os_is_debian; then
    local os_id
    os_id=$(_get_os_id)
    log_error "不支持的操作系统 (${os_id})，需要 Debian 12 或更高版本"
    return 1
  fi

  if ! _verify_debian_min_codename "bookworm"; then
    local codename version_id
    codename=$(_get_os_codename)
    version_id=$(_get_os_version_id)
    log_error "Debian 版本不满足要求 (${codename:-${version_id}})，需要 Debian 12 (bookworm) 或更高版本"
    return 1
  fi

  return 0
}

# 验证系统支持，支持 Debian 12 及以上版本（包括 sid 和 testing）
# 参数：无
# 返回：0 成功，非 0 失败
verify_debian_12_13_support() {
  if ! _verify_os_is_debian; then
    local os_id
    os_id=$(_get_os_id)
    log_error "不支持的操作系统 (${os_id})，需要 Debian 12 或更高版本"
    return 1
  fi

  local codename
  codename=$(_get_os_codename)

  if _is_development_codename "$codename"; then
    log_info "检测到 Debian 开发版本: $codename"
    return 0
  fi

  case "$codename" in
    "bookworm" | "trixie" | "forky")
      log_info "检测到支持的 Debian 版本: $codename"
      return 0
      ;;
    *)
      if _verify_debian_min_codename "bookworm"; then
        log_info "检测到支持的 Debian 版本: $codename"
        return 0
      else
        log_error "不支持的 Debian 版本代号: ${codename}，需要 Debian 12 (bookworm) 或更高版本"
        return 1
      fi
      ;;
  esac
}

# 获取系统代号
# 参数：无
# 返回：系统代号字符串
get_system_codename() {
  _get_os_codename
}

# 检查系统代号是否支持
# 参数：$1 - 系统代号
# 返回：0 支持，非 0 不支持
is_supported_codename() {
  local codename="$1"

  if _is_development_codename "$codename"; then
    return 0
  fi

  case "$codename" in
    "bookworm" | "trixie" | "forky")
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# 获取系统名称
# 参数：无
# 返回：系统名称字符串
get_system_name() {
  if command -v lsb_release >/dev/null 2>&1; then
    lsb_release -is
  else
    if [[ -f /etc/os-release ]]; then
      # shellcheck source=/dev/null
      . /etc/os-release
      echo "${NAME:-}"
    else
      echo "未知"
    fi
  fi
}

# 获取系统版本
# 参数：无
# 返回：系统版本字符串
get_system_version() {
  local version_id
  version_id=$(_get_os_version_id)

  if [[ -n "$version_id" ]]; then
    echo "$version_id"
  elif [[ -f /etc/debian_version ]]; then
    cat /etc/debian_version
  else
    echo "未知"
  fi
}

# 获取系统架构
# 参数：无
# 返回：系统架构字符串（如 x86_64、arm64 等）
get_system_architecture() {
  uname -m 2>/dev/null || echo "未知"
}

# 验证系统架构是否支持
# 参数：$1 - 支持的架构列表（空格分隔，如 "x86_64 amd64"）
# 返回：0 支持，非 0 不支持
verify_architecture_support() {
  local supported_archs="$1"
  local current_arch
  current_arch=$(get_system_architecture)

  if [[ -z "$supported_archs" ]]; then
    return 1
  fi

  for arch in $supported_archs; do
    if [[ "$current_arch" == "$arch" ]]; then
      return 0
    fi
  done

  return 1
}
