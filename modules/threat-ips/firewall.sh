#!/bin/bash
# threat-ips: Firewalld 集成模块

set -euo pipefail
IFS=$'\n\t'

reload_firewalld() {
  local need_reload="${1:-0}"
  if [[ ${need_reload} -eq 1 ]]; then
    local cmd_output
    if ! cmd_output=$(firewall-cmd --reload 2>&1); then
      log_message "ERROR" "Firewalld 规则重载失败：${cmd_output}"
      return 1
    fi
    log_message "SUCCESS" "Firewalld 规则重载成功"
  fi
}


apply_ips_to_single_ipset() {
  local ip_file="$1" ipset_name="$2" ip_type="$3" mode="$4"
  local count
  count=$(wc -l < "${ip_file}" 2>/dev/null || printf "0")
  if [[ ${count} -eq 0 ]]; then
    return 0
  fi
  if ! apply_ip_changes "${ip_file}" "${ipset_name}" "${mode}"; then
    log_message "ERROR" "应用 ${ip_type} IP 变更失败"
    return 1
  fi
  printf "%s" "${count}"
}

apply_ips_to_ipsets() {
  local output_file_ipv4="$1" output_file_ipv6="$2" mode="$3"
  local ipv4_count ipv6_count

  ipv4_count=$(apply_ips_to_single_ipset \
    "${output_file_ipv4}" "${IPSET_NAME_IPV4}" "IPv4" "${mode}") || return 1
  ipv6_count=$(apply_ips_to_single_ipset \
    "${output_file_ipv6}" "${IPSET_NAME_IPV6}" "IPv6" "${mode}") || return 1

  if [[ -z "${ipv4_count}" ]] && [[ -z "${ipv6_count}" ]]; then
    log_message "INFO" "无 IP 需要处理"
    return 0
  fi
  log_message "SUCCESS" \
    "已处理 IPv4: ${ipv4_count:-0} 条 IPv6: ${ipv6_count:-0} 条"
}

# 去重排序单个 IP 类型文件
_process_single_ip_file() {
  local temp_file="$1" output_file="$2" ip_type="$3"
  if ! deduplicate_and_sort_ips "${temp_file}" "${output_file}"; then
    return 1
  fi
  check_and_limit_ip_count "${output_file}" "${ip_type}" >/dev/null
}

# 处理 IP 列表：解析、去重、排序、限制数量并应用到 IPSet
process_ip_list() {
  local input_file="$1" output_file_ipv4="$2" output_file_ipv6="$3"
  local mode="$4"
  local temp_file_ipv4 temp_file_ipv6 temp_input

  temp_file_ipv4=$(create_temp_file "expanded_ips_ipv4" ".txt")
  temp_file_ipv6=$(create_temp_file "expanded_ips_ipv6" ".txt")
  : > "${temp_file_ipv4}"
  : > "${temp_file_ipv6}"

  temp_input=$(prepare_input_file "${input_file}") || return 0

  if ! parse_ip_entries "${temp_input}" "${temp_file_ipv4}" "${temp_file_ipv6}"; then
    return 0
  fi

  if [[ ! -s "${temp_file_ipv4}" && ! -s "${temp_file_ipv6}" ]]; then
    log_message "ERROR" "无有效 IP（请检查输入格式）"
    return 1
  fi

  _process_single_ip_file "${temp_file_ipv4}" "${output_file_ipv4}" "IPv4" \
    || return 1
  _process_single_ip_file "${temp_file_ipv6}" "${output_file_ipv6}" "IPv6" \
    || return 1

  apply_ips_to_ipsets "${output_file_ipv4}" "${output_file_ipv6}" "${mode}"
}

apply_ip_changes() {
  local ip_file="$1" ipset_name="$2" mode="$3"
  local ip_count_before

  if ! check_ipset_exists "${ipset_name}"; then
    log_message "ERROR" "IPSet 不存在：${ipset_name}"
    return 1
  fi

  if ! sort -u "${ip_file}" > "${ip_file}.tmp" 2>/dev/null; then
    log_message "ERROR" "去重失败：${ip_file}"
    return 1
  fi
  mv "${ip_file}.tmp" "${ip_file}"
  ip_count_before=$(wc -l < "${ip_file}")

  if [[ ${ip_count_before} -eq 0 ]]; then
    log_message "INFO" "输入文件为空，无需${mode}操作"
    return 0
  fi

  if [[ "${mode}" == "add" ]]; then
    if [[ ${ip_count_before} -gt ${MAX_IP_LIMIT} ]]; then
      log_message "WARNING" \
        "输入条目数超过 IPSet 上限：${ipset_name}（${ip_count_before} > ${MAX_IP_LIMIT}）"
      return 1
    fi
    if ! firewall-cmd --permanent \
      --ipset="${ipset_name}" \
      --add-entries-from-file="${ip_file}" &>/dev/null; then
      log_message "ERROR" "添加 IP 到 IPSet 失败：${ipset_name}"
      return 1
    fi
  elif [[ "${mode}" == "remove" ]]; then
    if ! firewall-cmd --permanent \
      --ipset="${ipset_name}" \
      --remove-entries-from-file="${ip_file}" &>/dev/null; then
      log_message "ERROR" "从 IPSet 移除 IP 失败：${ipset_name}"
      return 1
    fi
  fi
}


remove_ips_from_single_ipset() {
  local ipset_name="$1" temp_file="$2" ip_type="$3"
  local sources
  sources=$(firewall-cmd --permanent \
    --ipset="${ipset_name}" --get-entries 2>/dev/null)
  if [[ -z "${sources}" ]]; then
    return 0
  fi
  printf "%s" "${sources}" | tr ' ' '\n' > "${temp_file}"
  apply_ip_changes "${temp_file}" "${ipset_name}" "remove" || {
    log_message "WARNING" "移除 ${ip_type} IP 失败，继续执行清理"
  }
}

remove_ips_from_ipsets() {
  local temp_ipv4 temp_ipv6
  temp_ipv4=$(create_temp_file "remove_ipv4" ".txt")
  temp_ipv6=$(create_temp_file "remove_ipv6" ".txt")
  remove_ips_from_single_ipset "${IPSET_NAME_IPV4}" "${temp_ipv4}" "IPv4"
  remove_ips_from_single_ipset "${IPSET_NAME_IPV6}" "${temp_ipv6}" "IPv6"
}

# 从区域解绑单个 IPSet（返回：0 需要重载，1 无需重载）
unbind_single_ipset_from_zone() {
  local ipset_name="$1" ip_type="$2"
  local ipset_bound need_reload=0
  ipset_bound=$(firewall-cmd --permanent --zone=drop --list-sources \
    | grep -w "ipset:${ipset_name}" || true)
  if [[ -z "${ipset_bound}" ]]; then
    return 0
  fi
  log_message "INFO" "从 drop 区域解绑 ${ip_type} IPSet"
  if firewall-cmd --permanent --zone=drop \
    --remove-source="ipset:${ipset_name}" &>/dev/null; then
    need_reload=1
  else
    log_message "WARNING" "解绑 ${ip_type} IPSet 失败，继续执行清理"
  fi
  [[ ${need_reload} -eq 1 ]]
}

unbind_ipsets_from_zone() {
  local need_reload=0
  if unbind_single_ipset_from_zone "${IPSET_NAME_IPV4}" "IPv4"; then
    need_reload=1
  fi
  if unbind_single_ipset_from_zone "${IPSET_NAME_IPV6}" "IPv6"; then
    need_reload=1
  fi
  [[ ${need_reload} -eq 1 ]]
}

delete_single_ipset() {
  local ipset_name="$1" ip_type="$2" need_reload=0
  local ipset_old_file="/etc/firewalld/ipsets/${ipset_name}.xml.old"

  if ! check_ipset_exists "${ipset_name}"; then
    if [[ -f "${ipset_old_file}" ]]; then
      rm -f "${ipset_old_file}" 2>/dev/null || true
    fi
    return 0
  fi
  log_message "INFO" "删除 ${ip_type} IPSet：${ipset_name}"
  if firewall-cmd --permanent --delete-ipset="${ipset_name}" &>/dev/null; then
    need_reload=1
    if [[ -f "${ipset_old_file}" ]]; then
      rm -f "${ipset_old_file}" 2>/dev/null || true
    fi
  else
    log_message "WARNING" "删除 ${ip_type} IPSet 失败，继续执行清理"
  fi
  [[ ${need_reload} -eq 1 ]]
}

delete_ipsets() {
  local need_reload=0
  if delete_single_ipset "${IPSET_NAME_IPV4}" "IPv4"; then
    need_reload=1
  fi
  if delete_single_ipset "${IPSET_NAME_IPV6}" "IPv6"; then
    need_reload=1
  fi
  [[ ${need_reload} -eq 1 ]]
}

# 清理 drop 区域配置：仅在区域完全清空时删除自定义配置文件
cleanup_drop_zone_config() {
  local drop_xml_file="/etc/firewalld/zones/drop.xml"
  local remaining_sources drop_zone_info need_reload=0

  remaining_sources=$(firewall-cmd --permanent --zone=drop --list-sources \
    2>/dev/null | grep -v "^$" || true)
  drop_zone_info=$(firewall-cmd --permanent --zone=drop --list-all \
    2>/dev/null || true)

  local has_services has_ports has_protocols has_rich_rules
  has_services=$(printf "%s" "${drop_zone_info}" \
    | grep -E "^  services:" | grep -v "services: $" || true)
  has_ports=$(printf "%s" "${drop_zone_info}" \
    | grep -E "^  ports:" | grep -v "ports: $" || true)
  has_protocols=$(printf "%s" "${drop_zone_info}" \
    | grep -E "^  protocols:" | grep -v "protocols: $" || true)
  has_rich_rules=$(printf "%s" "${drop_zone_info}" \
    | grep -E "^  rich rules:" | grep -v "rich rules: $" || true)

  if [[ -z "${remaining_sources}" ]] && [[ -z "${has_services}" ]] \
    && [[ -z "${has_ports}" ]] && [[ -z "${has_protocols}" ]] \
    && [[ -z "${has_rich_rules}" ]]; then
    if [[ -f "${drop_xml_file}" ]]; then
      log_message "INFO" \
        "drop 区域已清空，删除自定义配置文件：${drop_xml_file}"
      if rm -f "${drop_xml_file}"; then
        need_reload=1
        local drop_old_file="/etc/firewalld/zones/drop.xml.old"
        if [[ -f "${drop_old_file}" ]]; then
          rm -f "${drop_old_file}" 2>/dev/null || true
        fi
      else
        log_message "WARNING" \
          "删除 drop 区域配置文件失败：${drop_xml_file}，继续执行清理"
      fi
    fi
  elif [[ -n "${remaining_sources}" ]]; then
    log_message "INFO" "drop 区域仍有其他 sources，保留配置文件"
  fi
  [[ ${need_reload} -eq 1 ]]
}

remove_all_ips() {
  local need_reload=0

  if ! check_ipset_exists "${IPSET_NAME_IPV4}" \
    && ! check_ipset_exists "${IPSET_NAME_IPV6}"; then
    log_message "INFO" "未配置 IPSet"
    return 0
  fi

  remove_ips_from_ipsets

  if unbind_ipsets_from_zone; then
    need_reload=1
  fi
  if delete_ipsets; then
    need_reload=1
  fi
  if cleanup_drop_zone_config; then
    need_reload=1
  fi

  reload_firewalld ${need_reload} || {
    log_message "WARNING" "Firewalld 重载失败，但继续执行清理"
  }
  log_message "SUCCESS" "已移除所有封禁 IP"
}


filter_and_add_ips() {
  local temp_txt="$1" temp_file_ipv4="$2" temp_file_ipv6="$3"
  local need_reload=0

  [[ ! -f "${temp_txt}" ]] && {
    log_message "ERROR" "IP 列表文件不存在：${temp_txt}"
    return 1
  }

  if configure_ipset; then
    need_reload=1
  fi
  clear_all_ipsets

  if ! process_ip_list "${temp_txt}" "${temp_file_ipv4}" "${temp_file_ipv6}" "add"; then
    log_message "ERROR" "处理 IP 列表失败"
    return 1
  fi

  # 使用 --permanent 修改 IPSet 后必须重载防火墙才能生效
  need_reload=1

  if ! reload_firewalld ${need_reload}; then
    log_message "ERROR" "Firewalld 重载失败"
    return 1
  fi
}

