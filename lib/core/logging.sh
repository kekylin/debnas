#!/bin/bash
# 功能：统一日志输出模块
# 说明：5 级日志等级（DEBUG/INFO/WARN/ERROR/FATAL），标签统一 7 字符宽度，全部直接输出
#       增强功能：支持文件日志输出（/var/log/debnas/）
#
# 日志等级使用指南：
#   INFO   — 用户关心的操作进度 + 幂等跳过说明
#            "正在安装 X"、"Y 已是最新，跳过"、"Z 配置未变更"
#   WARN   — 非致命异常，系统可自行处理
#            "APT 更新失败，使用缓存继续"
#   ERROR  — 操作失败，需用户介入
#            "权限不足"、"下载失败"
#   FATAL  — 不可恢复，程序终止 (exit 1)
#            "核心依赖缺失"、"磁盘空间耗尽"

set -euo pipefail
IFS=$'\n\t'

# 依赖: core/colors.sh（由 bootstrap-core.sh 先行加载）

# ==================== 文件日志配置 ====================

# 文件日志目录（默认值，log_to_file 中可能回退到 /tmp）
DEBNAS_LOG_DIR="/var/log/debnas"

# 当前日志文件路径（由 log_to_file 初始化）
declare -g _DEBNAS_LOG_FILE="${_DEBNAS_LOG_FILE:-}"

# 文件日志是否启用
declare -g _DEBNAS_FILE_LOGGING="${_DEBNAS_FILE_LOGGING:-${DEBNAS_FILE_LOGGING:-0}}"

# ==================== 核心函数 ====================

# 获取当前时间戳
get_timestamp() {
  if [[ "${LOG_TIMESTAMP:-1}" -eq 1 ]]; then
    date '+%Y-%m-%d %H:%M:%S'
  else
    echo ""
  fi
}

# 统一业务状态输出（终端）
log_status() {
  local status="$1"
  local message="$2"
  local color="$3"
  local ts
  ts=$(get_timestamp)
  if [[ -n "$ts" ]]; then
    printf "%b%s%b  %s %s\n" "$color" "$status" "$COLOR_RESET" "$ts" "$message" >&2
  else
    printf "%b%s%b  %s\n" "$color" "$status" "$COLOR_RESET" "$message" >&2
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

# ==================== 日志函数 ====================

# 标准 5 级日志等级：DEBUG=灰、INFO=青、WARN=黄、ERROR=红、FATAL=红
# log_success 是辅助标签（绿色 [DONE]），表示模块/操作的完成信号
# 标签统一 7 字符宽（左对齐不足补空格），标签与消息间固定 2 空格分隔（§4.4.2）
log_success() {
  log_status "[DONE] " "$1" "$COLOR_GREEN"
  _log_to_file "[DONE] " "$1"
}
log_warning() {
  log_status "[WARN] " "$1" "$COLOR_YELLOW"
  _log_to_file "[WARN] " "$1"
}
log_info() {
  log_status "[INFO] " "$1" "$COLOR_CYAN"
  _log_to_file "[INFO] " "$1"
}
log_error() {
  log_status "[ERROR]" "$1" "$COLOR_RED"
  _log_to_file "[ERROR]" "$1"
}
log_fatal() {
  log_status "[FATAL]" "$1" "$COLOR_RED"
  _log_to_file "[FATAL]" "$1"
  exit 1
}

# 库层专用：记录 FATAL 日志并返回 1（不退出进程）
# 调用方负责决定是否 exit，入口层（bin/）通常 || exit 1
log_fatal_return() {
  log_status "[FATAL]" "$1" "$COLOR_RED"
  _log_to_file "[FATAL]" "$1"
  return 1
}

# 调试日志（仅 DEBNAS_DEBUG=1 时输出到终端，文件日志始终写入）
log_debug() {
  if [[ "${DEBNAS_DEBUG:-0}" -eq 1 ]]; then
    log_status "[DEBUG]" "$1" "$COLOR_DIM"
  fi
  _log_to_file "[DEBUG]" "$1"
}

# ==================== 文件日志功能 ====================

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

  log_info "文件日志已启用：${_DEBNAS_LOG_FILE}"
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
