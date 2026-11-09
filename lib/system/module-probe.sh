#!/bin/bash
# 功能：模块只读探测契约（module_status / module_plan）加载器 + 状态缓存
# 说明：
#   模块可选实现两个只读函数（契约详见 docs/ARCHITECTURE.md §4.5）：
#     module_status  → 输出一行  状态码|简短说明
#                      状态码 ∈ applied running partial absent warn error unknown
#     module_plan    → 输出多行  类型|目标|备注
#                      类型   ∈ pkg write service port cron user risk info
#   加载机制：模块末尾的 main 调用改为受守卫形式
#     if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi
#   探测时在子 shell 中设置 DEBNAS_MODULE_ACTION=status|plan 后 source 模块，
#   只得到函数定义而不执行 main 与任何交互逻辑。
#   **未加守卫的模块绝不 source**（否则会直接执行 main），一律走回退结果。
# 依赖：module-registry.sh（get_module_path/get_module_field）、state.sh（state_get）

set -euo pipefail
IFS=$'\n\t'

# 守卫标记：模块入口文件包含此字符串才视为支持探测
readonly MODULE_PROBE_GUARD_MARK='DEBNAS_MODULE_ACTION:-run'

# 合法取值
readonly MODULE_STATUS_CODES=" applied running partial absent warn error unknown "
readonly MODULE_PLAN_TYPES=" pkg write service port cron user risk info "

# 超时（秒，可被环境变量覆盖）
MODULE_PROBE_STATUS_TIMEOUT="${MODULE_PROBE_STATUS_TIMEOUT:-3}"
MODULE_PROBE_PLAN_TIMEOUT="${MODULE_PROBE_PLAN_TIMEOUT:-8}"

# 状态缓存：模块名 → "code|desc"
declare -g -A _MODULE_STATUS=()
# 异步采集中的模块：模块名 → pid
declare -g -A _MODULE_PROBE_PIDS=()
declare -g _MODULE_PROBE_T0=""
declare -g _MODULE_PROBE_DIR=""

# ==================== 规范化 ====================

# 去除控制字符（含 ESC/CR/LF），防止模块输出破坏终端
_module_probe_clean() {
  local s="${1:-}"
  s="${s//$'\t'/ }"
  s="${s//[$'\001'-$'\037'$'\177']/}"
  printf '%s' "$s"
}

# 规范化 module_status 输出（取第一行非空行）
# 参数：$1 — 原始输出
# 输出：stdout 一行 "code|desc"，非法状态码归为 unknown
module_status_normalize() {
  local raw="${1:-}" line="" code desc
  while IFS= read -r line; do
    [[ -n "${line//[[:space:]]/}" ]] && break
  done <<< "$raw"
  if [[ -z "${line//[[:space:]]/}" ]]; then
    printf 'unknown|未返回状态\n'
    return 0
  fi
  code="${line%%|*}"
  if [[ "$line" == *"|"* ]]; then desc="${line#*|}"; else desc=""; fi
  code="${code//[[:space:]]/}"
  if [[ "$MODULE_STATUS_CODES" != *" ${code} "* ]]; then
    desc="${line}"
    code="unknown"
  fi
  printf '%s|%s\n' "$code" "$(_module_probe_clean "$desc")"
}

# 规范化 module_plan 输出
# 参数：$1 — 原始输出
# 输出：stdout 多行 "type|target|note"，非法类型归为 info，空行丢弃
module_plan_normalize() {
  local raw="${1:-}" line type target note rest
  while IFS= read -r line; do
    [[ -n "${line//[[:space:]]/}" ]] || continue
    line=$(_module_probe_clean "$line")
    type="${line%%|*}"
    if [[ "$line" == *"|"* ]]; then rest="${line#*|}"; else rest=""; fi
    target="${rest%%|*}"
    if [[ "$rest" == *"|"* ]]; then note="${rest#*|}"; else note=""; fi
    type="${type//[[:space:]]/}"
    if [[ "$MODULE_PLAN_TYPES" != *" ${type} "* ]]; then
      note="${line}"
      target="未识别的预演行"
      type="info"
    fi
    printf '%s|%s|%s\n' "$type" "$target" "$note"
  done <<< "$raw"
}

# ==================== 加载 ====================

# 判断模块是否已按契约加守卫（可安全 source）
# 参数：$1 — 模块名
# 返回：0 支持，1 不支持
module_probe_supported() {
  local module_name="${1:?module_probe_supported: 缺少模块名}"
  local path
  path=$(get_module_path "$module_name" 2>/dev/null) || return 1
  [[ -f "$path" ]] || return 1
  grep -qF "$MODULE_PROBE_GUARD_MARK" "$path" 2>/dev/null
}

