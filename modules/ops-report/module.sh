#!/bin/bash
# @module: ops-report
# @name: 运维报告
# @category: 系统维护
# @depends: sar,sadc,smartctl
# @version: 1.0.0
# @order: 70
# @interactive: true
# @cron: true
# @cron_schedule: 0 1 * * 1
# 功能：按周/月/半年/年生成服务器阶段性运维报告

set -euo pipefail
IFS=$'\n\t'

export LANG="C.UTF-8"
export LC_ALL="C.UTF-8"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/bootstrap.sh"

# ==================== 代码常量 ====================
readonly OPS_DEFAULT_PERIOD=7
readonly OPS_EMAIL_ENABLED=1
# shellcheck disable=SC2034  # 被 notify.sh 使用
readonly OPS_EMAIL_ATTACH_HTML=1
# shellcheck disable=SC2034  # 被 notify.sh 使用
readonly OPS_EMAIL_MAX_ATTACH_BYTES=2097152
readonly OPS_REPORT_DIR="/var/lib/debnas/ops-report"
readonly OPS_REPORTS_DIR="${OPS_REPORT_DIR}/reports"
# shellcheck disable=SC2034  # 被 setup.sh/report.sh/security.sh 使用
readonly OPS_SNAPSHOT_DIR="${OPS_REPORT_DIR}/snapshots"
readonly OPS_SYSSTAT_HISTORY=400
# shellcheck disable=SC2034  # 被 services.sh 使用
readonly OPS_INCLUDE_DOCKER=1
# shellcheck disable=SC2034  # 被 services.sh 使用
readonly OPS_INCLUDE_VM=1
# shellcheck disable=SC2034  # 被 health.sh 使用
readonly OPS_INCLUDE_SMART=1
readonly OPS_SYSSTAT_DEFAULT="/etc/default/sysstat"
readonly OPS_SYSSTAT_CONFIG="/etc/sysstat/sysstat"
readonly OPS_LOGROTATE_CONFIG="/etc/logrotate.d/debnas-ops-report"

# ==================== 加载子模块 ====================
source "${MODULE_DIR}/setup.sh"
source "${MODULE_DIR}/health.sh"
source "${MODULE_DIR}/security.sh"
source "${MODULE_DIR}/services.sh"
source "${MODULE_DIR}/report.sh"
source "${MODULE_DIR}/notify.sh"

# ==================== 参数解析 ====================
ops_period_to_days() {
  local period="${1:-}"
  case "$period" in
    "7d"|"1w"|"7")  echo "7" ;;
    "30d"|"1m"|"30") echo "30" ;;
    "365d"|"1y"|"365") echo "365" ;;
    "")
      echo "${OPS_DEFAULT_PERIOD}"
      ;;
    *)
      log_warning "无效报告周期：${period}，回退到 ${OPS_DEFAULT_PERIOD} 天"
      echo "${OPS_DEFAULT_PERIOD}"
      ;;
  esac
}

ops_parse_report_options() {
  local period="" email="${OPS_EMAIL_ENABLED:-1}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --period)
        shift
        if [[ $# -gt 0 ]]; then
          period="$1"
          shift
        else
          log_warning "--period 缺少参数，使用默认 7 天"
        fi
        ;;
      --email|-e)
        email=1
        shift
        ;;
      --no-email)
        email=0
        shift
        ;;
      *)
        shift
        ;;
    esac
  done

  local days
  days=$(ops_period_to_days "$period")
  printf '%s %s' "$days" "$email"
}

ops_generate_from_args() {
  local parsed days email
  parsed=$(ops_parse_report_options "$@")
  IFS=' ' read -r days email <<< "$parsed"
  ops_generate_report "$days" "$email"
}

ops_cron_generate_from_args() {
  local parsed days email
  parsed=$(ops_parse_report_options "$@")
  IFS=' ' read -r days email <<< "$parsed"

  ops_set_coverage "$days"
  if [[ "${OPS_SYSSTAT_DATA_DAYS:-0}" -lt "$days" ]]; then
    log_warning "定时报告跳过：sysstat 数据仅 ${OPS_SYSSTAT_DATA_DAYS:-0} 天，不足 ${days} 天"
    state_set "ops-report" "schedule_skip" "data_insufficient"
    state_set "ops-report" "schedule_skip_at" "$(date '+%Y-%m-%dT%H:%M:%S%z')"
    return 0
  fi

  ops_generate_report "$days" "$email"
}

