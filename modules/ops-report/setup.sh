#!/bin/bash
# ops-report: 环境初始化、sysstat 与日志保留配置
set -euo pipefail
IFS=$'\n\t'

ops_ensure_report_dirs() {
  local -a dirs=(
    "${OPS_REPORT_DIR}"
    "${OPS_REPORTS_DIR}"
    "${OPS_REPORTS_DIR}/weekly"
    "${OPS_REPORTS_DIR}/monthly"
    "${OPS_REPORTS_DIR}/annual"
    "${OPS_SNAPSHOT_DIR}"
  )
  local dir
  for dir in "${dirs[@]}"; do
    if [[ ! -d "$dir" ]]; then
      install -d -m 700 "$dir" || return 1
    else
      chmod 700 "$dir" 2>/dev/null || true
    fi
  done
  return 0
}

ops_configure_sysstat() {
  # sadc 在 Debian 上位于 /usr/lib/sysstat/sadc，不在 PATH；由 sysstat 服务保证可用
  install_missing_dependencies sar smartctl || log_warning "部分报告依赖安装失败，缺失能力将自动降级"

  local default_content=""
  [[ -f "$OPS_SYSSTAT_DEFAULT" ]] && default_content=$(cat "$OPS_SYSSTAT_DEFAULT" 2>/dev/null || true)
  local new_default
  new_default=$(printf '%s\n' "${default_content}" | awk '
    BEGIN { replaced = 0 }
    {
      if ($0 ~ "^[[:space:]]*ENABLED=") {
        print "ENABLED=\"true\""
        replaced = 1
      } else {
        print
      }
    }
    END { if (!replaced) print "ENABLED=\"true\"" }
  ')
  write_file_if_changed "$OPS_SYSSTAT_DEFAULT" "$new_default" 644 1 || log_warning "写入 ${OPS_SYSSTAT_DEFAULT} 失败，sysstat 采集开关可能未生效"

  local sadc_options=""
  if [[ -f "$OPS_SYSSTAT_CONFIG" ]]; then
    sadc_options=$(grep '^SADC_OPTIONS=' "$OPS_SYSSTAT_CONFIG" 2>/dev/null \
      | tail -1 | cut -d= -f2- | tr -d '"' || true)
  fi
  local opt
  for opt in "-D" "-S DISK" "-S XDISK"; do
    if [[ " ${sadc_options} " != *" ${opt} "* ]]; then
      sadc_options="${sadc_options:+${sadc_options} }${opt}"
    fi
  done

  local sysstat_content=""
  [[ -f "$OPS_SYSSTAT_CONFIG" ]] && sysstat_content=$(cat "$OPS_SYSSTAT_CONFIG" 2>/dev/null || true)
  local sadc_value="\"${sadc_options}\""
  local new_sysstat
  new_sysstat=$(printf '%s\n' "${sysstat_content}" | awk \
    -v history="${OPS_SYSSTAT_HISTORY}" \
    -v compress="14" \
    -v sadc_value="$sadc_value" '
    BEGIN { h = 0; c = 0; o = 0 }
    {
      if ($0 ~ "^[[:space:]]*HISTORY=") { print "HISTORY=" history; h = 1 }
      else if ($0 ~ "^[[:space:]]*COMPRESSAFTER=") { print "COMPRESSAFTER=" compress; c = 1 }
      else if ($0 ~ "^[[:space:]]*SADC_OPTIONS=") { print "SADC_OPTIONS=" sadc_value; o = 1 }
      else print
    }
    END {
      if (!h) print "HISTORY=" history
      if (!c) print "COMPRESSAFTER=" compress
      if (!o) print "SADC_OPTIONS=" sadc_value
    }')
  write_file_if_changed "$OPS_SYSSTAT_CONFIG" "$new_sysstat" 644 1 || log_warning "写入 ${OPS_SYSSTAT_CONFIG} 失败，sysstat 采集参数可能未生效"

  if command -v systemctl >/dev/null 2>&1; then
    if ! systemctl is-active --quiet sysstat 2>/dev/null; then
      service_ensure sysstat started || log_warning "sysstat 服务启动失败，历史采集可能不可用"
    fi
    if ! systemctl is-enabled --quiet sysstat 2>/dev/null; then
      service_ensure sysstat enabled || log_warning "sysstat 开机启动配置失败"
    fi
  fi
}

ops_configure_logrotate() {
  # Debian 自带 wtmp/btmp/wtmpdb 的 logrotate 配置，重复写入会导致
  # logrotate 报 duplicate log entry 并失败。这里只清理旧版本生成的配置。
  if [[ -n "${OPS_LOGROTATE_CONFIG:-}" && -f "$OPS_LOGROTATE_CONFIG" ]]; then
    rm -f "$OPS_LOGROTATE_CONFIG" || log_warning "清理旧的 logrotate 配置失败：${OPS_LOGROTATE_CONFIG}"
  fi
}

# 确保有登录记录数据源（报告"登录与身份审计"一节的来源）
# - 已有 wtmpdb 或 last：什么都不做（Debian 12 自带 last）
# - 都没有且为 Debian 13+：安装 wtmpdb 与 libpam-wtmpdb。libpam-wtmpdb 的 PAM 配置由包自带的
#   pam-auth-update 配置（Default: yes）自动启用，不手改 /etc/pam.d，也不需要重启服务；
#   sshd 自己写 wtmpdb（pam_wtmpdb 带 skip_if=sshd），PAM 模块负责本地终端、Cockpit 等其余登录
# - 安装失败或无包可装：只告警，报告照常生成（登录一节显示"无登录数据源"）
# 返回：始终 0
ops_ensure_login_source() {
  ops_login_source >/dev/null && return 0
  if ! ops_login_source_installable; then
    log_warning "未找到 last / wtmpdb，报告的登录统计将显示无登录数据源"
    return 0
  fi
  log_info "未找到登录记录数据源，安装 wtmpdb libpam-wtmpdb（安装后才开始记录本地终端与 Cockpit 登录）"
  if ! apt_install_packages wtmpdb libpam-wtmpdb || ! ops_login_source >/dev/null; then
    log_warning "wtmpdb 安装失败，报告的登录统计将显示无登录数据源"
  fi
  return 0
}

ops_setup_enable() {
  ops_ensure_report_dirs || return 1
  ops_configure_sysstat
  ops_ensure_login_source
  ops_configure_logrotate
  return 0
}
