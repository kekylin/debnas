#!/bin/bash
# 功能：统一日志输出模块
# 说明：支持标准日志级别密度控制，终端仅展示业务状态
#       增强功能：支持文件日志输出（/var/log/debnas/）

set -euo pipefail
IFS=$'\n\t'

# 日志级别定义（数字越大级别越高）
declare -A LOG_LEVELS=(
  [DEBUG]=0
  [INFO]=1
  [WARN]=2
  [ERROR]=3
  [FATAL]=4
)

# 默认日志级别
DEFAULT_LOG_LEVEL="INFO"
CURRENT_LOG_LEVEL="${LOG_LEVEL:-$DEFAULT_LOG_LEVEL}"

# 获取库文件目录
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 加载核心颜色定义
source "$LIB_DIR/core/colors.sh"

# ==================== 文件日志配置 ====================

# 文件日志目录（默认值，log_to_file 中可能回退到 /tmp）
DEBNAS_LOG_DIR="/var/log/debnas"

# 当前日志文件路径（由 log_to_file 初始化）
declare -g _DEBNAS_LOG_FILE="${_DEBNAS_LOG_FILE:-}"

# 文件日志是否启用
declare -g _DEBNAS_FILE_LOGGING="${_DEBNAS_FILE_LOGGING:-0}"

# ==================== 核心函数 ====================

# 获取当前时间戳
get_timestamp() {
  if [[ "${LOG_TIMESTAMP:-1}" -eq 1 ]]; then
    date '+%Y-%m-%d %H:%M:%S'
  else
    echo ""
  fi
}

# 检查日志级别是否应该输出
should_log() {
  local level="$1"
  local current_level_num="${LOG_LEVELS[$CURRENT_LOG_LEVEL]:-1}"
  local message_level_num="${LOG_LEVELS[$level]:-0}"
  [[ $message_level_num -ge $current_level_num ]]
}

# 统一业务状态输出（终端）
log_status() {
  local status="$1"
  local message="$2"
  local color="$3"
  local ts
  ts=$(get_timestamp)
  if [[ -n "$ts" ]]; then
    printf "%b%s%b %s %s\n" "$color" "$status" "$COLOR_RESET" "$ts" "$message" >&2
  else
    printf "%b%s%b %s\n" "$color" "$status" "$COLOR_RESET" "$message" >&2
  fi
}

# 写入日志到文件（无颜色代码）
# 参数：$1 - 级别标签（如 [INFO]）
#       $2 - 消息内容
_log_to_file() {
  local status="$1"
  local message="$2"

  if [[ "$_DEBNAS_FILE_LOGGING" -ne 1 ]] || [[ -z "$_DEBNAS_LOG_FILE" ]]; then
    return 0
  fi

  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  echo "${ts} ${status} ${message}" >> "$_DEBNAS_LOG_FILE" 2>/dev/null || true
}

# ==================== 日志函数（保持原有签名不变） ====================

# 业务状态日志函数（只输出业务状态，不输出日志级别）
# 注意：使用 if 而非 && 短路，确保函数始终返回 0（兼容 set -e）
log_success() {
  if should_log "INFO";  then log_status "[SUCCESS]" "$1" "$COLOR_GREEN"; _log_to_file "[SUCCESS]" "$1"; fi
}
log_fail() {
  if should_log "ERROR"; then log_status "[FAIL]"    "$1" "$COLOR_RED";   _log_to_file "[FAIL]" "$1"; fi
}
log_warning() {
  if should_log "WARN";  then log_status "[WARNING]" "$1" "$COLOR_YELLOW"; _log_to_file "[WARNING]" "$1"; fi
}
log_info() {
  if should_log "INFO";  then log_status "[INFO]"    "$1" "$COLOR_BLUE";   _log_to_file "[INFO]" "$1"; fi
}
log_action() {
  if should_log "INFO";  then log_status "[ACTION]"  "$1" "$COLOR_CYAN";   _log_to_file "[ACTION]" "$1"; fi
}
log_debug() {
  if should_log "DEBUG"; then log_status "[DEBUG]"   "$1" "$COLOR_CYAN";   _log_to_file "[DEBUG]" "$1"; fi
}
log_error() {
  if should_log "ERROR"; then log_status "[FAIL]"    "$1" "$COLOR_RED";    _log_to_file "[FAIL]" "$1"; fi
}
log_fatal() {
  if should_log "FATAL"; then log_status "[FAIL]"    "$1" "$COLOR_MAGENTA"; _log_to_file "[FATAL]" "$1"; fi
}

