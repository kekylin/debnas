#!/bin/bash
# 功能：标准化模块执行引擎
# 说明：提供 preflight → execute → verify → report 的标准执行流程
#
# 用法：
#   bash bin/module-runner.sh <模块名> [参数...]
#
# 执行流程：
#   preflight  → root/版本/依赖/状态/dry-run 检查
#   execute    → 调用模块的 main() 函数
#   verify     → 模块自检（如果模块定义了 module_verify 函数）
#   report     → 写入状态文件和日志

set -euo pipefail
IFS=$'\n\t'

# 获取项目根目录
_DEBNAS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 加载统一库
source "${_DEBNAS_ROOT}/lib/bootstrap.sh"

# ==================== Preflight 检查 ====================

# Preflight: root 权限检查
preflight_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    log_error "此操作需要 root 权限，请使用 sudo 或以 root 身份运行"
    return 1
  fi
}

# Preflight: Debian 版本检查
preflight_debian_version() {
  local debian_min="${1:-bookworm}"
  if ! verify_system_support 2>/dev/null; then
    log_error "系统不满足要求（需要 Debian 12 ${debian_min} 或更高版本）"
    return 1
  fi
}

# Preflight: 依赖命令检查
preflight_dependencies() {
  local module_name="$1"
  local depends_str
  depends_str=$(get_module_field "$module_name" "depends" "" 2>/dev/null) || depends_str=""

  if [[ -z "$depends_str" ]]; then
    return 0
  fi

  local -a missing_cmds=()
  local cmd
  for cmd in $(echo "$depends_str" | tr ',' ' '); do
    cmd="${cmd#"${cmd%%[![:space:]]*}"}"
    cmd="${cmd%"${cmd##*[![:space:]]}"}"
    [[ -n "$cmd" ]] || continue
    if ! command -v "$cmd" &>/dev/null; then
      missing_cmds+=("$cmd")
    fi
  done

  if [[ ${#missing_cmds[@]} -eq 0 ]]; then
    log_debug "所有依赖命令已就绪：${depends_str}"
    return 0
  fi

  log_info "检测到缺失依赖：${missing_cmds[*]}，尝试自动安装..."
  install_missing_dependencies "${missing_cmds[@]}"

  # 再次检查
  for cmd in "${missing_cmds[@]}"; do
    if ! command -v "$cmd" &>/dev/null; then
      log_error "依赖安装失败：${cmd}"
      return 1
    fi
  done
}

# Preflight: 幂等性检查
preflight_state() {
  local module_name="$1"

  if state_is_installed "$module_name" 2>/dev/null; then
    local version
    version=$(state_get "$module_name" "installed_version" 2>/dev/null) || version=""
    local display_name
    display_name=$(get_module_field "$module_name" "name" "$module_name" 2>/dev/null) || display_name="$module_name"

    log_info "${display_name} 已安装（版本: ${version:-未知}），跳过"

    if [[ "${DEBNAS_FORCE_YES:-0}" -eq 1 ]]; then
      log_info "--yes 模式下跳过已安装模块"
      return 1
    fi

    # 询问是否重新执行
    read -rp "是否重新执行？[y/N]: " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
      return 1
    fi
  fi
  return 0
}

# Preflight: dry-run 模式
preflight_dry_run() {
  local module_name="$1"

  if [[ "${DEBNAS_DRY_RUN:-0}" -ne 1 ]]; then
    return 0
  fi

  local display_name
  display_name=$(get_module_field "$module_name" "name" "$module_name" 2>/dev/null) || display_name="$module_name"

  echo "── 执行计划（dry-run）──"
  echo "  模块: ${display_name} (${module_name})"
  echo "  入口: $(get_module_path "$module_name" 2>/dev/null || echo '未知')"

  local depends_str
  depends_str=$(get_module_field "$module_name" "depends" "" 2>/dev/null) || depends_str=""
  if [[ -n "$depends_str" ]]; then
    echo "  依赖命令: ${depends_str}"
  fi

  local dep_modules
  dep_modules=$(get_module_field "$module_name" "depend_modules" "" 2>/dev/null) || dep_modules=""
  if [[ -n "$dep_modules" ]]; then
    echo "  依赖模块: ${dep_modules}"
  fi

  local cron_flag
  cron_flag=$(get_module_field "$module_name" "cron" "false" 2>/dev/null) || cron_flag="false"
  if [[ "$cron_flag" == "true" ]]; then
    local schedule
    schedule=$(get_module_field "$module_name" "cron_schedule" "" 2>/dev/null) || schedule=""
    echo "  定时任务: ${schedule:-未指定}"
  fi

  echo "── dry-run 模式，不实际执行 ──"
  return 1
}

# ==================== 执行流程 ====================

# 执行模块（通过 bash 子进程调用）
execute_module() {
  local module_name="$1"
  shift
  local module_path
  module_path=$(get_module_path "$module_name")

  local display_name
  display_name=$(get_module_field "$module_name" "name" "$module_name" 2>/dev/null) || display_name="$module_name"

  log_action "正在执行模块：${display_name}"

  # 通过 bash 子进程执行模块（模块保持独立性）
  if bash "$module_path" "$@"; then
    return 0
  else
    return 1
  fi
}

# ==================== 主流程 ====================

main() {
  # 解析全局参数
  parse_global_args "$@"

  # 获取剩余参数
  local -a args=()
  if [[ -n "${DEBNAS_REMAINING_ARGS:-}" ]]; then
    read -ra args <<< "$DEBNAS_REMAINING_ARGS"
  fi

  if [[ ${#args[@]} -eq 0 ]]; then
    log_error "未指定模块名"
    echo "用法: module-runner.sh <模块名> [参数...]"
    return 1
  fi

  local module_name="${args[0]}"
  local -a module_args=("${args[@]:1}")

  # 发现模块
  discover_modules 2>/dev/null

  # 检查模块是否存在
  if ! module_exists "$module_name"; then
    log_error "模块不存在：${module_name}"
    echo ""
    echo "可用模块："
    get_module_list | sort | sed 's/^/  /'
    return 1
  fi

  local display_name
  display_name=$(get_module_field "$module_name" "name" "$module_name" 2>/dev/null) || display_name="$module_name"

  # ── Preflight ──
  log_debug "开始 preflight 检查：${module_name}"

  # dry-run 检查（最先，如果启用则打印计划并退出）
  if ! preflight_dry_run "$module_name"; then
    return 0
  fi

  # root 权限
  if ! preflight_root; then
    return 1
  fi

  # Debian 版本
  local debian_min
  debian_min=$(get_module_field "$module_name" "debian_min" "bookworm" 2>/dev/null) || debian_min="bookworm"
  if ! preflight_debian_version "$debian_min"; then
    return 1
  fi

  # 依赖命令
  if ! preflight_dependencies "$module_name"; then
    return 1
  fi

  # 幂等性（已安装则询问）
  if ! preflight_state "$module_name"; then
    return 0
  fi

  # 依赖模块（递归执行）
  local dep_modules
  dep_modules=$(get_module_field "$module_name" "depend_modules" "" 2>/dev/null) || dep_modules=""
  if [[ -n "$dep_modules" ]]; then
    log_debug "解析模块依赖：${dep_modules}"
    local -a exec_order
    mapfile -t exec_order < <(resolve_module_deps "$module_name" 2>/dev/null)

    # 执行依赖模块（排除自身）
    local dep
    for dep in "${exec_order[@]}"; do
      if [[ "$dep" == "$module_name" ]]; then
        continue
      fi
      log_info "执行依赖模块：${dep}"
      if ! bash "${_DEBNAS_ROOT}/bin/module-runner.sh" "$dep"; then
        log_error "依赖模块 ${dep} 执行失败，当前模块已跳过"
        return 1
      fi
    done
  fi

  # ── 初始化日志 ──
  log_to_file "$module_name" 2>/dev/null || true

  # ── Execute ──
  local exit_code=0
  if execute_module "$module_name" "${module_args[@]+"${module_args[@]}"}"; then
    # ── Report: 成功 ──
    local version
    version=$(get_module_field "$module_name" "version" "" 2>/dev/null) || version=""
    state_mark_success "$module_name" "$version"
    log_success "模块执行完成：${display_name}"
  else
    exit_code=$?
    # ── Report: 失败 ──
    state_mark_fail "$module_name" "exit_code_${exit_code}"
    log_error "模块执行失败：${display_name}"
    local log_file
    log_file=$(get_log_file 2>/dev/null)
    if [[ -n "$log_file" ]]; then
      log_error "查看日志: ${log_file}"
    fi
  fi

  # ── 停止文件日志 ──
  log_stop_file 2>/dev/null || true

  return "$exit_code"
}

main "$@"
