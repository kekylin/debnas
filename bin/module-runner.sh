#!/bin/bash
# 功能：标准化模块执行引擎
# 说明：提供 preflight → execute → verify → report 的标准执行流程
#
# 用法：
#   bash bin/module-runner.sh <模块名> [参数...]
#   bash bin/module-runner.sh --probe status|plan <模块名>   # 只读探测，不执行 main
#
# 执行流程：
#   preflight  → root/版本/依赖/状态/dry-run 检查
#   execute    → 调用模块的 main() 函数
#   verify     → 模块自检（如果模块定义了 module_verify 函数）
#   report     → 写入状态文件和日志

set -euo pipefail
IFS=$'\n\t'

# 获取项目根目录
_DEBNAS_SCRIPT="$(readlink -f "${BASH_SOURCE[0]}")"
_DEBNAS_ROOT="$(cd "$(dirname "${_DEBNAS_SCRIPT}")/.." && pwd)"

# 加载统一库
source "${_DEBNAS_ROOT}/lib/bootstrap.sh"

# ==================== Preflight 检查 ====================

# Preflight: root 权限检查
preflight_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    log_error "需要 root 权限"
    return 1
  fi
}

# Preflight: Debian 版本检查
preflight_environment_check() {
  local debian_min="${1:-bookworm}"
  local required_arch="${2:-}"
  if ! verify_debian_12_13_support 2>/dev/null; then
    log_error "系统版本不满足运行基础环境 (需 Debian 12+)"
    return 1
  fi

  # 若模块有具体架构要求
  if [[ -n "$required_arch" ]] && ! verify_architecture_support "$required_arch" 2>/dev/null; then
    log_error "此模块不支持当前 CPU 架构，所需架构: $required_arch"
    return 1
  fi
}

