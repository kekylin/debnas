#!/bin/bash
# 功能：模块只读探测契约（module_status / module_plan）加载器
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
# 依赖：module-registry.sh（get_module_path/get_module_field）、tempfile.sh（create_temp_file）

set -euo pipefail
IFS=$'\n\t'

# 守卫行：模块入口文件中有以此开头的行（行首、非注释）才视为支持探测
readonly MODULE_PROBE_GUARD_RE='^if \[\[ "\$\{DEBNAS_MODULE_ACTION:-run\}" == "run" \]\]'

# 合法取值
readonly MODULE_STATUS_CODES=" applied running partial absent warn error unknown "
readonly MODULE_PLAN_TYPES=" pkg write service port cron user risk info "

# 超时（秒，可被环境变量覆盖）
MODULE_PROBE_STATUS_TIMEOUT="${MODULE_PROBE_STATUS_TIMEOUT:-3}"
MODULE_PROBE_PLAN_TIMEOUT="${MODULE_PROBE_PLAN_TIMEOUT:-8}"

declare -g _MP_CLEAN=""

# ==================== 规范化 ====================

# 去除控制字符（含 ESC/CR/LF），防止模块输出破坏终端；结果写入 _MP_CLEAN（不经命令替换，逐行调用不 fork）
_module_probe_clean() {
  _MP_CLEAN="${1:-}"
  _MP_CLEAN="${_MP_CLEAN//$'\t'/ }"
  _MP_CLEAN="${_MP_CLEAN//[$'\001'-$'\037'$'\177']/}"
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
  _module_probe_clean "$desc"
  printf '%s|%s\n' "$code" "$_MP_CLEAN"
}

# 规范化 module_plan 输出
# 参数：$1 — 原始输出
# 输出：stdout 多行 "type|target|note"，非法类型归为 info，空行丢弃
module_plan_normalize() {
  local raw="${1:-}" line type target note rest
  while IFS= read -r line; do
    [[ -n "${line//[[:space:]]/}" ]] || continue
    _module_probe_clean "$line"; line="$_MP_CLEAN"
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
# 说明：只认行首的真正守卫行，注释或字符串里出现 DEBNAS_MODULE_ACTION 不算
# 参数：$1 — 模块名
# 返回：0 支持，1 不支持
module_probe_supported() {
  local module_name="${1:?module_probe_supported: 缺少模块名}"
  local path=""
  get_module_field_var path "$module_name" "path" || return 1
  [[ -f "$path" ]] || return 1
  grep -qE -- "$MODULE_PROBE_GUARD_RE" "$path" 2>/dev/null
}

# 回退结果（模块未加守卫或未实现对应函数）
# 参数：$1 — 模块名，$2 — status|plan，$3 — 原因（guard|func）
_module_probe_fallback() {
  local module_name="$1" action="$2"
  if [[ "$action" == "status" ]]; then
    printf 'unknown|未提供状态检测\n'
  else
    local interactive=""
    get_module_field_var interactive "$module_name" "interactive" "false" || interactive="false"
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

  local path="" tmp timeout rc=0
  get_module_field_var path "$module_name" "path"
  tmp=$(create_temp_file "module-probe" 2>/dev/null) || tmp=""
  if [[ -z "$tmp" ]]; then
    [[ "$action" == "status" ]] && printf 'unknown|无法创建临时文件\n' || printf 'info|%s|无法创建临时文件\n' "$module_name"
    return 0
  fi
  if [[ "$action" == "status" ]]; then timeout="$MODULE_PROBE_STATUS_TIMEOUT"; else timeout="$MODULE_PROBE_PLAN_TIMEOUT"; fi

  # 后台任务自成进程组，超时时连同其中的命令一起终止（不留孤儿）
  bg_group_begin
  ( _module_probe_exec "$path" "$action" "$module_name" ) > "$tmp" 2>/dev/null &
  local pid=$!
  bg_group_end
  _module_probe_wait "$pid" "$timeout" || rc=$?

  local raw=""
  { raw=$(< "$tmp"); } 2>/dev/null || raw=""
  [[ -n "$tmp" ]] && rm -f -- "$tmp"

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
  local pid="$1" timeout="$2" fd="" tick=0.01
  local deadline=$(( ${EPOCHREALTIME/[.,]/} / 1000 + timeout * 1000 ))
  # 睡眠用的空管道只打开一次（原实现每轮 <(:) 都 fork 一个子进程）；
  # 10ms 轮询：多数探测几十毫秒内结束，结束后最多再等一个周期
  # 2>/dev/null 必须放在 { } 上：不带命令的 exec 会把重定向永久作用于当前 shell（stderr 从此消失）
  { exec {fd}<> <(:); } 2>/dev/null || fd=""
  while kill -0 "$pid" 2>/dev/null; do
    if (( ${EPOCHREALTIME/[.,]/} / 1000 >= deadline )); then
      bg_group_kill "$pid"
      wait "$pid" 2>/dev/null || true
      [[ -n "$fd" ]] && exec {fd}>&-
      return 124
    fi
    if [[ -n "$fd" ]]; then
      read -rt "$tick" -u "$fd" 2>/dev/null || true
    else
      read -rt "$tick" <> <(:) 2>/dev/null || true
    fi
  done
  [[ -n "$fd" ]] && exec {fd}>&-
  local rc=0
  wait "$pid" 2>/dev/null || rc=$?
  return "$rc"
}