# ==================== 定时报告 ====================
ops_register_cron_tasks() {
  # 周报为模块主调度；年报通过独立 cron 条目实现日期固定任务
  if ! cron_register "ops-report" "0 1 * * 1"; then
    log_error "周报定时任务注册失败"
    return 1
  fi
  if ! cron_register_variant "ops-report" "0 2 1 1 *" "--period 1y --email"; then
    log_error "年度报告定时任务注册失败"
    return 1
  fi
  return 0
}

ops_setup_and_enable() {
  if ! ops_setup_enable; then
    log_error "运维报告环境初始化失败"
    return 1
  fi
  if ! ops_register_cron_tasks; then
    return 1
  fi
  feature_enable "ops-report"
  log_success "定时报告已启用（周一 01:00 周报；1 月 1 日 02:00 年报）"
  log_info "首个 7 天报告将在 sysstat 覆盖满 7 天后可用；数据不足时定时任务自动跳过"
  module_mark_action
  return 0
}

ops_pause_schedule() {
  if ! cron_unregister "ops-report"; then
    log_error "定时报告暂停失败"
    return 1
  fi
  log_success "定时报告已暂停，手动生成不受影响"
  module_mark_action
  return 0
}

ops_resume_schedule() {
  if ! ops_register_cron_tasks; then
    log_error "定时报告恢复失败"
    return 1
  fi
  log_success "定时报告已恢复（周一 01:00 周报；1 月 1 日 02:00 年报）"
  module_mark_action
  return 0
}

ops_disable_module() {
  cron_unregister "ops-report" || true
  feature_disable "ops-report"
  log_success "运维报告已停用；历史报告和采集数据已保留"
  module_mark_action
  return 0
}

# ==================== 交互菜单 ====================
ops_generate_interactive() {
  local days="$1"
  # 默认直接发送邮件；未配置通知邮箱时由 notify.sh 自动跳过
  ops_generate_report "$days" 1
}

ops_data_status() {
  ops_data_readiness
  printf '\n'
  log_info "运维报告数据覆盖状态"
  printf '  sysstat 覆盖：%s 天，最早 %s\n' "${OPS_SYSSTAT_DATA_DAYS:-0}" "${OPS_DATA_START:-无数据}"

  local -a available=()
  [[ "${OPS_READY_7:-0}" -eq 1 ]] && available+=("7 天")
  [[ "${OPS_READY_30:-0}" -eq 1 ]] && available+=("30 天")
  [[ "${OPS_READY_365:-0}" -eq 1 ]] && available+=("365 天")
  if [[ ${#available[@]} -gt 0 ]]; then
    printf '  可生成报告：%s\n' "${available[*]}"
  else
    printf '  可生成报告：暂无（数据不足 7 天）\n'
    printf '  进度：数据满 7 天后开放 7 天报告，满 30/365 天依次开放对应周期。\n'
  fi

  if cron_is_registered "ops-report"; then
    printf '  定时报告：已开启（周一 01:00 周报；1 月 1 日 02:00 年报）\n'
    if [[ "${OPS_SYSSTAT_DATA_DAYS:-0}" -lt 7 ]]; then
      printf '  说明：数据不足 7 天时定时任务自动跳过，不发送不完整报告。\n'
    fi
  else
    printf '  定时报告：已暂停\n'
  fi
  ops_login_data_start
  printf '  登录日志：自 %s\n' "${OPS_LOGIN_DATA_START:-无数据}"
  module_mark_action
}

ops_data_readiness() {
  ops_set_coverage 365
  OPS_READY_7=0
  OPS_READY_30=0
  OPS_READY_365=0
  [[ "${OPS_SYSSTAT_DATA_DAYS:-0}" -ge 7 ]] && OPS_READY_7=1
  [[ "${OPS_SYSSTAT_DATA_DAYS:-0}" -ge 30 ]] && OPS_READY_30=1
  [[ "${OPS_SYSSTAT_DATA_DAYS:-0}" -ge 365 ]] && OPS_READY_365=1
}

ops_menu() {
  local -a items=(
    "启用定时报告"
    "禁用定时报告"
    "生成最近 7 天报告"
    "生成最近 30 天报告"
    "生成最近 365 天报告"
  )
  while true; do
    local choice exit_code menu_result
    menu_result=$(mktemp)
    UI_MENU_BLANK_BEFORE=1 UI_MENU_BACK_LABEL="← 返回上级" \
      UI_MENU_RESULT_FILE="$menu_result" ui_menu "运维报告" "${items[@]}" || {
        exit_code=$?
        rm -f "$menu_result"
        case "$exit_code" in
          254) return 0 ;;
          255) return 0 ;;
          *)   continue ;;
        esac
    }
    choice=$(<"$menu_result")
    rm -f "$menu_result"
    case "$choice" in
      0) ops_setup_and_enable ;;
      1) ops_pause_schedule ;;
      2) ops_generate_interactive 7 ;;
      3) ops_generate_interactive 30 ;;
      4) ops_generate_interactive 365 ;;
    esac
  done
}