# Preflight: 依赖命令检查（按 Tier 0/1/2 分级处理）
preflight_dependencies() {
  local module_name="$1"
  local depends_str
  depends_str=$(get_module_field "$module_name" "depends" "" 2>/dev/null) || depends_str=""

  if [[ -z "$depends_str" ]]; then
    return 0
  fi

  local -a dep_cmds=()
  IFS=' ,' read -ra dep_cmds <<< "$depends_str"

  # 去空格、去空元素
  local -a clean_cmds=()
  local cmd
  for cmd in "${dep_cmds[@]}"; do
    cmd="${cmd#"${cmd%%[![:space:]]*}"}"
    cmd="${cmd%"${cmd##*[![:space:]]}"}"
    [[ -n "$cmd" ]] || continue
    clean_cmds+=("$cmd")
  done

  if [[ ${#clean_cmds[@]} -eq 0 ]]; then
    return 0
  fi

  log_info "检查依赖命令：${depends_str}"

  # 按级别分流处理
  check_dependencies_by_level "${clean_cmds[@]}"
}

# Preflight: dry-run 模式
preflight_dry_run() {
  local module_name="$1"

  if [[ "${DEBNAS_DRY_RUN:-0}" -ne 1 ]]; then
    return 0
  fi

  local display_name
  display_name=$(get_module_field "$module_name" "name" "$module_name" 2>/dev/null) || display_name="$module_name"

  echo "[预览模式]"
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

  echo "[预览模式] 仅查看，不执行"
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

  if [[ "${_DEBNAS_INTERACTIVE_TTY:-0}" -ne 1 ]]; then
    log_info "→ ${display_name}"
  fi

  # 通过 bash 子进程执行模块（清除 bootstrap 标记，让模块重新加载库）
  # 保留模块真实退出码（2=依赖缺失、4=权限不足等），不再一律折叠为 1
  # 同时清除 DEBNAS_MODULE_ACTION：该变量若从环境泄漏进来，受守卫的模块会跳过 main（静默不执行）
  local rc=0
  (unset _DEBNAS_BOOTSTRAPPED DEBNAS_MODULE_ACTION; bash "$module_path" "$@") || rc=$?
  return "$rc"
}

# ==================== Preflight 阶段 ====================
# 执行所有预检查：权限、版本、依赖、幂等性、依赖模块
# 返回：0=通过，1=失败，2=跳过（已安装/dry-run）

run_preflight() {
  local module_name="$1"

  # dry-run
  if ! preflight_dry_run "$module_name"; then
    return 2
  fi

  # root 权限
  if ! preflight_root; then
    return 1
  fi

  # Debian 版本
  local debian_min
  local arch_req
  debian_min=$(get_module_field "$module_name" "debian_min" "bookworm" 2>/dev/null) || debian_min="bookworm"
  arch_req=$(get_module_field "$module_name" "arch" "" 2>/dev/null) || arch_req=""
  if ! preflight_environment_check "$debian_min" "$arch_req"; then
    return 1
  fi

  # 交互式模块跳过依赖检查（由模块在操作时自行调用 ensure_module_deps）
  local interactive
  interactive=$(get_module_field "$module_name" "interactive" "false" 2>/dev/null) || interactive="false"
  if [[ "$interactive" == "true" ]]; then
    return 0
  fi

  log_info "开始 preflight 检查：${module_name}"

  # 依赖命令
  if ! preflight_dependencies "$module_name"; then
    return 1
  fi

  # 依赖模块（检查是否已就绪，不自动执行）
  # 例外：部署方案中批量执行时，依赖模块由方案编排顺序保证
  local dep_modules
  dep_modules=$(get_module_field "$module_name" "depend_modules" "" 2>/dev/null) || dep_modules=""
  if [[ -n "$dep_modules" ]]; then
    log_info "检查依赖模块：${dep_modules}"
    local -a not_ready=()
    mapfile -t not_ready < <(check_module_deps_ready "$module_name" 2>/dev/null) || not_ready=()
    if [[ ${#not_ready[@]} -gt 0 ]]; then
      log_error "以下依赖模块尚未完成，请先执行："
      local nd
      for nd in "${not_ready[@]}"; do
        local nd_name
        nd_name=$(get_module_field "$nd" "name" "$nd" 2>/dev/null) || nd_name="$nd"
        echo "  debnas run ${nd}   # ${nd_name}"
      done
      return 1
    fi
    log_info "依赖模块已全部就绪：${dep_modules}"
  fi

  return 0
}

# ==================== Report 阶段 ====================
# 记录模块执行结果到状态文件和日志

run_report() {
  local module_name="$1"
  local display_name="$2"
  local exit_code="$3"

  if [[ "$exit_code" -eq 0 ]]; then
    # 交互式菜单仅浏览未执行动作：不记录状态、不输出完成日志
    if [[ "${_DEBNAS_INTERACTIVE_TTY:-0}" -eq 1 && ! -f "${DEBNAS_ACTION_MARKER:-}" ]]; then
      log_stop_file 2>/dev/null || true
      return 0
    fi
    local version
    version=$(get_module_field "$module_name" "version" "" 2>/dev/null) || version=""
    state_mark_success "$module_name" "$version"
    log_success "${display_name}"
  else
    state_mark_fail "$module_name" "exit_code_${exit_code}"
    log_error "${display_name} 失败"
    local log_file
    log_file=$(get_log_file 2>/dev/null)
    if [[ -n "$log_file" ]]; then
      log_info "日志 → ${log_file}"
    fi
  fi

  log_stop_file 2>/dev/null || true
}

# ==================== 只读探测（status / plan） ====================
# 用法：module-runner.sh --probe status|plan <模块名>
# 以 DEBNAS_MODULE_ACTION=status|plan 加载模块，只调用 module_status / module_plan，
# 不执行模块 main、不做 preflight（无需 root）、不写状态与日志。契约见 docs/ARCHITECTURE.md §4.5
run_probe() {
  local action="${1:-}" module_name="${2:-}"
  if [[ "$action" != "status" && "$action" != "plan" ]] || [[ -z "$module_name" ]]; then
    echo "用法: module-runner.sh --probe status|plan <模块名>" >&2
    return 1
  fi
  discover_modules 2>/dev/null
  if ! module_exists "$module_name"; then
    log_error "模块不存在：${module_name}"
    return 1
  fi
  module_probe "$module_name" "$action"
}

# ==================== 主流程 ====================

main() {
  if [[ "${1:-}" == "--probe" ]]; then
    shift
    run_probe "$@"
    return $?
  fi

  # 解析全局参数
  parse_global_args "$@"

  # 获取剩余参数（通过全局数组传递，避免 eval）
  local -a args=("${DEBNAS_REMAINING_ARGS_ARRAY[@]+"${DEBNAS_REMAINING_ARGS_ARRAY[@]}"}")

  if [[ ${#args[@]} -eq 0 ]]; then
    log_error "未指定模块名"
    echo "用法: module-runner.sh <模块名> [参数...]"
    return 1
  fi

  local module_name="${args[0]}"
  local -a module_args=()
  if [[ ${#args[@]} -gt 1 ]]; then
    module_args=("${args[@]:1}")
  fi

  # 发现并验证模块
  discover_modules 2>/dev/null
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
  local preflight_rc=0
  run_preflight "$module_name" || preflight_rc=$?
  if [[ "$preflight_rc" -eq 1 ]]; then
    return 1
  elif [[ "$preflight_rc" -eq 2 ]]; then
    return 0
  fi

  # ── Initialize + Execute ──
  log_to_file "$module_name" 2>/dev/null || true

  # 交互式 TTY 模块：用动作标记区分“仅浏览菜单”和“真实执行动作”
  _DEBNAS_INTERACTIVE_TTY=0
  local interactive_marker=""
  local interactive
  interactive=$(get_module_field "$module_name" "interactive" "false" 2>/dev/null) || interactive="false"
  if [[ "$interactive" == "true" && -t 0 ]]; then
    _DEBNAS_INTERACTIVE_TTY=1
    interactive_marker=$(mktemp)
    export DEBNAS_ACTION_MARKER="$interactive_marker"
  else
    export DEBNAS_ACTION_MARKER=""
  fi

  local exit_code=0
  execute_module "$module_name" "${module_args[@]+"${module_args[@]}"}" || exit_code=$?

  # ── Report ──
  run_report "$module_name" "$display_name" "$exit_code"
  [[ -n "$interactive_marker" ]] && rm -f "$interactive_marker" 2>/dev/null || true

  return "$exit_code"
}

main "$@"
