#!/bin/bash
# threat-ips: 定时更新逻辑模块

set -euo pipefail
IFS=$'\n\t'

# ==================== 自动更新管理 ====================
enable_auto_update() {
  local cron_schedule threat_level input

  print_prompt "请输入威胁等级（0-100，留空使用默认：${DEFAULT_THREAT_LEVEL}）："
  read -r input || true
  threat_level="${input:-${DEFAULT_THREAT_LEVEL}}"
  if ! [[ "${threat_level}" =~ ^[0-9]+$ ]] \
    || [[ "${threat_level}" -lt 0 ]] || [[ "${threat_level}" -gt 100 ]]; then
    log_message "WARNING" \
      "无效威胁等级：${threat_level}，使用默认：${DEFAULT_THREAT_LEVEL}"
    threat_level=${DEFAULT_THREAT_LEVEL}
  fi
  THREAT_LEVEL=${threat_level}
  export THREAT_LEVEL

  print_prompt "请输入 Cron 规则（留空使用默认：${DEFAULT_UPDATE_CRON}）："
  read -r input || true
  cron_schedule="${input:-${DEFAULT_UPDATE_CRON}}"
  if ! printf "%s" "${cron_schedule}" \
    | grep -qE '^[0-9*,/-]+[[:space:]]+[0-9*,/-]+[[:space:]]+[0-9*,/-]+[[:space:]]+[0-9*,/-]+[[:space:]]+[0-9*,/-]+$'; then
    log_message "WARNING" \
      "无效 Cron 规则：${cron_schedule}，使用默认：${DEFAULT_UPDATE_CRON}"
    cron_schedule=${DEFAULT_UPDATE_CRON}
  fi

  init_data_dir
  if [[ ! -d "${LOG_DIR}" ]]; then
    log_message "INFO" "创建日志目录：${LOG_DIR}"
    mkdir -p "${LOG_DIR}" || {
      log_message "ERROR" "创建日志目录失败：${LOG_DIR}"
      return 1
    }
    chmod 755 "${LOG_DIR}"
  fi
  if [[ ! -f "${LOG_FILE}" ]]; then
    log_message "INFO" "创建日志文件：${LOG_FILE}"
    touch "${LOG_FILE}" || {
      log_message "ERROR" "创建日志文件失败：${LOG_FILE}"
      return 1
    }
    chmod 644 "${LOG_FILE}"
  fi
  if [[ ! -w "${LOG_FILE}" ]]; then
    log_message "ERROR" "日志文件不可写：${LOG_FILE}（请检查权限）"
    return 1
  fi

  printf "THREAT_LEVEL=%s\n" "${threat_level}" > "${CONFIG_FILE}" || {
    log_message "ERROR" "写入配置文件失败：${CONFIG_FILE}"
    return 1
  }
  printf "UPDATE_CRON=%s\n" "${cron_schedule}" >> "${CONFIG_FILE}" || {
    log_message "ERROR" "写入配置文件失败：${CONFIG_FILE}"
    return 1
  }
  chmod 644 "${CONFIG_FILE}" 2>/dev/null

  # 使用统一 cron 框架注册定时任务（替代自行管理 crontab）
  if ! cron_register "threat-ips" "${cron_schedule}" 2>/dev/null; then
    log_message "ERROR" "设置定时任务失败（请检查 cron 服务）"
    return 1
  fi
  log_message "SUCCESS" \
    "启用自动更新：威胁等级 ${threat_level}，定时 ${cron_schedule}"

  if ! update_threat_ips "${threat_level}"; then
    log_message "WARNING" \
      "首次更新失败，但自动更新已启用（将在下次定时任务时重试）"
  fi
}

