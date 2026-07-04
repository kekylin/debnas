#!/bin/bash
# threat-ips: 威胁列表下载与解析模块

set -euo pipefail
IFS=$'\n\t'

download_threat_list() {
  local threat_level="${1:-${THREAT_LEVEL:-${DEFAULT_THREAT_LEVEL}}}"
  local temp_gz="$2" temp_txt="$3"

  if ! [[ "${threat_level}" =~ ^[0-9]+$ ]] \
    || [[ "${threat_level}" -lt 0 || "${threat_level}" -gt 100 ]]; then
    log_warning \
      "无效威胁等级：${threat_level}，使用默认：${DEFAULT_THREAT_LEVEL}"
    threat_level=${DEFAULT_THREAT_LEVEL}
  fi

  local download_url
  download_url=$(get_threat_list_url "${threat_level}")
  log_info "下载威胁等级 ${threat_level} 的 IP 列表"

  if ! wget -q --timeout=60 "${download_url}" -O "${temp_gz}"; then
    log_error \
      "下载威胁 IP 列表失败（威胁等级：${threat_level}）"
    return 1
  fi
  if ! gzip -dc "${temp_gz}" > "${temp_txt}"; then
    log_error "解压威胁 IP 列表失败"
    return 1
  fi
  rm -f "${temp_gz}"
  log_success "威胁 IP 列表下载完成（威胁等级：${threat_level}）"
}


prepare_input_file() {
  local input_file="$1"
  local temp_input
  temp_input=$(create_temp_file "processed_input" ".txt")
  grep -v '^\s*$' "${input_file}" | grep -v '^\s*#' > "${temp_input}" || {
    log_info "IP 列表为空或仅包含注释，无需处理"
    return 1
  }
  printf "%s" "${temp_input}"
}

# 解析 IP 条目：逐行解析并统计
parse_ip_entries() {
  local temp_input="$1" temp_file_ipv4="$2" temp_file_ipv6="$3"
  local total_count valid_count=0 invalid_count=0 ip

  total_count=$(wc -l < "${temp_input}")
  log_info "解析 IP 列表中..."

  while IFS= read -r ip; do
    [[ -z "${ip}" ]] && continue
    if parse_ip_range "${ip}" "${temp_file_ipv4}" "${temp_file_ipv6}"; then
      ((valid_count += 1))
    else
      ((invalid_count += 1))
    fi
  done < "${temp_input}"

  if [[ ${valid_count} -gt 0 ]]; then
    log_info \
      "解析 IP 列表：${valid_count} 条有效，${invalid_count} 条无效"
  fi
  if [[ ${invalid_count} -eq ${total_count} ]]; then
    log_info "所有输入 IP (${invalid_count} 条) 无效，已跳过"
    return 1
  fi
}

deduplicate_and_sort_ips() {
  local temp_file="$1" output_file="$2"
  sort -u "${temp_file}" > "${output_file}" 2>/dev/null
}

check_and_limit_ip_count() {
  local ip_file="$1" ip_type="$2"
  local count
  count=$(wc -l < "${ip_file}")
  if [[ ${count} -gt ${MAX_IP_LIMIT} ]]; then
    log_warning \
      "${ip_type} IP 数量超出上限 ${MAX_IP_LIMIT}，截取前 ${MAX_IP_LIMIT} 条"
    head -n "${MAX_IP_LIMIT}" "${ip_file}" > "${ip_file}.tmp" \
      && mv "${ip_file}.tmp" "${ip_file}"
    count=${MAX_IP_LIMIT}
  fi
  printf "%s" "${count}"
}
