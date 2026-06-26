#!/bin/bash
# 功能：APT 操作封装模块
# 说明：提供安全的 apt update/install/remove 操作，内置锁等待和防重复机制

set -euo pipefail
IFS=$'\n\t'

# 获取库文件目录
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$LIB_DIR/core/logging.sh"

# ==================== 常量定义 ====================

# APT 锁文件路径
readonly _APT_LISTS_LOCK="/var/lib/apt/lists/lock"
readonly _APT_ARCHIVES_LOCK="/var/lib/dpkg/lock"
readonly _APT_FRONTEND_LOCK="/var/lib/dpkg/lock-frontend"

# 锁等待超时（秒）
readonly APT_LOCK_TIMEOUT="${APT_LOCK_TIMEOUT:-300}"

# 全局防重复标志
declare -g _DEBNAS_APT_UPDATED="${_DEBNAS_APT_UPDATED:-0}"

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

  log_info "检测到 APT 锁被占用，等待释放（最长 ${timeout} 秒）..."

  while (( elapsed < timeout )); do
    sleep "$interval"
    elapsed=$(( elapsed + interval ))

    if _apt_lock_available; then
      log_success "APT 锁已释放"
      return 0
    fi

    if (( elapsed % 30 == 0 )); then
      log_info "仍在等待 APT 锁...（已等待 ${elapsed} 秒）"
    fi
  done

  log_error "等待 APT 锁超时（${timeout} 秒），请检查是否有其他 apt 进程正在运行"
  log_error "可尝试：sudo killall apt apt-get dpkg 或等待其完成"
  return 1
}

# 安全执行 apt update（防重复 + 锁等待）
# 参数：无
# 返回：0 成功，1 失败
# 说明：同一会话内多次调用只执行一次（通过 _DEBNAS_APT_UPDATED 标志控制）
apt_update_safe() {
  # 防重复：同一会话已更新过则跳过
  if [[ "${_DEBNAS_APT_UPDATED}" -eq 1 ]]; then
    log_debug "apt update 已在本次会话中执行过，跳过"
    return 0
  fi

  # 等待锁释放
  if ! apt_wait_for_lock; then
    return 1
  fi

  log_info "正在更新软件包列表..."
  if apt update 2>&1; then
    export _DEBNAS_APT_UPDATED=1
    log_success "软件包列表更新完成"
    return 0
  else
    log_error "apt update 执行失败"
    return 1
  fi
}

# 安全安装软件包（锁等待 + 错误提示）
# 参数：$@ - 包名列表
# 返回：0 成功，1 失败
# 选项：通过环境变量控制行为
#   APT_INSTALL_NO_RECOMMENDS=1  不安装推荐包
apt_install_safe() {
  if [[ $# -eq 0 ]]; then
    log_error "apt_install_safe: 未指定要安装的包名"
    return 1
  fi

  local -a packages=("$@")
  local -a apt_opts=(-y)

  # 默认不安装推荐包（精简安装）
  if [[ "${APT_INSTALL_NO_RECOMMENDS:-1}" -eq 1 ]]; then
    apt_opts+=(--no-install-recommends)
  fi

  # 等待锁释放
  if ! apt_wait_for_lock; then
    return 1
  fi

  log_info "正在安装：${packages[*]}"
  if DEBIAN_FRONTEND=noninteractive apt install "${apt_opts[@]}" "${packages[@]}" 2>&1; then
    log_success "安装完成：${packages[*]}"
    return 0
  else
    log_error "安装失败：${packages[*]}"
    log_error "请检查软件源配置或手动执行: apt install ${packages[*]}"
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
    log_error "apt_remove_safe: 未指定要卸载的包名"
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

  log_info "正在卸载：${packages[*]}"
  if DEBIAN_FRONTEND=noninteractive apt "${action}" -y "${packages[@]}" 2>&1; then
    log_success "卸载完成：${packages[*]}"

    # 自动清理不再需要的依赖
    apt autoremove -y &>/dev/null || true
    return 0
  else
    log_error "卸载失败：${packages[*]}"
    return 1
  fi
}

# 重置 apt update 防重复标志
# 参数：无
# 说明：用于需要强制重新执行 apt update 的场景（如切换镜像源后）
apt_reset_update_flag() {
  export _DEBNAS_APT_UPDATED=0
  log_debug "apt update 防重复标志已重置"
}
