#!/bin/bash
# threat-ips: 定时更新逻辑模块

set -euo pipefail
IFS=$'\n\t'

# ==================== 并发控制 ====================
# 定时任务与手动操作互斥，避免两个进程同时增删 IPSet
# 参数：$1 - 等待秒数（0 表示不等待）
acquire_update_lock() {
  local wait_seconds="${1:-0}"
  local lock_dir="/run/lock"
  [[ -d "${lock_dir}" && -w "${lock_dir}" ]] || lock_dir="/tmp"
  exec 9>"${lock_dir}/debnas-threat-ips.lock" || return 1
  if [[ "${wait_seconds}" -gt 0 ]]; then
    flock -w "${wait_seconds}" 9
  else
    flock -n 9
  fi
}

release_update_lock() {
  exec 9>&-
}

# ==================== 自动更新管理 ====================
enable_auto_update() {
  local threat_level input

  print_prompt "请输入威胁等级（0-100，留空使用默认：${DEFAULT_THREAT_LEVEL}）："
  read -r input || true
  threat_level="${input:-${DEFAULT_THREAT_LEVEL}}"
  if ! [[ "${threat_level}" =~ ^[0-9]+$ ]] \
    || [[ "${threat_level}" -lt 0 ]] || [[ "${threat_level}" -gt 100 ]]; then
    log_warning \
      "无效威胁等级：${threat_level}，使用默认：${DEFAULT_THREAT_LEVEL}"
    threat_level=${DEFAULT_THREAT_LEVEL}
  fi
  THREAT_LEVEL=${threat_level}
  export THREAT_LEVEL

  init_data_dir
  if [[ ! -d "${LOG_DIR}" ]]; then
    log_info "创建日志目录：${LOG_DIR}"
    mkdir -p "${LOG_DIR}" || {
      log_error "创建日志目录失败：${LOG_DIR}"
      return 1
    }
    chmod 755 "${LOG_DIR}"
  fi
  if [[ ! -f "${LOG_FILE}" ]]; then
    log_info "创建日志文件：${LOG_FILE}"
    touch "${LOG_FILE}" || {
      log_error "创建日志文件失败：${LOG_FILE}"
      return 1
    }
    chmod 644 "${LOG_FILE}"
  fi
  if [[ ! -w "${LOG_FILE}" ]]; then
    log_error "日志文件不可写：${LOG_FILE}（请检查权限）"
    return 1
  fi

  printf "THREAT_LEVEL=%s\n" "${threat_level}" > "${CONFIG_FILE}" || {
    log_error "写入配置文件失败：${CONFIG_FILE}"
    return 1
  }
  chmod 644 "${CONFIG_FILE}" 2>/dev/null
  feature_enable "threat-ips"

  if ! update_threat_ips "${threat_level}"; then
    log_warning \
      "首次更新失败，但自动更新已启用（将在下次定时任务时重试）"
  fi
  release_update_lock
  log_success "威胁封禁已启用：威胁等级 ${threat_level}"
  module_mark_action
}

disable_auto_update() {
  if ! acquire_update_lock 300; then
    log_error "另一个威胁 IP 更新任务仍在运行，请稍后重试"
    return 1
  fi
  feature_disable "threat-ips"
  cron_unregister "threat-ips" || true

  remove_all_ips || {
    log_warning "清理防火墙配置时出现警告，继续执行清理"
  }

  if [[ -f "${CONFIG_FILE}" ]]; then
    log_info "删除配置文件：${CONFIG_FILE}"
    rm -f "${CONFIG_FILE}" || {
      log_error "删除配置文件失败：${CONFIG_FILE}"
      exit "${ERROR_GENERAL}"
    }
  fi
  # CRON_SCRIPT_PATH 清理（兼容旧版安装残留的文件）
  if [[ -f "${CRON_SCRIPT_PATH}" ]]; then
    log_info "删除旧版脚本文件：${CRON_SCRIPT_PATH}"
    rm -f "${CRON_SCRIPT_PATH}" 2>/dev/null || true
  fi
  if [[ -d "${DATA_DIR}" ]]; then
    if [[ -z "$(ls -A "${DATA_DIR}" 2>/dev/null)" ]]; then
      log_info "删除数据目录：${DATA_DIR}"
      rmdir "${DATA_DIR}" 2>/dev/null || true
    else
      log_warning "数据目录 ${DATA_DIR} 非空，保留目录"
    fi
  fi

  release_update_lock
  log_success "威胁 IP 已禁用"
  module_mark_action
}

view_cron_jobs() {
  if cron_is_registered "threat-ips"; then
    cron_list | grep "threat-ips" || \
      log_info "定时任务已注册（使用 debnas cron list 查看详情）"
  else
    log_info "未设置任何与 IPThreat Firewalld 相关的定时任务"
  fi
}

update_threat_ips() {
  local threat_level="${1:-${THREAT_LEVEL:-${DEFAULT_THREAT_LEVEL}}}"
  local temp_gz temp_txt temp_file_ipv4 temp_file_ipv6

  if ! [[ "${threat_level}" =~ ^[0-9]+$ ]] \
    || [[ "${threat_level}" -lt 0 || "${threat_level}" -gt 100 ]]; then
    log_warning \
      "无效威胁等级：${threat_level}，使用默认：${DEFAULT_THREAT_LEVEL}"
    threat_level=${DEFAULT_THREAT_LEVEL}
  fi

  if ! acquire_update_lock 0; then
    log_warning "另一个威胁 IP 更新任务正在运行，跳过本次更新"
    return 1
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
    log_error "下载威胁 IP 列表失败，终止更新"
    return 1
  fi

  if ! filter_and_add_ips "${temp_txt}" "${temp_file_ipv4}" "${temp_file_ipv6}"; then
    log_error "处理 IP 列表失败，终止更新"
    return 1
  fi
}