# ==================== 只读探测契约（docs/ARCHITECTURE.md §4.5） ====================

# 最近一次报告时间（来自 state 的 report_file 文件名；无记录输出空）
_ops_last_report_time() {
  local file base
  file=$(state_get "ops-report" "report_file" 2>/dev/null) || file=""
  [[ -n "$file" ]] || return 0
  base="${file##*/}"
  if [[ "$base" =~ ([0-9]{8})-([0-9]{6})\.html$ ]]; then
    printf '%s-%s-%s %s:%s' "${BASH_REMATCH[1]:0:4}" "${BASH_REMATCH[1]:4:2}" "${BASH_REMATCH[1]:6:2}" \
      "${BASH_REMATCH[2]:0:2}" "${BASH_REMATCH[2]:2:2}"
  fi
}

_ops_sysstat_active() {
  command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet sysstat 2>/dev/null
}

# 当前状态：一行 "状态码|说明"（只读、< 300ms、不联网）
module_status() {
  local cron enabled=0 last sysstat_desc last_desc
  cron=$(cron_state "ops-report")
  feature_enabled "ops-report" 2>/dev/null && enabled=1
  last=$(_ops_last_report_time)
  last_desc="${last:+最近报告 ${last}}"
  last_desc="${last_desc:-尚无报告}"

  if ! command -v sar >/dev/null 2>&1; then
    sysstat_desc="sysstat 未安装"
  elif _ops_sysstat_active; then
    sysstat_desc="sysstat 运行中"
  else
    sysstat_desc="sysstat 未运行"
  fi

  case "$cron" in
    on)
      if [[ "$sysstat_desc" != "sysstat 运行中" ]]; then
        echo "warn|定时报告已启用 · ${sysstat_desc} · ${last_desc}"
      else
        echo "running|定时报告已启用 · ${sysstat_desc} · ${last_desc}"
      fi
      ;;
    off)
      if [[ "$enabled" -eq 1 ]]; then
        echo "partial|定时报告已暂停 · ${sysstat_desc} · ${last_desc}"
      elif [[ -n "$last" ]]; then
        echo "partial|未启用定时报告 · ${sysstat_desc} · ${last_desc}"
      else
        echo "absent|未启用 · ${sysstat_desc}"
      fi
      ;;
    *)
      if [[ "$enabled" -eq 1 ]]; then
        echo "applied|已启用（定时任务需 root 查看）· ${sysstat_desc} · ${last_desc}"
      elif [[ -n "$last" ]]; then
        echo "partial|已生成过报告（定时任务需 root 查看）· ${sysstat_desc} · ${last_desc}"
      else
        echo "unknown|定时任务需 root 查看 · ${sysstat_desc} · ${last_desc}"
      fi
      ;;
  esac
}