# 回退结果（模块未加守卫或未实现对应函数）
# 参数：$1 — 模块名，$2 — status|plan，$3 — 原因（guard|func）
_module_probe_fallback() {
  local module_name="$1" action="$2"
  if [[ "$action" == "status" ]]; then
    printf 'unknown|未提供状态检测\n'
  else
    local interactive
    interactive=$(get_module_field "$module_name" "interactive" "false" 2>/dev/null) || interactive="false"
    if [[ "$interactive" == "true" ]]; then
      printf 'info|%s|未提供预演；交互式模块，执行时进入模块自身菜单\n' "$module_name"
    else
      printf 'info|%s|未提供预演；将直接执行模块\n' "$module_name"
    fi
  fi
}

# 在当前（子）shell 中加载模块并调用探测函数 —— 必须在子 shell 中调用
# 参数：$1 — 模块入口路径，$2 — status|plan，$3 — 模块名
_module_probe_exec() {
  local path="$1" action="$2" module_name="$3"
  export DEBNAS_MODULE_ACTION="$action"
  unset -f module_status module_plan 2>/dev/null || true
  # 已加载的库保持加载状态：模块内 source bootstrap.sh 会直接返回
  _DEBNAS_BOOTSTRAPPED=1
  # shellcheck disable=SC1090
  source "$path" </dev/null >/dev/null 2>&1 || return 3
  if [[ "$action" == "status" ]]; then
    declare -F module_status >/dev/null || { _module_probe_fallback "$module_name" status; return 0; }
    module_status </dev/null 2>/dev/null
  else
    declare -F module_plan >/dev/null || { _module_probe_fallback "$module_name" plan; return 0; }
    module_plan </dev/null 2>/dev/null
  fi
}

# 同步探测单个模块（带超时）
# 参数：$1 — 模块名，$2 — status|plan
# 输出：stdout 规范化结果（status 一行 / plan 多行）
# 返回：0（探测失败也返回 0，并输出 error/unknown 结果，保证调用方界面不受影响）
module_probe() {
  local module_name="${1:?module_probe: 缺少模块名}"
  local action="${2:?module_probe: 缺少动作}"
  case "$action" in status|plan) ;; *) log_error "未知探测动作：${action}"; return 2 ;; esac

  if ! module_exists "$module_name" 2>/dev/null; then
    [[ "$action" == "status" ]] && printf 'unknown|模块不存在\n' || printf 'info|%s|模块不存在\n' "$module_name"
    return 0
  fi
  if ! module_probe_supported "$module_name"; then
    _module_probe_fallback "$module_name" "$action"
    return 0
  fi

  local path tmp timeout rc=0
  path=$(get_module_path "$module_name")
  tmp=$(mktemp 2>/dev/null) || tmp=""
  if [[ -z "$tmp" ]]; then
    [[ "$action" == "status" ]] && printf 'unknown|无法创建临时文件\n' || printf 'info|%s|无法创建临时文件\n' "$module_name"
    return 0
  fi
  if [[ "$action" == "status" ]]; then timeout="$MODULE_PROBE_STATUS_TIMEOUT"; else timeout="$MODULE_PROBE_PLAN_TIMEOUT"; fi

  ( _module_probe_exec "$path" "$action" "$module_name" ) > "$tmp" 2>/dev/null &
  local pid=$!
  _module_probe_wait "$pid" "$timeout" || rc=$?

  local raw=""
  raw=$(cat "$tmp" 2>/dev/null) || raw=""
  [[ -n "$tmp" ]] && rm -f "$tmp"

  if [[ $rc -eq 124 ]]; then
    [[ "$action" == "status" ]] && printf 'unknown|状态检测超时\n' || printf 'info|%s|预演超时（>%ss），结果不完整\n' "$module_name" "$timeout"
    [[ "$action" == "plan" && -n "$raw" ]] && module_plan_normalize "$raw"
    return 0
  fi
  if [[ $rc -ne 0 && -z "$raw" ]]; then
    [[ "$action" == "status" ]] && printf 'error|状态检测失败（退出码 %s）\n' "$rc" || printf 'info|%s|预演失败（退出码 %s）\n' "$module_name" "$rc"
    return 0
  fi
  if [[ "$action" == "status" ]]; then
    module_status_normalize "$raw"
  else
    module_plan_normalize "$raw"
  fi
}

# 等待后台进程结束（超时则终止）
# 参数：$1 — pid，$2 — 超时秒数（整数）
# 返回：进程退出码；超时返回 124
_module_probe_wait() {
  local pid="$1" timeout="$2"
  local deadline=$(( ${EPOCHREALTIME/[.,]/} / 1000 + timeout * 1000 ))
  while kill -0 "$pid" 2>/dev/null; do
    if (( ${EPOCHREALTIME/[.,]/} / 1000 >= deadline )); then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    read -rt 0.02 <> <(:) 2>/dev/null || true
  done
  local rc=0
  wait "$pid" 2>/dev/null || rc=$?
  return "$rc"
}

# ==================== 状态缓存（仪表盘批量/异步采集） ====================

