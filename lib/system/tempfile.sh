#!/bin/bash
# 功能：临时文件集中管理模块
#
# 提供统一的临时文件与目录的创建及自动清理机制。
# 每个进程使用独立的 PID 子目录（/tmp/debnas/pid-$$/），
# 退出时 rm -rf 整个进程目录即可，无需追踪单个文件。
# 此设计天然免疫命令替换子 shell 导致的数组修改丢失问题，
# 因为文件系统操作在子 shell 中同样持久。
#
# 用法：
#   source lib/system/tempfile.sh
#   register_temp_cleanup
#   my_file=$(create_temp_file "prefix")
#   my_dir=$(create_temp_dir "prefix")

set -euo pipefail
IFS=$'\n\t'

# ==================== 常量定义 ====================

# 临时文件基目录（所有进程共享）
readonly DEBNAS_TMP_BASE="${DEBNAS_TMP_BASE:-/tmp/debnas}"

# 当前进程的 PID 临时子目录（进程隔离，退出时整体移除）
readonly _DEBNAS_PID_DIR="${DEBNAS_TMP_BASE}/pid-$$"

# ==================== 内部状态 ====================

# 清理 trap 注册标志（防止重复注册）
declare -g _DEBNAS_CLEANUP_REGISTERED=0

# 正常退出标志（区分正常退出与异常退出的日志输出）
# 0 = 未标记，1 = 已标记正常退出
declare -g _DEBNAS_NORMAL_EXIT=0

# 有意退出码范围（constants.sh 中定义的错误码 2-6）
# 退出码 1 是歧义的：可能是 ERROR_GENERAL（有意），也可能是 set -e 意外杀进程
# 因此 2-6 始终视为有意退出，退出码 1 需通过 mark_normal_exit 标记来区分
readonly _DEBNAS_INTENTIONAL_EXIT_MIN=2
readonly _DEBNAS_INTENTIONAL_EXIT_MAX=6

# ==================== 核心函数 ====================

# 初始化临时文件目录
# 创建基目录（755，允许 _apt 等系统用户遍历访问）和进程 PID 子目录（700）
# 返回：0 成功，1 失败
init_temp_dir() {
  # 基目录
  if [[ ! -d "$DEBNAS_TMP_BASE" ]]; then
    mkdir -p "$DEBNAS_TMP_BASE" || {
      echo "临时目录失败: ${DEBNAS_TMP_BASE}" >&2
      return 1
    }
  fi
  chmod 755 "$DEBNAS_TMP_BASE" || {
    echo "临时目录权限设置失败：${DEBNAS_TMP_BASE}" >&2
    return 1
  }

  # PID 子目录（进程隔离）
  if [[ ! -d "$_DEBNAS_PID_DIR" ]]; then
    mkdir -p "$_DEBNAS_PID_DIR" || {
      echo "PID临时目录失败: ${_DEBNAS_PID_DIR}" >&2
      return 1
    }
    chmod 700 "$_DEBNAS_PID_DIR"
  fi
}

# 创建临时文件
# 文件创建在当前进程的 PID 子目录下，退出时自动随目录移除。
# 参数：
#   $1 - 文件名前缀（必填）
#   $2 - 文件扩展名（可选，默认 .tmp）
# 输出：临时文件绝对路径
# 返回：0 成功，1 失败
create_temp_file() {
  local prefix="${1:?create_temp_file: 缺少必要参数：文件名前缀}"
  local suffix="${2:-.tmp}"
  local temp_file

  init_temp_dir || return 1

  temp_file=$(mktemp "${_DEBNAS_PID_DIR}/${prefix}.XXXXXX${suffix}") || {
    echo "临时文件失败: ${_DEBNAS_PID_DIR}/${prefix}.XXXXXX${suffix}" >&2
    return 1
  }

  echo "$temp_file"
}

