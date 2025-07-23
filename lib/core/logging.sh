#!/bin/bash
# 功能：统一日志输出模块，支持标准日志级别密度控制，终端仅展示业务状态

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

# 统一业务状态输出
log_status() {
  local status="$1"
  local message="$2"
  local color="$3"
  local ts
  ts=$(get_timestamp)
  if [[ -n "$ts" ]]; then
    printf "%b%s%b %s %s\n" "$color" "$status" "$COLOR_RESET" "$ts" "$message"
  else
    printf "%b%s%b %s\n" "$color" "$status" "$COLOR_RESET" "$message"
  fi
}

# 业务状态日志函数（只输出业务状态，不输出日志级别）
log_success() { should_log "INFO"  && log_status "[SUCCESS]" "$1" "$COLOR_GREEN"; }
log_fail()    { should_log "ERROR" && log_status "[FAIL]"    "$1" "$COLOR_RED"; }
log_warning() { should_log "WARN"  && log_status "[WARNING]" "$1" "$COLOR_YELLOW"; }
log_info()    { should_log "INFO"  && log_status "[INFO]"    "$1" "$COLOR_BLUE"; }
log_action()  { should_log "INFO"  && log_status "[ACTION]"  "$1" "$COLOR_CYAN"; }
log_debug()   { should_log "DEBUG" && log_status "[DEBUG]"   "$1" "$COLOR_CYAN"; }
log_error()   { should_log "ERROR" && log_status "[FAIL]"    "$1" "$COLOR_RED"; }
log_fatal()   { should_log "FATAL" && log_status "[FAIL]"    "$1" "$COLOR_MAGENTA"; }

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