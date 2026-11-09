#!/bin/bash
# 功能：Cron 定时任务统一管理模块
# 说明：提供模块定时任务的注册、注销和查询功能
# 设计：所有模块的 cron 任务通过本模块统一管理，不再由模块自行操作 crontab

set -euo pipefail
IFS=$'\n\t'

# 依赖: core/logging.sh（由 bootstrap.sh 加载）

# ==================== 常量定义 ====================

# cron 标识前缀（用于在 crontab 中标记 DebNAS 管理的条目）
readonly CRON_MARKER="# DEBNAS-CRON:"

# DebNAS 可执行文件路径
readonly DEBNAS_BIN="${DEBNAS_BIN:-/usr/local/bin/debnas}"

# ==================== 内部函数 ====================

# 校验 cron 单个字段
# 参数：$1 - 字段值，$2 - 最小值，$3 - 最大值
# 返回：0 合法，1 非法
_cron_field_valid() {
  local field="$1" min="$2" max="$3" part
  local -a parts=()
  [[ -n "$field" ]] || return 1
  IFS=',' read -ra parts <<< "$field"
  [[ ${#parts[@]} -gt 0 ]] || return 1
  for part in "${parts[@]}"; do
    if [[ "$part" == "*" ]]; then
      continue
    fi
    # 数值统一按十进制解析（10#），否则 "08"/"09" 会被当作非法八进制报错
    if [[ "$part" =~ ^\*/([0-9]{1,4})$ ]]; then
      (( 10#${BASH_REMATCH[1]} >= 1 )) || return 1
      continue
    fi
    if [[ "$part" =~ ^([0-9]{1,4})-([0-9]{1,4})(/([0-9]{1,4}))?$ ]]; then
      local lo=$((10#${BASH_REMATCH[1]})) hi=$((10#${BASH_REMATCH[2]}))
      (( lo >= min && hi <= max && lo <= hi )) || return 1
      if [[ -n "${BASH_REMATCH[4]}" ]]; then
        (( 10#${BASH_REMATCH[4]} >= 1 )) || return 1
      fi
      continue
    fi
    [[ "$part" =~ ^[0-9]{1,4}$ ]] || return 1
    (( 10#$part >= min && 10#$part <= max )) || return 1
  done
  return 0
}

# 校验 cron 表达式（5 个字段，含字段值范围）
# 参数：$1 - cron 表达式
# 返回：0 合法，1 非法
cron_validate_schedule() {
  local schedule="$1"
  local -a fields
  local IFS=' '
  read -r -a fields <<< "$schedule"
  [[ ${#fields[@]} -eq 5 ]] || return 1
  _cron_field_valid "${fields[0]}" 0 59 || return 1
  _cron_field_valid "${fields[1]}" 0 23 || return 1
  _cron_field_valid "${fields[2]}" 1 31 || return 1
  _cron_field_valid "${fields[3]}" 1 12 || return 1
  _cron_field_valid "${fields[4]}" 0 7 || return 1
  return 0
}

# 构建 cron 条目标识
# 参数：$1 - 模块名
# 输出：cron 条目的标记字符串
_cron_entry_marker() {
  local module_name="$1"
  echo "${CRON_MARKER} ${module_name}"
}

# 校验模块名（模块名会原样拼入 crontab 命令行，必须禁止 shell 元字符）
# 参数：$1 - 模块名
# 返回：0 合法，1 非法
_cron_valid_module_name() {
  [[ "$1" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]]
}

# 从 crontab 内容中剔除以指定标记结尾的行（精确匹配模块名）
# 说明：旧实现用 grep -v "<marker>" 子串匹配，"# DEBNAS-CRON: cockpit" 会误删
#       cockpit-ext / cockpit-net 的条目，这里改为行尾精确匹配。
# 参数：$1 - 标记字符串；stdin - crontab 内容
# 输出：剔除后的内容
_cron_filter_out_marker() {
  _DEBNAS_CRON_MARKER="$1" awk '
    BEGIN { m = ENVIRON["_DEBNAS_CRON_MARKER"]; ml = length(m) }
    { line = $0; sub(/[[:space:]]+$/, "", line) }
    length(line) >= ml && substr(line, length(line) - ml + 1) == m { next }
    { print }
  '
}

# 判断 crontab 内容中是否存在以指定标记结尾的行
# 参数：$1 - 标记字符串；stdin - crontab 内容
# 返回：0 存在，1 不存在
_cron_has_marker() {
  _DEBNAS_CRON_MARKER="$1" awk '
    BEGIN { m = ENVIRON["_DEBNAS_CRON_MARKER"]; ml = length(m); found = 0 }
    { line = $0; sub(/[[:space:]]+$/, "", line) }
    length(line) >= ml && substr(line, length(line) - ml + 1) == m { found = 1 }
    END { exit(found ? 0 : 1) }
  '
}

# 获取当前用户的 crontab 内容
# 参数：无
# 输出：crontab 内容
_get_current_crontab() {
  crontab -l 2>/dev/null || true
}

# 写入 crontab
# 参数：$1 - crontab 内容（通过 stdin 传入）
# 返回：0 成功，1 失败
_set_crontab() {
  if crontab - 2>/dev/null; then
    return 0
  else
    return 1
  fi
}

# ==================== 公共接口 ====================

# 注册模块的 cron 定时任务
# 参数：$1 - 模块名
#       $2 - cron 表达式（如 "0 */6 * * *"）
# 返回：0 成功，1 失败
# 说明：如果已存在相同模块的条目，则先移除再添加（幂等）
cron_register() {
  local module_name="${1:?cron_register: 缺少模块名}"
  local schedule="${2:?cron_register: 缺少 cron 表达式}"
  local marker
  marker=$(_cron_entry_marker "$module_name")

  if ! _cron_valid_module_name "$module_name"; then
    log_error "非法的模块名：${module_name}"
    return 1
  fi

  # 验证 cron 表达式格式（5 个字段 + 字段值范围）
  if ! cron_validate_schedule "$schedule"; then
    return 1
  fi

  # 构建 cron 命令（传递 DEBNAS_CRON_MODE=1 告知模块以非交互模式运行）
  local cron_cmd="${schedule} DEBNAS_CRON_MODE=1 ${DEBNAS_BIN} run ${module_name} ${marker}"

  # 获取当前 crontab，移除该模块的旧条目
  local current_crontab
  current_crontab=$(_get_current_crontab)

  # 移除旧条目并添加新条目
  local new_crontab
  new_crontab=$(printf '%s\n' "$current_crontab" | _cron_filter_out_marker "$marker" || true)

  # 追加新条目（确保末尾有换行）
  if [[ -n "$new_crontab" ]]; then
    new_crontab="${new_crontab}
${cron_cmd}"
  else
    new_crontab="${cron_cmd}"
  fi

  # 写入 crontab
  if echo "$new_crontab" | _set_crontab; then
    return 0
  else
    return 1
  fi
}

# 为同一模块注册额外的 cron 变体条目（不替换主调度条目）
# 参数：$1 - 模块名，$2 - cron 表达式，$3 - 附加命令参数
# 返回：0 成功，1 失败
cron_register_variant() {
  local module_name="${1:?cron_register_variant: 缺少模块名}"
  local schedule="${2:?cron_register_variant: 缺少 cron 表达式}"
  local command_args="${3:-}"
  local marker cron_cmd
  marker=$(_cron_entry_marker "$module_name")

  if ! _cron_valid_module_name "$module_name"; then
    log_error "非法的模块名：${module_name}"
    return 1
  fi
  # 附加参数原样拼入 crontab 命令行，仅允许安全字符（禁止 ; | & $ ` 等 shell 元字符）
  if [[ ! "$command_args" =~ ^[A-Za-z0-9_\ =.,/:-]*$ ]]; then
    log_error "非法的定时任务参数：${command_args}"
    return 1
  fi

  if ! cron_validate_schedule "$schedule"; then
    return 1
  fi

  cron_cmd="${schedule} DEBNAS_CRON_MODE=1 ${DEBNAS_BIN} run ${module_name} ${command_args} ${marker}"
  local current_crontab
  current_crontab=$(_get_current_crontab)

  if grep -Fxq -- "$cron_cmd" <<<"$current_crontab"; then
    return 0
  fi

  # 移除同一模块同调度但参数不同的旧条目，保留其他条目
  local new_crontab
  new_crontab=$(printf '%s\n' "$current_crontab" | \
    _DEBNAS_CRON_MARKER="$marker" _DEBNAS_CRON_SCHED="$schedule" awk '
    BEGIN { m = ENVIRON["_DEBNAS_CRON_MARKER"]; ml = length(m); s = ENVIRON["_DEBNAS_CRON_SCHED"] }
    { line = $0; sub(/[[:space:]]+$/, "", line) }
    length(line) >= ml && substr(line, length(line) - ml + 1) == m && index($0, s) == 1 { next }
    { print }
  ' | sed '/^$/d' || true)

  if [[ -n "$new_crontab" ]]; then
    new_crontab="${new_crontab}
${cron_cmd}"
  else
    new_crontab="${cron_cmd}"
  fi

  if printf '%s\n' "$new_crontab" | _set_crontab; then
    return 0
  fi
  return 1
}

# 注销模块的 cron 定时任务
# 参数：$1 - 模块名
# 返回：0 成功（包括原本不存在的情况），1 操作失败
cron_unregister() {
  local module_name="${1:?cron_unregister: 缺少模块名}"
  local marker
  marker=$(_cron_entry_marker "$module_name")

  # 获取当前 crontab
  local current_crontab
  current_crontab=$(_get_current_crontab)

  # 检查是否存在该模块的条目（行尾精确匹配，避免误删同前缀模块）
  if ! printf '%s\n' "$current_crontab" | _cron_has_marker "$marker"; then
    return 0
  fi

  # 移除该模块的条目
  local new_crontab
  new_crontab=$(printf '%s\n' "$current_crontab" | _cron_filter_out_marker "$marker" || true)

  # 写入 crontab（如果为空则移除整个 crontab）
  if [[ -z "$new_crontab" ]]; then
    crontab -r 2>/dev/null || true
  else
    if ! echo "$new_crontab" | _set_crontab; then
      return 1
    fi
  fi

  return 0
}

# 列出所有 DebNAS 管理的 cron 定时任务
# 参数：无
# 输出：格式化的任务列表（每行：模块名 | cron 表达式 | 命令）
# 返回：始终 0
cron_list() {
  local current_crontab
  current_crontab=$(_get_current_crontab)

  if [[ -z "$current_crontab" ]]; then
    echo "无定时任务"
    return 0
  fi

  local debnas_entries
  debnas_entries=$(echo "$current_crontab" | grep "${CRON_MARKER}" || true)

  if [[ -z "$debnas_entries" ]]; then
    echo "无定时任务"
    return 0
  fi

  echo "定时任务"
  echo "─────────────────────────────────────────────────"

  local line module_name f1 f2 f3 f4 f5
  while IFS= read -r line; do
    # 提取模块名（最后一个标记之后的内容，去掉前导空格）
    module_name="${line##*"${CRON_MARKER}"}"
    module_name="${module_name#"${module_name%%[! ]*}"}"
    # 提取 cron 表达式（前 5 个字段）
    IFS=$' \t' read -r f1 f2 f3 f4 f5 _ <<< "$line"
    printf "  %-30s %s %s %s %s %s\n" "$module_name" "$f1" "$f2" "$f3" "$f4" "$f5"
  done <<< "$debnas_entries"

  echo "─────────────────────────────────────────────────"
  return 0
}

# 检查模块是否已注册 cron 任务
# 参数：$1 - 模块名
# 返回：0 已注册，1 未注册
cron_is_registered() {
  local module_name="${1:?cron_is_registered: 缺少模块名}"
  local marker
  marker=$(_cron_entry_marker "$module_name")
  local current_crontab
  current_crontab=$(_get_current_crontab)

  printf '%s\n' "$current_crontab" | _cron_has_marker "$marker"
}

# 当前进程能否读取 root crontab（DebNAS 定时任务都写在 root crontab）
# 返回：0 能（root），1 不能（拆成函数便于测试覆盖）
_cron_can_read_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]]
}

# 查询模块定时任务状态（只读，供 module_status / module_plan 使用，不报错不打日志）
# 参数：$1 - 模块名
#       $2 - 变体附加参数（可选，即 cron_register_variant 的第 3 个参数；省略时查该模块的任意条目）
# 输出：on（已注册）/ off（未注册或系统无 crontab 命令）/ unknown（非 root 无法读取 root crontab）
# 返回：始终 0
cron_state() {
  local module_name="${1:?cron_state: 缺少模块名}"
  local variant="${2:-}" marker line suffix
  if ! _cron_can_read_root; then
    echo "unknown"
    return 0
  fi
  if ! command -v crontab >/dev/null 2>&1; then
    echo "off"
    return 0
  fi
  marker="${CRON_MARKER} ${module_name}"
  if [[ -n "$variant" ]]; then
    suffix=" run ${module_name} ${variant} ${marker}"
  else
    suffix="${marker}"
  fi
  while IFS= read -r line; do
    # 与 _cron_has_marker 相同：去掉行尾空白后按后缀精确匹配（避免 cockpit 误配 cockpit-ext）
    line="${line%"${line##*[![:space:]]}"}"
    if [[ "$line" == *"$suffix" ]]; then
      echo "on"
      return 0
    fi
  done < <(_get_current_crontab)
  echo "off"
  return 0
}

# 获取模块当前 cron 表达式
# 参数：$1 - 模块名
# 输出：cron 表达式；未注册时输出空
# 返回：0 已注册，1 未注册
cron_get_schedule() {
  local module_name="${1:?cron_get_schedule: 缺少模块名}"
  local marker line
  marker=$(_cron_entry_marker "$module_name")
  # 只取主调度条目（"run <模块> <标记>"），跳过带附加参数的变体条目
  line=$(_get_current_crontab | grep -F -- " run ${module_name} ${marker}" | head -1) || true
  [[ -n "$line" ]] || return 1
  local f1 f2 f3 f4 f5
  IFS=$' \t' read -r f1 f2 f3 f4 f5 _ <<< "$line"
  echo "${f1} ${f2} ${f3} ${f4} ${f5}"
}

# 将常见 cron 表达式转换为可读描述
# 参数：$1 - cron 表达式
# 输出：可读描述；无法识别时返回原始表达式
cron_describe() {
  local schedule="$1"
  case "$schedule" in
    "0 0 * * *")  echo "每天 00:00" ;;
    "0 0 * * 1")  echo "每周一 00:00" ;;
    "0 1 * * 1")  echo "每周一 01:00" ;;
    "0 2 1 1 *")  echo "每年 1 月 1 日 02:00" ;;
    "0 0 * * 0"|"0 0 * * 7") echo "每周日 00:00" ;;
    "0 * * * *")  echo "每小时整点" ;;
    "0 */6 * * *") echo "每 6 小时" ;;
    *) echo "$schedule" ;;
  esac
}

# 统一展示模块定时任务状态
# 参数：$1 - 模块名
# 输出：模块显示名、状态、调度与可读描述
cron_show_status() {
  local module_name="${1:?cron_show_status: 缺少模块名}"
  local display_name
  display_name=$(get_module_field "$module_name" "name" "$module_name" 2>/dev/null) || display_name="$module_name"

  echo "模块：${display_name}"
  if cron_is_registered "$module_name"; then
    local schedule
    schedule=$(cron_get_schedule "$module_name") || schedule=""
    echo "状态：已启用"
    echo "调度：${schedule}（$(cron_describe "$schedule")）"
  else
    echo "状态：未启用"
  fi
}

# 交互式启用定时任务：先询问时间，再自动补齐功能并注册
# 参数：$1 - 模块名
# 返回：0 成功，1 失败
cron_enable_interactive() {
  local module_name="${1:?cron_enable_interactive: 缺少模块名}"
  local default_cron="0 0 * * *" input schedule

  input=$(ui_input "请输入定时表达式（留空使用默认每天 00:00）" "$default_cron")
  if [[ -z "$input" ]]; then
    schedule="$default_cron"
  elif cron_validate_schedule "$input"; then
    schedule="$input"
  else
    log_warning "无效定时表达式：${input}，使用默认：${default_cron}"
    schedule="$default_cron"
  fi

  if ! feature_enabled "$module_name"; then
    log_warning "$(_cron_display_name "$module_name") 功能未启用，将自动启用"
    if ! (unset _DEBNAS_BOOTSTRAPPED; trap - INT; bash "${DEBNAS_ROOT}/bin/module-runner.sh" "$module_name" enable); then
      log_error "自动启用 $(_cron_display_name "$module_name") 失败"
      return 1
    fi
  fi

  if cron_register "$module_name" "$schedule"; then
    log_success "已启用 $(_cron_display_name "$module_name") 定时任务：${schedule}（$(cron_describe "$schedule")）"
    module_mark_action
  else
    log_error "定时任务注册失败"
    return 1
  fi
  return 0
}

# 模块内“定时设置”统一菜单
# 参数：$1 - 模块名
# 返回：0 返回上级，1 失败
cron_settings_menu() {
  local module_name="${1:?cron_settings_menu: 缺少模块名}"
  local display_name
  display_name=$(_cron_display_name "$module_name")
  local -a items=("启用定时任务（默认每天 00:00）" "禁用定时任务")

  while true; do
    local choice exit_code menu_result
    menu_result=$(mktemp)
    UI_MENU_BLANK_BEFORE=1 UI_MENU_BACK_LABEL="← 返回上级" UI_MENU_RESULT_FILE="$menu_result" ui_menu "${display_name} 定时设置" "${items[@]}" || {
      exit_code=$?
      rm -f "$menu_result"
      case $exit_code in
        254) return 0 ;;   # Esc：返回上级
        255) return 0 ;;   # Q：退出
        *)   continue ;;
      esac
    }
    choice=$(cat "$menu_result")
    rm -f "$menu_result"
    case "$choice" in
      0) cron_enable_interactive "$module_name" ;;
      1)
        if cron_unregister "$module_name"; then
          log_success "已禁用 ${display_name} 定时任务"
          module_mark_action
        else
          log_error "定时任务移除失败"
        fi
        ;;
    esac
  done
}

# 获取模块显示名（供 cron 管理函数内部使用）
_cron_display_name() {
  local module_name="$1"
  get_module_field "$module_name" "name" "$module_name" 2>/dev/null || echo "$module_name"
}
