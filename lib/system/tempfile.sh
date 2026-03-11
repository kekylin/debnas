#!/bin/bash
# 功能：临时文件集中管理模块
#
# 提供统一的临时文件与目录的创建、跟踪及自动清理机制。
# 所有临时资源存放于 /tmp/debnas/，通过 mktemp 生成唯一文件名，
# 基目录权限设置为 0700，脚本退出时自动清理已跟踪的资源。
#
# 用法：
#   source lib/system/tempfile.sh
#   register_temp_cleanup
#   my_file=$(create_temp_file "prefix")
#   my_dir=$(create_temp_dir "prefix")

set -euo pipefail
IFS=$'\n\t'

# ==================== 常量定义 ====================

# 临时文件基目录（所有模块共享）
readonly DEBNAS_TMP_BASE="${DEBNAS_TMP_BASE:-/tmp/debnas}"

# ==================== 内部状态 ====================

# 已创建的临时资源路径列表（用于退出时逆序清理）
declare -a _DEBNAS_TEMP_FILES=()

# 清理 trap 注册标志（防止重复注册）
declare -g _DEBNAS_CLEANUP_REGISTERED=0

# 正常退出标志（区分正常退出与异常退出的日志输出）
declare -g _DEBNAS_NORMAL_EXIT=0

# ==================== 核心函数 ====================

# 初始化临时文件基目录
# 若目录不存在则创建，并确保权限为 0700（仅 root 可访问）
# 返回：0 成功，1 失败
init_temp_dir() {
  if [[ ! -d "$DEBNAS_TMP_BASE" ]]; then
    mkdir -p "$DEBNAS_TMP_BASE" || {
      echo "临时目录创建失败：${DEBNAS_TMP_BASE}" >&2
      return 1
    }
  fi

  local current_mode
  current_mode=$(stat -c %a "$DEBNAS_TMP_BASE" 2>/dev/null || echo "")
  if [[ "$current_mode" != "700" ]]; then
    chmod 700 "$DEBNAS_TMP_BASE" || {
      echo "临时目录权限设置失败：${DEBNAS_TMP_BASE}" >&2
      return 1
    }
  fi
}

# 创建临时文件并纳入跟踪列表
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

  temp_file=$(mktemp "${DEBNAS_TMP_BASE}/${prefix}.XXXXXX${suffix}") || {
    echo "临时文件创建失败：${DEBNAS_TMP_BASE}/${prefix}.XXXXXX${suffix}" >&2
    return 1
  }

  _DEBNAS_TEMP_FILES+=("$temp_file")
  echo "$temp_file"
}

# 创建临时目录并纳入跟踪列表
# 参数：
#   $1 - 目录名前缀（必填）
# 输出：临时目录绝对路径
# 返回：0 成功，1 失败
create_temp_dir() {
  local prefix="${1:?create_temp_dir: 缺少必要参数：目录名前缀}"
  local temp_dir

  init_temp_dir || return 1

  temp_dir=$(mktemp -d "${DEBNAS_TMP_BASE}/${prefix}.XXXXXXXX") || {
    echo "临时目录创建失败：${DEBNAS_TMP_BASE}/${prefix}.XXXXXXXX" >&2
    return 1
  }

  chmod 700 "$temp_dir"
  _DEBNAS_TEMP_FILES+=("$temp_dir")
  echo "$temp_dir"
}

# 清理当前脚本已跟踪的所有临时资源
# 仅移除通过 create_temp_file / create_temp_dir 创建的条目，
# 不影响其他并发脚本的临时数据。基目录为空时自动移除。
cleanup_temp_files() {
  local item i
  # 逆序清理：确保子资源先于父目录移除
  for (( i=${#_DEBNAS_TEMP_FILES[@]}-1; i>=0; i-- )); do
    item="${_DEBNAS_TEMP_FILES[$i]}"
    if [[ -d "$item" ]]; then
      rm -rf "$item" 2>/dev/null || true
    elif [[ -f "$item" ]]; then
      rm -f "$item" 2>/dev/null || true
    fi
  done
  _DEBNAS_TEMP_FILES=()

  # 基目录为空时自动移除
  if [[ -d "$DEBNAS_TMP_BASE" ]] && [[ -z "$(ls -A "$DEBNAS_TMP_BASE" 2>/dev/null)" ]]; then
    rmdir "$DEBNAS_TMP_BASE" 2>/dev/null || true
  fi
}

# EXIT 信号回调：执行清理并在异常退出时记录日志
_debnas_cleanup_on_exit() {
  local exit_code=$?
  cleanup_temp_files
  if [[ $_DEBNAS_NORMAL_EXIT -eq 0 ]] && [[ $exit_code -ne 0 ]]; then
    if declare -f log_warning >/dev/null 2>&1; then
      log_warning "脚本异常退出（退出码：${exit_code}），临时文件已清理"
    fi
  fi
}

# INT/TERM 信号回调：执行清理并终止脚本
_debnas_cleanup_on_signal() {
  cleanup_temp_files
  if declare -f log_warning >/dev/null 2>&1; then
    log_warning "接收到中断信号，临时文件已清理"
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

# 为 apt 安装场景创建临时目录
# 流程：提升基目录权限至 0711（允许 _apt 用户遍历）→ 创建 0755 子目录
# 使用完毕后须调用 restore_apt_temp_permissions 恢复基目录原始权限
# 参数：
#   $1 - 子目录名前缀（必填）
# 输出：子目录绝对路径
# 返回：0 成功，1 失败
prepare_apt_temp() {
  local prefix="${1:?prepare_apt_temp: 缺少必要参数：子目录名前缀}"
  local apt_dir orig_mode

  init_temp_dir || return 1

  # 保存基目录原始权限，用于后续恢复
  orig_mode=$(stat -c '%a' "$DEBNAS_TMP_BASE" 2>/dev/null || echo "700")
  echo "$orig_mode" > "${DEBNAS_TMP_BASE}/.orig_mode" 2>/dev/null || true

  # 提升基目录权限，允许 _apt 用户遍历访问
  chmod 711 "$DEBNAS_TMP_BASE" || true

  apt_dir=$(mktemp -d -p "$DEBNAS_TMP_BASE" "${prefix}.XXXXXXXX") || {
    chmod "$orig_mode" "$DEBNAS_TMP_BASE" 2>/dev/null || true
    echo "apt 临时目录创建失败" >&2
    return 1
  }

  chmod 755 "$apt_dir" || true
  _DEBNAS_TEMP_FILES+=("$apt_dir")
  echo "$apt_dir"
}

# 恢复 apt 场景下基目录的原始权限
# 读取 prepare_apt_temp 保存的权限值并恢复
restore_apt_temp_permissions() {
  local orig_mode="700"
  if [[ -f "${DEBNAS_TMP_BASE}/.orig_mode" ]]; then
    orig_mode=$(cat "${DEBNAS_TMP_BASE}/.orig_mode" 2>/dev/null || echo "700")
    rm -f "${DEBNAS_TMP_BASE}/.orig_mode" 2>/dev/null || true
  fi
  chmod "$orig_mode" "$DEBNAS_TMP_BASE" 2>/dev/null || true
}
