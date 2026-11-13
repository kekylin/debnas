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

# DebNAS 可执行文件路径（正常由 layout.sh 定义；直接 source 本文件的测试使用默认值）
: "${DEBNAS_BIN:=/usr/local/bin/debnas}"

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
  # 表达式原样拼进 crontab：换行/回车可追加任意条目（read 只读第一行，后面几行会绕过校验），
  # % 在 crontab 命令字段中表示换行/标准输入，一律拒绝
  [[ "$schedule" != *[$'\n\r%']* ]] || return 1
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
# 输出：crontab 内容（无 crontab 时为空）
# 返回：0 成功或确认无 crontab；1 读取失败（权限/spool 损坏/命令不可用等）
# 说明：cron_register* 会以该内容为基线写回 crontab，读取失败若当成空会导致用户任务被覆盖；
#       仅当 cron 明确报告 "no crontab for <user>" 时才按空处理，其余失败一律返回 1。
_get_current_crontab() {
  local out="" err_file err="" rc=0
  err_file=$(mktemp 2>/dev/null) || err_file=""
  if [[ -n "$err_file" ]]; then
    out=$(crontab -l 2>"$err_file") || rc=$?
    err=$(<"$err_file") || err=""
    rm -f -- "$err_file"
  else
    out=$(crontab -l 2>/dev/null) || rc=$?
  fi
  if [[ $rc -eq 0 ]]; then
    # 保留行结构（末尾换行）：cron_state 等调用方用 while read 逐行读取，
    # 没有末尾换行时最后一行不会被 read 处理
    [[ -n "$out" ]] && printf '%s\n' "$out"
    return 0
  fi
  # Debian cron：无 crontab 时 stderr 为 "no crontab for <user>"
  if [[ "$err" == *"no crontab for"* ]]; then
    return 0
  fi
  printf '%s\n' "${err:-crontab -l 失败（退出码 ${rc}）}" >&2
  return 1
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

# 注册定时任务前确保 cron 可用：crontab 命令存在、cron 服务在运行并开机自启
# 说明：Debian 云镜像等最小化系统不带 cron；原先此时 crontab 写入失败只报"注册失败"，
#       或条目写进去了但 cron 服务没在跑、任务永远不执行
# 返回：0 可用；1 无法安装/启动（已输出明确错误）
# 依赖：apt_install_packages（apt.sh）、service_ensure（service.sh），均由 bootstrap-core.sh 加载
_cron_ensure_ready() {
  if ! command -v crontab &>/dev/null; then
    if [[ "${EUID:-$(id -u)}" -ne 0 ]] || ! declare -F apt_install_packages >/dev/null 2>&1; then
      log_error "未安装 cron（缺少 crontab 命令），无法注册定时任务；请先以 root 执行：apt install cron"
      return 1
    fi
    log_info "未安装 cron，正在安装（定时任务需要）..."
    if ! apt_install_packages cron || ! command -v crontab &>/dev/null; then
      log_error "cron 安装失败，无法注册定时任务；请手动执行 apt install cron 后重试"
      return 1
    fi
  fi
  # 服务状态只在 root + systemd 下处理；已在运行且已自启时不输出任何内容
  [[ "${EUID:-$(id -u)}" -eq 0 ]] && command -v systemctl &>/dev/null || return 0
  declare -F service_ensure >/dev/null 2>&1 || return 0
  if ! systemctl is-active --quiet cron 2>/dev/null; then
    if ! service_ensure cron started; then
      log_error "cron 服务未运行且启动失败，定时任务不会执行；请检查：systemctl status cron"
      return 1
    fi
  fi
  if ! systemctl is-enabled --quiet cron 2>/dev/null; then
    service_ensure cron enabled || log_warning "cron 服务未能设为开机自启，重启后定时任务不会执行"
  fi
  return 0
}

# ==================== 公共接口 ====================

# 注册模块的 cron 定时任务
# 参数：$1 - 模块名
#       $2 - cron 表达式（如 "0 */6 * * *"）
# 返回：0 成功，1 失败
# 说明：如果已存在相同模块的条目，则先移除再添加（幂等）
cron_register() {
  # 读改写 crontab 期间持锁（并发注册会丢掉对方刚写入的条目）
  if declare -F debnas_locked >/dev/null 2>&1 && [[ -z "${_DEBNAS_LOCKS_HELD[cron]:-}" ]]; then
    debnas_locked cron cron_register "$@"
    return
  fi
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

  # cron 未安装/未运行时先装好并启用（失败则明确报错，不留下一个不会执行的条目）
  _cron_ensure_ready || return 1

  # 构建 cron 命令（传递 DEBNAS_CRON_MODE=1 告知模块以非交互模式运行）
  local cron_cmd="${schedule} DEBNAS_CRON_MODE=1 ${DEBNAS_BIN} run ${module_name} ${marker}"

  # 获取当前 crontab，移除该模块的旧主条目
  # 读取失败时不能以空内容为基线写回（会覆盖用户任务），必须中止
  local current_crontab
  if ! current_crontab=$(_get_current_crontab); then
    log_error "无法读取当前 crontab，拒绝覆盖；请检查 cron 服务与 spool 权限"
    return 1
  fi

  # 只按主条目后缀 " run <模块> <标记>" 精确匹配；变体条目（run <模块> <参数> <标记>，
  # 如 ops-report 的年报）同样以标记结尾，按标记匹配会被一起删掉
  local new_crontab
  if ! new_crontab=$(printf '%s\n' "$current_crontab" | _cron_filter_out_marker " run ${module_name} ${marker}"); then
    log_error "过滤 crontab 失败，拒绝写入"
    return 1
  fi

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
  # 读改写 crontab 期间持锁（并发注册会丢掉对方刚写入的条目）
  if declare -F debnas_locked >/dev/null 2>&1 && [[ -z "${_DEBNAS_LOCKS_HELD[cron]:-}" ]]; then
    debnas_locked cron cron_register_variant "$@"
    return
  fi
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

  _cron_ensure_ready || return 1

  cron_cmd="${schedule} DEBNAS_CRON_MODE=1 ${DEBNAS_BIN} run ${module_name} ${command_args} ${marker}"
  # 读取失败时不能以空内容为基线写回（会覆盖用户任务），必须中止
  local current_crontab
  if ! current_crontab=$(_get_current_crontab); then
    log_error "无法读取当前 crontab，拒绝覆盖；请检查 cron 服务与 spool 权限"
    return 1
  fi

  if grep -Fxq -- "$cron_cmd" <<<"$current_crontab"; then
    return 0
  fi

  # 移除同一模块同调度但参数不同的旧条目，保留其他条目
  local new_crontab
  if ! new_crontab=$(printf '%s\n' "$current_crontab" | \
    _DEBNAS_CRON_MARKER="$marker" _DEBNAS_CRON_SCHED="$schedule" awk '
    BEGIN { m = ENVIRON["_DEBNAS_CRON_MARKER"]; ml = length(m); s = ENVIRON["_DEBNAS_CRON_SCHED"] }
    { line = $0; sub(/[[:space:]]+$/, "", line) }
    # 只删除调度字段完全相同（前 5 个字段）的旧变体；不能用 index($0, s)==1 前缀匹配，
    # 否则 "0 0 * * 1" 会误删 "0 0 * * 1,3"
    length(line) >= ml && substr(line, length(line) - ml + 1) == m && ($1 " " $2 " " $3 " " $4 " " $5) == s { next }
    { print }
  ' | sed '/^$/d'); then
    log_error "过滤 crontab 失败，拒绝写入"
    return 1
  fi

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
  # 读改写 crontab 期间持锁（并发注册会丢掉对方刚写入的条目）
  if declare -F debnas_locked >/dev/null 2>&1 && [[ -z "${_DEBNAS_LOCKS_HELD[cron]:-}" ]]; then
    debnas_locked cron cron_unregister "$@"
    return
  fi
  local module_name="${1:?cron_unregister: 缺少模块名}"
  local marker
  marker=$(_cron_entry_marker "$module_name")

  # 获取当前 crontab
  # 读取失败时不能用空内容继续（后续 crontab -r 可能删除整份任务），必须中止
  local current_crontab
  if ! current_crontab=$(_get_current_crontab); then
    log_error "无法读取当前 crontab，拒绝修改；请检查 cron 服务与 spool 权限"
    return 1
  fi

  # 检查是否存在该模块的条目（行尾精确匹配，避免误删同前缀模块）
  if ! printf '%s\n' "$current_crontab" | _cron_has_marker "$marker"; then
    return 0
  fi

  # 移除该模块的条目
  local new_crontab
  if ! new_crontab=$(printf '%s\n' "$current_crontab" | _cron_filter_out_marker "$marker"); then
    log_error "过滤 crontab 失败，拒绝修改"
    return 1
  fi

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
  # 只读查询：读取失败按空处理（不能因 set -e 终止列表命令）
  current_crontab=$(_get_current_crontab 2>/dev/null || true)

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
  # 只读查询：读取失败按“未注册”处理
  current_crontab=$(_get_current_crontab 2>/dev/null || true)

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
  done < <(_get_current_crontab 2>/dev/null || true)
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
  line=$(_get_current_crontab 2>/dev/null | grep -F -- " run ${module_name} ${marker}" | head -1) || true
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

