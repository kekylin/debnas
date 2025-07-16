#!/bin/bash
# 功能：统一日志输出模块，支持标准日志级别、时间戳、模块名等
# 作者：kekylin
# 创建时间：2025-07-11
# 修改时间：2025-07-12
#
# 用法：source logging.sh 后调用 log_debug/log_info/log_warn/log_error/log_fatal
#
# 环境变量：
#   LOG_LEVEL - 日志级别过滤 (DEBUG|INFO|WARN|ERROR|FATAL)
#   NO_COLOR=1 - 禁用彩色输出
#   LOG_TIMESTAMP=0 - 禁用时间戳

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

# 语义化颜色映射（用于日志系统）
get_log_color() {
  local level="$1"
  case "$level" in
    DEBUG) echo "$COLOR_CYAN" ;;
    INFO)  echo "$COLOR_BLUE" ;;
    WARN)  echo "$COLOR_YELLOW" ;;
    ERROR) echo "$COLOR_RED" ;;
    FATAL) echo "$COLOR_MAGENTA" ;;
    *)     echo "$COLOR_BLUE" ;;
  esac
}

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

# 日志输出主函数
log_message() {
  local level="$1"
  local message="$2"
  local timestamp
  local color=""

  should_log "$level" || return 0
  timestamp=$(get_timestamp)
  color=$(get_log_color "$level")

  if [[ -n "$timestamp" ]]; then
    printf "%b[%s]%b %s %s\n" \
      "$color" "$level" "$COLOR_RESET" \
      "$timestamp" "$message"
  else
    printf "%b[%s]%b %s\n" \
      "$color" "$level" "$COLOR_RESET" \
      "$message"
  fi
}

# 标准日志级别函数
log_debug() { log_message "DEBUG" "$1"; }
log_info()  { log_message "INFO"  "$1"; }
log_warn()  { log_message "WARN"  "$1"; }
log_error() { log_message "ERROR" "$1"; }
log_fatal() { log_message "FATAL" "$1"; }

# 语义别名，按行业标准统一颜色
log_success() {
  local msg="$1"
  local ts=$(get_timestamp)
  printf "%b[SUCCESS]%b %s %s\n" "$COLOR_GREEN" "$COLOR_RESET" "$ts" "$msg"
}
log_fail() {
  local msg="$1"
  local ts=$(get_timestamp)
  printf "%b[FAIL]%b %s %s\n" "$COLOR_RED" "$COLOR_RESET" "$ts" "$msg"
}
log_warning() {
  local msg="$1"
  local ts=$(get_timestamp)
  printf "%b[WARNING]%b %s %s\n" "$COLOR_YELLOW" "$COLOR_RESET" "$ts" "$msg"
}
log_info() {
  local msg="$1"
  local ts=$(get_timestamp)
  printf "%b[INFO]%b %s %s\n" "$COLOR_BLUE" "$COLOR_RESET" "$ts" "$msg"
}
log_action() {
  local msg="$1"
  local ts=$(get_timestamp)
  printf "%b[ACTION]%b %s %s\n" "$COLOR_CYAN" "$COLOR_RESET" "$ts" "$msg"
}

# 设置日志级别
set_log_level() {
  local level="$1"
  if [[ -n "${LOG_LEVELS[$level]}" ]]; then
    CURRENT_LOG_LEVEL="$level"
    log_info "日志级别设置为: $level"
  else
    log_error "无效的日志级别: $level (支持: ${!LOG_LEVELS[*]})"
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