#!/bin/bash
# 功能：模块状态追踪模块
# 说明：管理模块的安装状态和执行结果，支持幂等性检查
# 状态文件路径：/var/lib/debnas/state/<module>.state

set -euo pipefail
IFS=$'\n\t'

# 获取库文件目录
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$LIB_DIR/core/logging.sh"

# ==================== 常量定义 ====================

# 状态目录
readonly DEBNAS_STATE_DIR="/var/lib/debnas/state"

# 状态值常量
readonly STATE_SUCCESS="success"
readonly STATE_FAIL="fail"

# ==================== 内部函数 ====================

# 获取模块状态文件路径
# 参数：$1 - 模块名
# 输出：状态文件的绝对路径
_state_file() {
  local module_name="${1:?_state_file: 缺少模块名}"
  echo "${DEBNAS_STATE_DIR}/${module_name}.state"
}

# 确保状态目录存在
# 参数：无
# 返回：0 成功，1 失败
_ensure_state_dir() {
  if [[ ! -d "$DEBNAS_STATE_DIR" ]]; then
    mkdir -p "$DEBNAS_STATE_DIR" 2>/dev/null || {
      log_error "无法创建状态目录：${DEBNAS_STATE_DIR}"
      return 1
    }
    chmod 755 "$DEBNAS_STATE_DIR"
  fi
  return 0
}

# ==================== 公共接口 ====================

# 读取模块状态中的指定键值
# 参数：$1 - 模块名
#       $2 - 键名（installed_version|installed_at|last_result|last_run）
# 输出：键对应的值（不存在则输出空字符串）
# 返回：0 找到，1 未找到
state_get() {
  local module_name="${1:?state_get: 缺少模块名}"
  local key="${2:?state_get: 缺少键名}"
  local state_file
  state_file=$(_state_file "$module_name")

  if [[ ! -f "$state_file" ]]; then
    return 1
  fi

  local value
  value=$(grep "^${key}=" "$state_file" 2>/dev/null | head -1 | cut -d= -f2-)
  if [[ -n "$value" ]]; then
    echo "$value"
    return 0
  fi
  return 1
}

# 设置模块状态中的指定键值
# 参数：$1 - 模块名
#       $2 - 键名
#       $3 - 键值
# 返回：0 成功，1 失败
state_set() {
  local module_name="${1:?state_set: 缺少模块名}"
  local key="${2:?state_set: 缺少键名}"
  local value="${3:?state_set: 缺少键值}"
  local state_file
  state_file=$(_state_file "$module_name")

  if ! _ensure_state_dir; then
    return 1
  fi

  # 如果文件不存在则创建
  if [[ ! -f "$state_file" ]]; then
    touch "$state_file" 2>/dev/null || {
      log_error "无法创建状态文件：${state_file}"
      return 1
    }
    chmod 644 "$state_file"
  fi

  # 更新或追加键值对
  if grep -q "^${key}=" "$state_file" 2>/dev/null; then
    # 替换已有行
    sed -i "s|^${key}=.*|${key}=${value}|" "$state_file"
  else
    # 追加新行
    echo "${key}=${value}" >> "$state_file"
  fi

  log_debug "状态已更新：${module_name} ${key}=${value}"
  return 0
}

# 检查模块是否已成功安装
# 参数：$1 - 模块名
# 返回：0 已安装且成功，1 未安装或失败
state_is_installed() {
  local module_name="${1:?state_is_installed: 缺少模块名}"
  local last_result
  last_result=$(state_get "$module_name" "last_result" 2>/dev/null) || return 1

  [[ "$last_result" == "$STATE_SUCCESS" ]]
}

# 检查模块是否已配置（有状态记录即可）
# 参数：$1 - 模块名
# 返回：0 已配置，1 未配置
state_is_configured() {
  local module_name="${1:?state_is_configured: 缺少模块名}"
  local state_file
  state_file=$(_state_file "$module_name")

  [[ -f "$state_file" ]]
}

# 标记模块执行检查点（用于多步骤模块的进度记录）
# 参数：$1 - 模块名
#       $2 - 检查点名称
# 返回：0 成功，1 失败
state_mark_checkpoint() {
  local module_name="${1:?state_mark_checkpoint: 缺少模块名}"
  local checkpoint="${2:?state_mark_checkpoint: 缺少检查点名称}"

  state_set "$module_name" "last_checkpoint" "$checkpoint"
}

# 获取模块最后一个检查点
# 参数：$1 - 模块名
# 输出：检查点名称（无则输出空）
state_get_checkpoint() {
  local module_name="${1:?state_get_checkpoint: 缺少模块名}"
  state_get "$module_name" "last_checkpoint" 2>/dev/null
}

# 记录模块执行成功
# 参数：$1 - 模块名
#       $2 - 版本号（可选）
# 返回：0 成功
state_mark_success() {
  local module_name="${1:?state_mark_success: 缺少模块名}"
  local version="${2:-}"

  state_set "$module_name" "last_result" "$STATE_SUCCESS"
  state_set "$module_name" "last_run" "$(date '+%Y-%m-%dT%H:%M:%S%z')"

  if [[ -n "$version" ]]; then
    state_set "$module_name" "installed_version" "$version"
  fi

  # 首次安装时记录安装时间
  if ! state_get "$module_name" "installed_at" &>/dev/null; then
    state_set "$module_name" "installed_at" "$(date '+%Y-%m-%dT%H:%M:%S%z')"
  fi
}

# 记录模块执行失败
# 参数：$1 - 模块名
#       $2 - 失败原因（可选）
# 返回：0 成功
state_mark_fail() {
  local module_name="${1:?state_mark_fail: 缺少模块名}"
  local reason="${2:-unknown}"

  state_set "$module_name" "last_result" "$STATE_FAIL"
  state_set "$module_name" "last_run" "$(date '+%Y-%m-%dT%H:%M:%S%z')"
  state_set "$module_name" "last_error" "$reason"
}

# 清除模块状态（用于卸载或重置）
# 参数：$1 - 模块名
# 返回：0 成功
state_clear() {
  local module_name="${1:?state_clear: 缺少模块名}"
  local state_file
  state_file=$(_state_file "$module_name")

  if [[ -f "$state_file" ]]; then
    rm -f "$state_file"
    log_debug "模块状态已清除：${module_name}"
  fi
  return 0
}

# 列出所有已安装模块
# 参数：无
# 输出：每行一个模块名
state_list_installed() {
  if [[ ! -d "$DEBNAS_STATE_DIR" ]]; then
    return 0
  fi

  local state_file module_name last_result
  for state_file in "${DEBNAS_STATE_DIR}"/*.state; do
    [[ -f "$state_file" ]] || continue
    module_name=$(basename "$state_file" .state)
    last_result=$(grep "^last_result=" "$state_file" 2>/dev/null | cut -d= -f2-)
    if [[ "$last_result" == "$STATE_SUCCESS" ]]; then
      echo "$module_name"
    fi
  done
}