# 合并执行记录：模块未提供状态检测时，用 module-runner 写入的 state 文件补充
# 参数：$1 — 模块名，$2 — "code|desc"
# 输出：stdout 合并后的 "code|desc"
module_status_merge_state() {
  local module_name="$1" result="$2"
  local code="${result%%|*}"
  [[ "$code" == "unknown" ]] || { printf '%s\n' "$result"; return 0; }
  local last=""
  last=$(state_get "$module_name" "last_result" 2>/dev/null) || last=""
  case "$last" in
    success) printf 'applied|已执行（按 DebNAS 执行记录，模块未提供状态检测）\n' ;;
    fail)    printf 'error|上次执行失败（按 DebNAS 执行记录）\n' ;;
    *)       printf '%s\n' "$result" ;;
  esac
}

# 启动异步状态采集
# 参数：$1 — 缓存目录，其余 — 模块名列表
# 说明：每个支持契约的模块在独立后台子 shell 中探测，结果写 <dir>/<模块>.status；
#       不支持契约的模块立即写入回退结果（不 fork）
module_status_collect_start() {
  local dir="${1:?module_status_collect_start: 缺少缓存目录}"
  shift
  _MODULE_PROBE_DIR="$dir"
  _MODULE_PROBE_T0="${EPOCHREALTIME/[.,]/}"
  local module_name path
  for module_name in "$@"; do
    [[ -n "$module_name" ]] || continue
    # 已在采集中的先终止，避免旧结果覆盖
    if [[ -n "${_MODULE_PROBE_PIDS[$module_name]:-}" ]]; then
      kill "${_MODULE_PROBE_PIDS[$module_name]}" 2>/dev/null || true
      unset '_MODULE_PROBE_PIDS[$module_name]'
    fi
    rm -f "${dir}/${module_name}.status" 2>/dev/null || true
    if ! module_probe_supported "$module_name"; then
      _MODULE_STATUS["$module_name"]=$(module_status_merge_state "$module_name" "unknown|未提供状态检测")
      continue
    fi
    path=$(get_module_path "$module_name" 2>/dev/null) || continue
    _MODULE_STATUS["$module_name"]="pending|检测中"
    (
      raw=$( _module_probe_exec "$path" status "$module_name" 2>/dev/null ) || raw="${raw:-error|状态检测失败}"
      printf '%s\n' "$raw" > "${dir}/${module_name}.status.tmp" 2>/dev/null \
        && mv -f "${dir}/${module_name}.status.tmp" "${dir}/${module_name}.status" 2>/dev/null
    ) </dev/null >/dev/null 2>&1 &
    _MODULE_PROBE_PIDS["$module_name"]=$!
  done
  return 0
}

# 轮询异步采集结果，超时的终止并标记
# 参数：$1 — 超时秒数（可选，默认 MODULE_PROBE_STATUS_TIMEOUT）
# 返回：0 全部完成，1 仍有进行中的
module_status_collect_poll() {
  local timeout="${1:-$MODULE_PROBE_STATUS_TIMEOUT}"
  local dir="$_MODULE_PROBE_DIR" module_name raw now elapsed
  [[ ${#_MODULE_PROBE_PIDS[@]} -gt 0 ]] || return 0
  now="${EPOCHREALTIME/[.,]/}"
  elapsed=$(( (now - ${_MODULE_PROBE_T0:-$now}) / 1000 ))
  for module_name in "${!_MODULE_PROBE_PIDS[@]}"; do
    if [[ -f "${dir}/${module_name}.status" ]]; then
      raw=$(< "${dir}/${module_name}.status") || raw=""
      _MODULE_STATUS["$module_name"]=$(module_status_merge_state "$module_name" "$(module_status_normalize "$raw")")
      unset '_MODULE_PROBE_PIDS[$module_name]'
    elif ! kill -0 "${_MODULE_PROBE_PIDS[$module_name]}" 2>/dev/null; then
      # 进程已退出但没有结果文件（加载失败/被 set -e 终止）
      [[ -f "${dir}/${module_name}.status" ]] && continue
      _MODULE_STATUS["$module_name"]=$(module_status_merge_state "$module_name" "unknown|状态检测失败")
      unset '_MODULE_PROBE_PIDS[$module_name]'
    elif (( elapsed >= timeout * 1000 )); then
      kill "${_MODULE_PROBE_PIDS[$module_name]}" 2>/dev/null || true
      _MODULE_STATUS["$module_name"]=$(module_status_merge_state "$module_name" "unknown|状态检测超时")
      unset '_MODULE_PROBE_PIDS[$module_name]'
    fi
  done
  [[ ${#_MODULE_PROBE_PIDS[@]} -eq 0 ]]
}

# 终止全部进行中的采集（退出仪表盘时调用）
module_status_collect_stop() {
  local module_name
  for module_name in "${!_MODULE_PROBE_PIDS[@]}"; do
    kill "${_MODULE_PROBE_PIDS[$module_name]}" 2>/dev/null || true
  done
  _MODULE_PROBE_PIDS=()
  return 0
}

# 读取缓存的模块状态
# 参数：$1 — 模块名
# 输出：stdout "code|desc"（无缓存时 unknown）
module_status_get() {
  local module_name="${1:?module_status_get: 缺少模块名}"
  printf '%s\n' "${_MODULE_STATUS[$module_name]:-unknown|未检测}"
}