# 创建临时目录
# 目录创建在当前进程的 PID 子目录下，退出时自动随目录移除。
# 参数：
#   $1 - 目录名前缀（必填）
# 输出：临时目录绝对路径
# 返回：0 成功，1 失败
create_temp_dir() {
  local prefix="${1:?create_temp_dir: 缺少必要参数：目录名前缀}"
  local temp_dir

  init_temp_dir || return 1

  temp_dir=$(mktemp -d "${_DEBNAS_PID_DIR}/${prefix}.XXXXXXXX") || {
    echo "临时目录失败: ${_DEBNAS_PID_DIR}" >&2
    return 1
  }

  chmod 700 "$temp_dir"
  echo "$temp_dir"
}

# 清理当前进程的所有临时资源
# 移除 PID 子目录及其下所有内容。基目录为空时自动移除。
# 不影响其他并发脚本的 PID 子目录。
cleanup_temp_files() {
  if [[ -d "$_DEBNAS_PID_DIR" ]]; then
    rm -rf "$_DEBNAS_PID_DIR" 2>/dev/null || true
  fi

  # 基目录为空时自动移除
  if [[ -d "$DEBNAS_TMP_BASE" ]] && [[ -z "$(ls -A "$DEBNAS_TMP_BASE" 2>/dev/null)" ]]; then
    rmdir "$DEBNAS_TMP_BASE" 2>/dev/null || true
  fi
}

# EXIT 信号回调：执行清理并在异常退出时记录日志
# 已知错误码（2-6）视为有意退出，不输出警告
# 退出码 1 需配合 mark_normal_exit 标记区分有意/意外
# 其他非零退出码（7-127, 128+信号）视为异常退出
_debnas_cleanup_on_exit() {
  local exit_code=$?
  # 在清理前捕获信号状态（哨兵文件将在 cleanup_temp_files 后被移除，
  # 避免残留的哨兵文件影响后续 debnas 运行的异常退出警告）
  local _was_signalled=0
  [[ -f /tmp/.debnas_signal_handled ]] && _was_signalled=1
  cleanup_temp_files
  rm -f /tmp/.debnas_signal_handled 2>/dev/null || true
  # 如果中断信号已处理过，不再重复输出
  if [[ $_was_signalled -eq 1 ]]; then
    return 0
  fi
  # 退出码 0：成功，不报警
  [[ $exit_code -eq 0 ]] && return 0
  # 退出码 2-6：已知的有意退出码（ERROR_DEPENDENCY/ERROR_PERMISSION 等）
  [[ $exit_code -ge $_DEBNAS_INTENTIONAL_EXIT_MIN && $exit_code -le $_DEBNAS_INTENTIONAL_EXIT_MAX ]] && return 0
  # 退出码 1：如果已标记正常退出，视为有意；否则可能是 set -e 意外杀进程
  [[ $exit_code -eq 1 && $_DEBNAS_NORMAL_EXIT -eq 1 ]] && return 0
  # 其余情况：真正意外的退出，输出警告
  if declare -f log_warning >/dev/null 2>&1; then
    log_warning "异常退出 (${exit_code})，临时文件已清理"
  fi
}

# INT/TERM 信号回调：执行清理并终止脚本（跨进程去重，只提示一次）
_debnas_cleanup_on_signal() {
  cleanup_temp_files
  # 跨进程去重：只有第一个接收到信号的进程输出提示
  if [[ ! -f /tmp/.debnas_signal_handled ]]; then
    touch /tmp/.debnas_signal_handled 2>/dev/null || true
    if declare -f log_warning >/dev/null 2>&1; then
      log_warning "已取消，临时文件已清理"
    fi
  fi
  exit 1
}

# 注册退出清理 trap（EXIT/INT/TERM）
# 确保脚本退出时自动清理已跟踪的临时资源，多次调用仅首次生效
register_temp_cleanup() {
  if [[ $_DEBNAS_CLEANUP_REGISTERED -eq 1 ]]; then
    return 0
  fi
  trap '_debnas_cleanup_on_exit' EXIT
  trap '_debnas_cleanup_on_signal' INT TERM
  _DEBNAS_CLEANUP_REGISTERED=1
}

# 标记当前脚本为正常退出状态
# 调用后，EXIT 回调将不再输出异常退出警告
mark_normal_exit() {
  _DEBNAS_NORMAL_EXIT=1
}