# ==================== 日志级别管理（保持原有签名不变） ====================

# 设置日志级别
set_log_level() {
  local level="$1"
  if [[ -n "${LOG_LEVELS[$level]}" ]]; then
    CURRENT_LOG_LEVEL="$level"
    log_info "日志级别设置为: $level"
  else
    log_fail "无效的日志级别: $level (支持: ${!LOG_LEVELS[*]})"
    return 1
  fi
}

# 获取当前日志级别
get_log_level() {
  echo "$CURRENT_LOG_LEVEL"
}

# 显示支持的日志级别
show_log_levels() {
  echo "支持的日志级别:"
  for level in "${!LOG_LEVELS[@]}"; do
    echo "  $level (${LOG_LEVELS[$level]})"
  done
  echo "当前日志级别: $CURRENT_LOG_LEVEL"
}

# ==================== 文件日志功能（新增） ====================

# 初始化文件日志
# 参数：$1 - 模块名（用于日志文件命名）
# 返回：0 成功，1 失败
# 说明：日志文件路径 /var/log/debnas/<module>-<timestamp>.log
log_to_file() {
  local module_name="${1:?log_to_file: 缺少模块名}"

  # 确保日志目录存在
  if [[ ! -d "$DEBNAS_LOG_DIR" ]]; then
    mkdir -p "$DEBNAS_LOG_DIR" 2>/dev/null || {
      # 无 root 权限时使用 /tmp 回退
      DEBNAS_LOG_DIR="/tmp/debnas-logs"
      mkdir -p "$DEBNAS_LOG_DIR" 2>/dev/null || return 1
    }
    chmod 755 "$DEBNAS_LOG_DIR" 2>/dev/null || true
  fi

  # 生成日志文件名
  local timestamp
  timestamp=$(date '+%Y-%m-%d-%H%M%S')
  _DEBNAS_LOG_FILE="${DEBNAS_LOG_DIR}/${module_name}-${timestamp}.log"

  # 创建日志文件
  touch "$_DEBNAS_LOG_FILE" 2>/dev/null || return 1
  chmod 644 "$_DEBNAS_LOG_FILE" 2>/dev/null || true

  # 启用文件日志
  _DEBNAS_FILE_LOGGING=1

  # 写入日志头
  {
    echo "=== DebNAS 模块日志 ==="
    echo "模块: ${module_name}"
    echo "开始时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "系统: $(uname -a)"
    echo "========================"
  } >> "$_DEBNAS_LOG_FILE"

  log_debug "文件日志已启用：${_DEBNAS_LOG_FILE}"
  return 0
}

# 停止文件日志
# 参数：无
# 返回：0 成功
log_stop_file() {
  if [[ "$_DEBNAS_FILE_LOGGING" -eq 1 ]] && [[ -n "$_DEBNAS_LOG_FILE" ]]; then
    echo "=== 日志结束 $(date '+%Y-%m-%d %H:%M:%S') ===" >> "$_DEBNAS_LOG_FILE" 2>/dev/null || true
    _DEBNAS_FILE_LOGGING=0
  fi
  return 0
}

# 获取当前日志文件路径
# 参数：无
# 输出：日志文件路径（未启用则输出空）
get_log_file() {
  echo "$_DEBNAS_LOG_FILE"
}
