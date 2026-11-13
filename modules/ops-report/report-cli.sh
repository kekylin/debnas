#!/bin/bash
# ops-report: 报告生成、终端摘要与并发锁（由 report.sh 加载）
set -euo pipefail
IFS=$'\n\t'

ops_period_reports_dir() {
  local base="${OPS_REPORTS_DIR:-${OPS_REPORT_DIR:-}/reports}"
  case "${1:-7}" in
    7) printf '%s/weekly' "$base" ;;
    30) printf '%s/monthly' "$base" ;;
    365) printf '%s/annual' "$base" ;;
    *) printf '%s/weekly' "$base" ;;
  esac
}

ops_print_terminal_summary() {
  printf '\n'
  printf 'DebNAS 运维报告\n'
  printf '────────────────────────────────────────────\n'
  printf '周期：最近 %s 天       总体状态：%s\n' "$OPS_REPORT_DAYS" "$OPS_STATUS_TEXT"
  printf '运行：%s 天   CPU：%s   内存：%s\n' "$OPS_UPTIME_DAYS" "$(ops_pct_label "$OPS_CPU_AVG")" "$(ops_pct_label "$OPS_MEM_CURRENT_PERCENT")"
  printf '登录成功：%s   失败：%s   待更新：%s   建议：%s\n' \
    "$OPS_LOGIN_SUCCESS_COUNT" "$OPS_LOGIN_FAIL_COUNT" "$(ops_installed_count_label "$OPS_PENDING_UPDATE_COUNT")" "$OPS_ACTION_COUNT"
  printf '报告目录：%s\n' "${OPS_PERIOD_REPORTS_DIR:-$OPS_REPORTS_DIR}"
  printf '报告文件：%s（%s 字节）\n' "$OPS_LAST_REPORT" "$OPS_REPORT_SIZE"
  printf '固定入口：%s/latest.html\n' "${OPS_PERIOD_REPORTS_DIR:-$OPS_REPORTS_DIR}"
  printf '提示：报告目录按安全规范为 root 权限（700/600），请以 root 用户查看。\n'
  printf '────────────────────────────────────────────\n'
}

ops_generate_report() {
  ops_ensure_report_dirs || return 1
  local lock_fd rc=0
  if ! exec {lock_fd}>"${OPS_REPORT_DIR}/.generate.lock"; then
    log_error "无法创建报告生成锁：${OPS_REPORT_DIR}/.generate.lock"
    return 1
  fi
  if ! flock -n "$lock_fd"; then
    exec {lock_fd}>&-
    log_warning "已有运维报告生成任务正在运行，本次跳过"
    if [[ "${DEBNAS_CRON_MODE:-0}" -eq 1 ]]; then
      return 0
    fi
    return 1
  fi
  # 直接调用以保留 set -e 语义；异常退出时进程结束会自动释放锁
  _ops_generate_report_locked "$@"
  rc=$?
  exec {lock_fd}>&-
  return "$rc"
}

_ops_generate_report_locked() {
  local days="${1:-${OPS_DEFAULT_PERIOD}}"
  local email="${2:-0}"
  case "$days" in
    7|30|365) ;;
    *) days="$OPS_DEFAULT_PERIOD" ;;
  esac

  OPS_REPORT_DAYS="$days"
  OPS_REPORT_SINCE=$(date -d "$days days ago" '+%Y-%m-%d %H:%M:%S')
  OPS_REPORT_UNTIL=$(date '+%Y-%m-%d %H:%M:%S')
  OPS_ACTION_ITEMS=()
  OPS_REPORT_SIZE=0
  local started
  started=$(date +%s)

  if ! ops_setup_enable; then
    log_warning "数据采集初始化未完成，报告将继续生成，但周期历史数据可能不足"
  fi
  ops_ensure_report_dirs || return 1
  ops_set_coverage "$days"
  ops_collect_resources
  ops_collect_disk_trend
  ops_collect_health
  ops_collect_security
  ops_collect_suspicious_processes
  ops_collect_services
  ops_collect_security_drift
  ops_collect_updates
  ops_collect_availability
  ops_determine_status

  local filename report_path previous_file prev_base period_tag period_reports_dir
  case "$days" in
    7) period_tag="7d" ;;
    30) period_tag="30d" ;;
    365) period_tag="365d" ;;
    *) period_tag="7d" ;;
  esac
  period_reports_dir=$(ops_period_reports_dir "$days")
  OPS_PERIOD_REPORTS_DIR="$period_reports_dir"
  mkdir -p "$period_reports_dir" 2>/dev/null || true
  filename="ops-report-${period_tag}-$(date '+%Y%m%d-%H%M%S').html"
  report_path="${period_reports_dir}/${filename}"
  OPS_PREVIOUS_REPORT_DATE="未找到"
  while IFS= read -r previous_file; do
    prev_base="${previous_file##*/}"
    [[ "$prev_base" == "$filename" ]] && continue
    if [[ "$prev_base" =~ ^ops-report-([0-9]+d)-([0-9]{8})-([0-9]{6})\.html$ ]]; then
      OPS_PREVIOUS_REPORT_DATE="${BASH_REMATCH[2]:0:4}-${BASH_REMATCH[2]:4:2}-${BASH_REMATCH[2]:6:2} ${BASH_REMATCH[3]:0:2}:${BASH_REMATCH[3]:2:2}"
    elif [[ "$prev_base" =~ ^ops-report-([0-9]{8})-([0-9]{6})\.html$ ]]; then
      OPS_PREVIOUS_REPORT_DATE="${BASH_REMATCH[1]:0:4}-${BASH_REMATCH[1]:4:2}-${BASH_REMATCH[1]:6:2} ${BASH_REMATCH[2]:0:2}:${BASH_REMATCH[2]:2:2}"
    fi
  done < <(find "$period_reports_dir" -maxdepth 1 -name 'ops-report-*.html' -printf '%f\n' 2>/dev/null | sort)
  # 先以 600 创建再写入，避免写入期间按 umask 以 644 暴露登录 IP 等敏感内容
  install -m 600 /dev/null "$report_path"
  ops_render_html_report > "$report_path"
  chmod 600 "$report_path"

  if [[ ! -s "$report_path" ]] || ! grep -q '</html>' "$report_path" 2>/dev/null; then
    log_error "报告文件生成失败或不完整：${report_path}"
    return 1
  fi

  OPS_REPORT_SIZE=$(wc -c < "$report_path" | tr -d '[:space:]')
  OPS_LAST_REPORT="$report_path"
  ln -sf "$filename" "${period_reports_dir}/latest.html" 2>/dev/null || true

  local ended duration
  ended=$(date +%s)
  duration=$((ended - started))

  state_set "ops-report" "report_file" "$report_path"
  state_set "ops-report" "report_period" "${days}d"
  state_set "ops-report" "report_duration" "${duration}s"
  state_set "ops-report" "data_coverage" "$OPS_DATA_COVERAGE"
  state_set "ops-report" "report_size" "$OPS_REPORT_SIZE"

  if [[ "$email" -eq 1 ]]; then
    ops_send_report_email "$days" || true
  fi

  ops_print_terminal_summary
  module_mark_action
  return 0
}

