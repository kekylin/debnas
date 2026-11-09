#!/bin/bash
# 功能：模块状态追踪模块
# 说明：管理模块的安装状态和执行结果，支持幂等性检查
# 状态文件路径：/var/lib/debnas/state/<module>.state

set -euo pipefail
IFS=$'\n\t'

# 依赖: core/logging.sh（由 bootstrap-core.sh 加载）

# ==================== 常量定义 ====================

# 状态目录（不设 readonly，允许测试 Mock）
DEBNAS_STATE_DIR="${DEBNAS_STATE_DIR:-/var/lib/debnas/state}"

# 状态值常量
STATE_SUCCESS="${STATE_SUCCESS:-success}"
STATE_FAIL="${STATE_FAIL:-fail}"

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
  local state_file="${DEBNAS_STATE_DIR}/${module_name}.state" line

  if [[ ! -f "$state_file" || ! -r "$state_file" ]]; then
    return 1
  fi

  # 纯 bash 逐行匹配，取第一条 key=（状态文件只有几行；原 grep|head|cut 每次 3 个进程，
  # 仪表盘合并执行记录时每个模块都会调用）
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "${key}="* ]]; then
      line="${line#*=}"
      [[ -n "$line" ]] || return 1
      echo "$line"
      return 0
    fi
  done < "$state_file"
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

  # 值中的换行会注入额外的键值行（如 last_error 来自多行错误信息），统一替换为空格
  value="${value//$'\r'/ }"
  value="${value//$'\n'/ }"

  # 更新或追加键值对
  if grep -q "^${key}=" "$state_file" 2>/dev/null; then
    # 替换已有行：整行重写为 key=value。
    # 旧实现 awk -F= '$2=v' 在值含 "=" 时会残留后续字段，且 -v 会解释反斜杠转义。
    _DEBNAS_STATE_KEY="$key" _DEBNAS_STATE_VAL="$value" awk '
      BEGIN { k = ENVIRON["_DEBNAS_STATE_KEY"]; v = ENVIRON["_DEBNAS_STATE_VAL"] }
      index($0, k"=") == 1 { print k"="v; next }
      { print }
    ' "$state_file" > "${state_file}.tmp"
    mv "${state_file}.tmp" "$state_file"
  else
    # 追加新行
    echo "${key}=${value}" >> "$state_file"
  fi

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

# 交互模块执行真实动作后调用，供 module-runner 判断是否记录状态与日志
module_mark_action() {
  [[ -n "${DEBNAS_ACTION_MARKER:-}" ]] && : > "$DEBNAS_ACTION_MARKER" 2>/dev/null || true
  return 0
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
    module_name="${state_file##*/}"
    module_name="${module_name%.state}"
    last_result=$(state_get "$module_name" "last_result") || last_result=""
    if [[ "$last_result" == "$STATE_SUCCESS" ]]; then
      echo "$module_name"
    fi
  done
}