disable_auto_update() {
  # 使用统一 cron 框架移除定时任务（替代自行管理 crontab）
  cron_unregister "threat-ips" 2>/dev/null || true

  remove_all_ips || {
    log_message "WARNING" "清理防火墙配置时出现警告，继续执行清理"
  }

  if [[ -f "${CONFIG_FILE}" ]]; then
    log_message "INFO" "删除配置文件：${CONFIG_FILE}"
    rm -f "${CONFIG_FILE}" || {
      log_message "ERROR" "删除配置文件失败：${CONFIG_FILE}"
      exit "${ERROR_GENERAL}"
    }
  fi
  # CRON_SCRIPT_PATH 清理（兼容旧版安装残留的文件）
  if [[ -f "${CRON_SCRIPT_PATH}" ]]; then
    log_message "INFO" "删除旧版脚本文件：${CRON_SCRIPT_PATH}"
    rm -f "${CRON_SCRIPT_PATH}" 2>/dev/null || true
  fi
  if [[ -d "${DATA_DIR}" ]]; then
    if [[ -z "$(ls -A "${DATA_DIR}" 2>/dev/null)" ]]; then
      log_message "INFO" "删除数据目录：${DATA_DIR}"
      rmdir "${DATA_DIR}" 2>/dev/null || true
    else
      log_message "WARNING" "数据目录 ${DATA_DIR} 非空，保留目录"
    fi
  fi

  log_message "SUCCESS" "已禁用自动更新并清理所有相关配置"
}

view_cron_jobs() {
  if cron_is_registered "threat-ips" 2>/dev/null; then
    cron_list 2>/dev/null | grep "threat-ips" || \
      log_message "INFO" "定时任务已注册（使用 debnas cron list 查看详情）"
  else
    log_message "INFO" "未设置任何与 IPThreat Firewalld 相关的定时任务"
  fi
}

update_threat_ips() {
  local threat_level="${1:-${THREAT_LEVEL:-${DEFAULT_THREAT_LEVEL}}}"
  local temp_gz temp_txt temp_file_ipv4 temp_file_ipv6

  if ! [[ "${threat_level}" =~ ^[0-9]+$ ]] \
    || [[ "${threat_level}" -lt 0 || "${threat_level}" -gt 100 ]]; then
    log_message "WARNING" \
      "无效威胁等级：${threat_level}，使用默认：${DEFAULT_THREAT_LEVEL}"
    threat_level=${DEFAULT_THREAT_LEVEL}
  fi

  temp_gz=$(create_temp_file "threat" ".gz")
  temp_txt=$(create_temp_file "threat" ".txt")
  temp_file_ipv4=$(create_temp_file "valid_ips_ipv4" ".txt")
  temp_file_ipv6=$(create_temp_file "valid_ips_ipv6" ".txt")

  if ! check_ipset_exists "${IPSET_NAME_IPV4}" \
    && ! check_ipset_exists "${IPSET_NAME_IPV6}"; then
    configure_ipset || true
  fi

  if ! download_threat_list "${threat_level}" "${temp_gz}" "${temp_txt}"; then
    log_message "ERROR" "下载威胁 IP 列表失败，终止更新"
    return 1
  fi

  if ! filter_and_add_ips "${temp_txt}" "${temp_file_ipv4}" "${temp_file_ipv6}"; then
    log_message "ERROR" "处理 IP 列表失败，终止更新"
    return 1
  fi
}


update_threat_ips() {
  local threat_level="${1:-${THREAT_LEVEL:-${DEFAULT_THREAT_LEVEL}}}"
  local temp_gz temp_txt temp_file_ipv4 temp_file_ipv6

  if ! [[ "${threat_level}" =~ ^[0-9]+$ ]] \
    || [[ "${threat_level}" -lt 0 || "${threat_level}" -gt 100 ]]; then
    log_message "WARNING" \
      "无效威胁等级：${threat_level}，使用默认：${DEFAULT_THREAT_LEVEL}"
    threat_level=${DEFAULT_THREAT_LEVEL}
  fi

  temp_gz=$(create_temp_file "threat" ".gz")
  temp_txt=$(create_temp_file "threat" ".txt")
  temp_file_ipv4=$(create_temp_file "valid_ips_ipv4" ".txt")
  temp_file_ipv6=$(create_temp_file "valid_ips_ipv6" ".txt")

  if ! check_ipset_exists "${IPSET_NAME_IPV4}" \
    && ! check_ipset_exists "${IPSET_NAME_IPV6}"; then
    configure_ipset || true
  fi

  if ! download_threat_list "${threat_level}" "${temp_gz}" "${temp_txt}"; then
    log_message "ERROR" "下载威胁 IP 列表失败，终止更新"
    return 1
  fi

  if ! filter_and_add_ips "${temp_txt}" "${temp_file_ipv4}" "${temp_file_ipv6}"; then
    log_message "ERROR" "处理 IP 列表失败，终止更新"
    return 1
  fi
}

