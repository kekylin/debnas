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
preflight_debian_version() {
  local debian_min="${1:-bookworm}"
  if ! verify_system_support 2>/dev/null; then
    log_error "需要 Debian 12+"
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
  local -a dep_cmds=()
  local cmd
  # 使用 read -ra 拆分逗号/空格分隔的依赖列表（IFS=$'\n\t' 下 $(...|tr) 分词不可靠）
  IFS=' ,' read -ra dep_cmds <<< "$depends_str"
  for cmd in "${dep_cmds[@]}"; do
    cmd="${cmd#"${cmd%%[![:space:]]*}"}"
    cmd="${cmd%"${cmd##*[![:space:]]}"}"
    [[ -n "$cmd" ]] || continue
    if ! command -v "$cmd" &>/dev/null; then
      missing_cmds+=("$cmd")
    fi
  done

  if [[ ${#missing_cmds[@]} -eq 0 ]]; then
    log_info "所有依赖命令已就绪：${depends_str}"
    return 0
  fi

  log_warning "缺少 ${missing_cmds[*]}"
  install_missing_dependencies "${missing_cmds[@]}" || true

  # 再次检查（安装失败只警告，不阻断 — 模块自身会处理缺失依赖）
  local -a still_missing=()
  for cmd in "${missing_cmds[@]}"; do
    if ! command -v "$cmd" &>/dev/null; then
      still_missing+=("$cmd")
    fi
  done

  if [[ ${#still_missing[@]} -gt 0 ]]; then
    log_warning "${still_missing[*]} 未装，模块自行处理"
  fi
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

  log_action "→ ${display_name}"

  # 通过 bash 子进程执行模块（清除 bootstrap 标记，让模块重新加载库）
  if (unset _DEBNAS_BOOTSTRAPPED; bash "$module_path" "$@"); then
    return 0
  else
    return 1
  fi
}

# ==================== Preflight 阶段 ====================
# 执行所有预检查：权限、版本、依赖、幂等性、依赖模块
# 返回：0=通过，1=失败，2=跳过（已安装/dry-run）

run_preflight() {
  local module_name="$1"

  log_info "开始 preflight 检查：${module_name}"

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
  debian_min=$(get_module_field "$module_name" "debian_min" "bookworm" 2>/dev/null) || debian_min="bookworm"
  if ! preflight_debian_version "$debian_min"; then
    return 1
  fi

  # 依赖命令
  if ! preflight_dependencies "$module_name"; then
    return 1
  fi

  # 依赖模块（始终自动执行，依赖模块自身负责幂等优化）
  local dep_modules
  dep_modules=$(get_module_field "$module_name" "depend_modules" "" 2>/dev/null) || dep_modules=""
  if [[ -n "$dep_modules" ]]; then
    log_info "解析模块依赖：${dep_modules}"
    local -a exec_order=()
    mapfile -t exec_order < <(resolve_module_deps "$module_name" 2>/dev/null) || exec_order=()
    if [[ ${#exec_order[@]} -eq 0 ]]; then
      # 回退解析：统一将逗号替换为空格后按空格拆分，兼容 "a,b" / "a, b" / "a b" 格式
      read -ra exec_order <<< "${dep_modules//,/ }"
    fi

    local dep single_dep
    local -a split_deps=()
    for dep in "${exec_order[@]+"${exec_order[@]}"}"; do
      split_deps=()
      IFS=' ,' read -ra split_deps <<< "$dep"
      for single_dep in "${split_deps[@]+"${split_deps[@]}"}"; do
        single_dep="${single_dep#"${single_dep%%[![:space:]]*}"}"
        single_dep="${single_dep%"${single_dep##*[![:space:]]}"}"
        [[ -n "$single_dep" ]] || continue
        [[ "$single_dep" == "$module_name" ]] && continue
        # 会话级去重：同一会话内依赖模块只执行一次
        local dep_stamp="/tmp/.debnas_dep_${single_dep}"
        if [[ -f "$dep_stamp" ]]; then
          log_info "依赖模块 ${single_dep} 已在本会话内执行过，跳过"
          continue
        fi
        # 幂等检查：如果依赖模块已安装，跳过
        if state_is_installed "$single_dep" 2>/dev/null; then
          log_info "${single_dep} 已完成，跳过"
          touch "$dep_stamp" 2>/dev/null || true
          continue
        fi

        log_action "→ ${single_dep}"
        if ! (unset _DEBNAS_BOOTSTRAPPED; bash "${_DEBNAS_ROOT}/bin/module-runner.sh" "$single_dep"); then
          log_error "${single_dep} 失败，跳过后续"
          return 1
        fi
        touch "$dep_stamp" 2>/dev/null || true
      done
    done
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

# ==================== 主流程 ====================

main() {
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

  local exit_code=0
  execute_module "$module_name" "${module_args[@]+"${module_args[@]}"}" || exit_code=$?

  # ── Report ──
  run_report "$module_name" "$display_name" "$exit_code"

  return "$exit_code"
}

main "$@"
