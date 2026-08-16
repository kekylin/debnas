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

ops_sysstat_upsert() {
  local file="$1" key="$2" value="$3"
  local content=""
  [[ -f "$file" ]] && content=$(cat "$file" 2>/dev/null || true)

  local new_content
  new_content=$(printf '%s\n' "${content}" | awk -v k="$key" -v v="$value" '
    BEGIN { replaced = 0 }
    {
      if ($0 ~ "^[[:space:]]*" k "=") {
        print k "=" v
        replaced = 1
      } else {
        print
      }
    }
    END {
      if (!replaced) print k "=" v
    }
  ')
  write_file_if_changed "$file" "$new_content" 644 || true
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
  write_file_if_changed "$OPS_SYSSTAT_DEFAULT" "$new_default" 644 1 || true

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
  write_file_if_changed "$OPS_SYSSTAT_CONFIG" "$new_sysstat" 644 1 || true

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

ops_setup_enable() {
  ops_ensure_report_dirs || return 1
  ops_configure_sysstat
  ops_configure_logrotate
  return 0
}