# 预演：每行 "类型|目标|备注"（无副作用；交互式模块，列出菜单动作的影响范围）
module_plan() {
  local IFS=$' \n\t'
  local -a missing=()
  local cron sadc_opts="" opt need_sysstat=0
  cron=$(cron_state "ops-report")

  echo "info|动作范围|交互菜单：启用/禁用定时报告、生成最近 7/30/365 天报告；--yes 生成 7 天报告；cron 模式按周期生成（数据不足自动跳过）"
  command -v sar >/dev/null 2>&1 || missing+=("sysstat")
  command -v smartctl >/dev/null 2>&1 || missing+=("smartmontools")
  [[ ${#missing[@]} -gt 0 ]] && echo "pkg|${missing[*]}|前置检查自动安装（失败时报告相应部分降级）"

  # sysstat 配置（启用与每次生成报告都会执行 ops_setup_enable）
  if [[ -r "$OPS_SYSSTAT_DEFAULT" ]] && grep -qx 'ENABLED="true"' "$OPS_SYSSTAT_DEFAULT" 2>/dev/null; then
    echo "info|${OPS_SYSSTAT_DEFAULT}|已为 ENABLED=\"true\"，不改动"
  else
    echo "write|${OPS_SYSSTAT_DEFAULT}|设置 ENABLED=\"true\"；原件备份到 /var/backups/debnas/"
  fi
  if [[ -r "$OPS_SYSSTAT_CONFIG" ]]; then
    grep -qx "HISTORY=${OPS_SYSSTAT_HISTORY}" "$OPS_SYSSTAT_CONFIG" 2>/dev/null || need_sysstat=1
    grep -qx 'COMPRESSAFTER=14' "$OPS_SYSSTAT_CONFIG" 2>/dev/null || need_sysstat=1
    sadc_opts=$(grep '^SADC_OPTIONS=' "$OPS_SYSSTAT_CONFIG" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"' || true)
    for opt in "-D" "-S DISK" "-S XDISK"; do
      [[ " ${sadc_opts} " == *" ${opt} "* ]] || need_sysstat=1
    done
  else
    need_sysstat=1
  fi
  if [[ "$need_sysstat" -eq 1 ]]; then
    echo "write|${OPS_SYSSTAT_CONFIG}|HISTORY=${OPS_SYSSTAT_HISTORY}、COMPRESSAFTER=14、SADC_OPTIONS 补 -D -S DISK -S XDISK；原件备份到 /var/backups/debnas/"
  else
    echo "info|${OPS_SYSSTAT_CONFIG}|保留 ${OPS_SYSSTAT_HISTORY} 天与磁盘采集参数已就绪，不改动"
  fi
  if _ops_sysstat_active; then
    echo "service|sysstat|已运行；未设开机自启时补设"
  else
    echo "service|sysstat|启动并设为开机自启（启用及每次生成报告都会确保）"
  fi
  [[ -e "$OPS_LOGROTATE_CONFIG" ]] \
    && echo "write|${OPS_LOGROTATE_CONFIG}|删除旧版遗留配置（避免与系统 wtmp/btmp 配置重复），不另做备份"

  echo "write|${OPS_REPORTS_DIR}/|生成报告：weekly/monthly/annual 下写 HTML（600）并更新 latest.html 链接；目录 700"
  echo "info|邮件|生成报告后发送到通知邮箱（未配置则跳过；HTML 附件不超过 2MB）"

  case "$cron" in
    on)  echo "info|定时任务|已启用（周一 01:00 周报；1 月 1 日 02:00 年报）" ;;
    *)
      echo "cron|ops-report 0 1 * * 1|启用定时报告：周一 01:00 周报（sysstat 数据不足 7 天时自动跳过）"
      echo "cron|ops-report 0 2 1 1 * --period 1y --email|启用定时报告：1 月 1 日 02:00 年报"
      ;;
  esac
  echo "cron|ops-report|禁用定时报告：移除全部 ops-report 条目（历史报告与采集数据保留）"
  echo "info|耗时|生成报告会采集 journal、SMART、docker、登录日志，可能需要数十秒"
  echo "risk|sysstat|每次生成报告都会确保 sysstat 运行并改写其配置（保留 ${OPS_SYSSTAT_HISTORY} 天历史，占用 /var/log/sysstat 空间）"
  return 0
}

# ==================== 主入口 ====================
main() {
  case "${1:-}" in
    enable)
      ops_setup_and_enable
      return $?
      ;;
    disable)
      ops_pause_schedule
      return $?
      ;;
  esac

  if [[ "${DEBNAS_CRON_MODE:-0}" -eq 1 ]]; then
    ops_cron_generate_from_args "$@"
    return $?
  fi

  if [[ "${DEBNAS_FORCE_YES:-0}" -eq 1 ]]; then
    if [[ $# -eq 0 ]]; then
      ops_generate_from_args --period 7d
    else
      ops_generate_from_args "$@"
    fi
    return $?
  fi

  if [[ $# -gt 0 ]]; then
    ops_generate_from_args "$@"
    return $?
  fi

  ops_menu
}

# 契约守卫：DEBNAS_MODULE_ACTION=status|plan 时只加载函数供只读探测，不执行 main（docs/ARCHITECTURE.md §4.5）
if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi
