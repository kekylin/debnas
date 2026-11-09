#!/bin/bash
# 功能：APT 操作封装模块
# 说明：提供安全的 apt update/install/remove 操作，内置锁等待和防重复机制

set -euo pipefail
IFS=$'\n\t'

# 依赖: core/logging.sh（由 bootstrap-core.sh 加载）

# ==================== 常量定义 ====================

# APT 锁文件路径
readonly _APT_LISTS_LOCK="/var/lib/apt/lists/lock"
readonly _APT_ARCHIVES_LOCK="/var/lib/dpkg/lock"
readonly _APT_FRONTEND_LOCK="/var/lib/dpkg/lock-frontend"

# 锁等待超时（秒）
readonly APT_LOCK_TIMEOUT="${APT_LOCK_TIMEOUT:-300}"

# ==================== 内部函数 ====================

# 检查 APT 锁是否可用
# 参数：无
# 返回：0 表示可用，1 表示被锁定
_apt_lock_available() {
  if command -v fuser &>/dev/null; then
    # 使用 fuser 检查锁文件是否被占用
    if fuser "${_APT_LISTS_LOCK}" &>/dev/null || \
       fuser "${_APT_ARCHIVES_LOCK}" &>/dev/null || \
       fuser "${_APT_FRONTEND_LOCK}" &>/dev/null; then
      return 1
    fi
  else
    # 回退方案：尝试直接获取锁
    if ! (exec 200>"${_APT_LISTS_LOCK}" && flock -n 200) 2>/dev/null; then
      return 1
    fi
  fi
  return 0
}

# ==================== 公共接口 ====================

# 等待 APT 锁释放
# 参数：$1 - 超时秒数（可选，默认 APT_LOCK_TIMEOUT）
# 返回：0 成功获取锁，1 超时
apt_wait_for_lock() {
  local timeout="${1:-$APT_LOCK_TIMEOUT}"
  local elapsed=0
  local interval=5

  if _apt_lock_available; then
    return 0
  fi

  log_info "APT 锁等待 (${timeout}s)"

  while (( elapsed < timeout )); do
    sleep "$interval"
    elapsed=$(( elapsed + interval ))

    if _apt_lock_available; then
      log_success "APT 锁释放"
      return 0
    fi

    if (( elapsed % 30 == 0 )); then
      log_info "仍在等待 APT 锁...（已等待 ${elapsed} 秒）"
    fi
  done

  log_error "APT 锁超时 (${timeout}s)"
  return 1
}

# 安全执行 apt update（锁等待 + 直接执行）
# 参数：无
# 返回：0 成功，1 失败
apt_update_safe() {
  if ! apt_wait_for_lock; then
    return 1
  fi

  log_info "更新索引..."
  if DEBIAN_FRONTEND=noninteractive apt update -qq >&2; then
    log_success "索引已更新"
    return 0
  else
    log_error "apt update 失败"
    return 1
  fi
}

# 智能安装软件包（过滤已装包 + apt update 去重 + 锁等待）
# 参数：$@ - 包名列表
# 返回：0 成功，1 失败
# 说明：先检测哪些包未安装，只安装缺失的包；全部已装则直接返回
apt_install_packages() {
  if [[ $# -eq 0 ]]; then
    return 0
  fi

  local -a to_install=()
  for pkg in "$@"; do
    if ! dpkg -s "$pkg" &>/dev/null; then
      to_install+=("$pkg")
    fi
  done

  if [[ ${#to_install[@]} -eq 0 ]]; then
    log_info "所有软件包已安装，无需操作：$*"
    return 0
  fi

  log_info "安装 ${to_install[*]}..."
  # apt update 失败不阻断（使用已有索引继续）；否则在 set -e 下会直接退出调用方
  apt_update_safe || log_warning "APT 索引更新失败，使用现有缓存继续安装"
  apt_install_safe "${to_install[@]}"
}

# 软件包是否已安装（只认 dpkg 状态 installed；已卸载仅剩配置文件的不算）
# 说明：只读查询，不打日志，供 module_status / module_plan 使用（替代各模块自写的 _xx_pkg_installed）
# 参数：$1 - 包名（单个）
# 返回：0 已安装，1 未安装或查询失败
pkg_is_installed() {
  local pkg="${1:?pkg_is_installed: 缺少包名}" status=""
  status=$(dpkg-query -W -f='${db:Status-Status}' "$pkg" 2>/dev/null) || return 1
  [[ "$status" == "installed" ]]
}

# 安全安装软件包（锁等待 + 错误提示）
# 参数：$@ - 包名列表
# 返回：0 成功，1 失败
apt_install_safe() {
  if [[ $# -eq 0 ]]; then
    log_error "apt_install_safe: 未指定包名"
    return 1
  fi

  local -a packages=("$@")
  local -a apt_opts=(-y)

  # 等待锁释放
  if ! apt_wait_for_lock; then
    return 1
  fi

  log_info "apt install ${packages[*]}"
  if DEBIAN_FRONTEND=noninteractive apt install "${apt_opts[@]}" "${packages[@]}" >&2; then
    log_success "${packages[*]} 就绪"
    return 0
  else
    log_error "${packages[*]} 安装失败"
    log_error "请检查 APT 源，或手动: apt install ${packages[*]}"
    return 1
  fi
}

# 安全卸载软件包（锁等待 + 清理）
# 参数：$@ - 包名列表
# 返回：0 成功，1 失败
# 选项：通过环境变量控制行为
#   APT_REMOVE_PURGE=1  同时清除配置文件（默认启用）
apt_remove_safe() {
  if [[ $# -eq 0 ]]; then
    log_error "apt_remove_safe: 未指定包名"
    return 1
  fi

  local -a packages=("$@")
  local action="remove"

  # 默认 purge 模式（清除配置文件）
  if [[ "${APT_REMOVE_PURGE:-1}" -eq 1 ]]; then
    action="purge"
  fi

  # 等待锁释放
  if ! apt_wait_for_lock; then
    return 1
  fi

  log_info "卸载 ${packages[*]}..."
  if DEBIAN_FRONTEND=noninteractive apt "${action}" -y "${packages[@]}" >&2; then
    log_success "${packages[*]} 已卸载"

    # 自动清理不再需要的依赖
    apt autoremove -y &>/dev/null || true
    return 0
  else
    log_error "卸载失败：${packages[*]}"
    return 1
  fi
}

