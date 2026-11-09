#!/bin/bash
# threat-ips: IPSet 管理模块

set -euo pipefail
IFS=$'\n\t'

# ==================== 工具函数 ====================
check_ipset_exists() {
  local ipset_name="$1"
  firewall-cmd --permanent --get-ipsets | grep -qw "${ipset_name}"
}

check_ipset_bound() {
  local ipset_name="$1" zone="$2"
  firewall-cmd --permanent --zone="${zone}" --list-sources \
    | grep -qw "ipset:${ipset_name}"
}

# 使用 sipcalc 验证 IPv4 地址（支持 CIDR 格式）
validate_ipv4() {
  local ip=$1 sipcalc_output
  if [[ ! "${ip}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){0,3}(/[0-9]{1,2})?$ ]]; then
    return 1
  fi
  if sipcalc_output=$(sipcalc "${ip}" 2>/dev/null); then
    if printf "%s" "${sipcalc_output}" | grep -qiE "^\\-\\[ipv4\\s*:"; then
      return 0
    fi
  fi
  return 1
}

# 使用 sipcalc 验证 IPv6 地址（支持 CIDR 格式）
validate_ipv6() {
  local ip=$1 sipcalc_output
  if [[ ! "${ip}" =~ ^[0-9a-fA-F:]+(/[0-9]{1,3})?$ ]]; then
    return 1
  fi
  if sipcalc_output=$(sipcalc "${ip}" 2>/dev/null); then
    if printf "%s" "${sipcalc_output}" | grep -qiE "^\\-\\[ipv6\\s*:"; then
      return 0
    fi
  fi
  return 1
}

# 使用 sipcalc 验证 IP 地址并返回类型（输出 "ipv4" 或 "ipv6"）
validate_ip() {
  local ip=$1 sipcalc_output
  if sipcalc_output=$(sipcalc "${ip}" 2>/dev/null); then
    if printf "%s" "${sipcalc_output}" | grep -qiE "^\\-\\[ipv4\\s*:"; then
      printf "ipv4"
      return 0
    elif printf "%s" "${sipcalc_output}" | grep -qiE "^\\-\\[ipv6\\s*:"; then
      printf "ipv6"
      return 0
    fi
  fi
  return 1
}

# 验证 IPv4 CIDR 格式并提取前缀和掩码（输出 "前缀 掩码"）
validate_cidr_ipv4() {
  local input=$1 prefix mask sipcalc_output
  if [[ ! ${input} =~ ^([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})/([0-9]{1,2})$ ]]; then
    return 1
  fi
  prefix=${BASH_REMATCH[1]}
  mask=${BASH_REMATCH[2]}
  if [[ ! ${mask} =~ ^[0-9]+$ ]] || [[ ${mask} -gt 32 ]] || [[ ${mask} -lt 0 ]]; then
    return 1
  fi
  if sipcalc_output=$(sipcalc "${input}" 2>/dev/null); then
    if printf "%s" "${sipcalc_output}" | grep -qiE "^\\-\\[ipv4\\s*:"; then
      printf "%s %s" "${prefix}" "${mask}"
      return 0
    fi
  fi
  return 1
}


# ==================== 通用 IPSet 操作模块 ====================
# 配置单个 IPSet：创建并绑定到区域
# 返回：0 表示需要重载，1 表示无需重载
configure_single_ipset() {
  local ipset_name="$1" ip_family="$2" ip_type="$3"
  local need_log=0 need_reload=0

  if ! check_ipset_exists "${ipset_name}"; then
    need_log=1
    if ! firewall-cmd --permanent \
      --new-ipset="${ipset_name}" \
      --type=hash:net \
      --option=family="${ip_family}" \
      --option=maxelem=${MAX_IP_LIMIT} &>/dev/null; then
      log_error "配置 ${ip_type} IPSet 失败（请检查 Firewalld 配置）"
      exit "${ERROR_GENERAL}"
    fi
    need_reload=1
  fi
  if ! check_ipset_bound "${ipset_name}" "${ZONE}"; then
    need_log=1
    if ! firewall-cmd --permanent \
      --zone="${ZONE}" \
      --add-source="ipset:${ipset_name}" &>/dev/null; then
      log_error "配置 ${ip_type} IPSet 失败"
      exit "${ERROR_GENERAL}"
    fi
    need_reload=1
  fi
  if [[ ${need_log} -eq 1 ]]; then
    log_info "配置 ${ip_type} IPSet 于 drop 区域"
  fi
  [[ ${need_reload} -eq 1 ]]
}

configure_ipset() {
  local need_reload=0
  if configure_single_ipset "${IPSET_NAME_IPV4}" "inet" "IPv4"; then
    need_reload=1
  fi
  if configure_single_ipset "${IPSET_NAME_IPV6}" "inet6" "IPv6"; then
    need_reload=1
  fi
  [[ ${need_reload} -eq 1 ]]
}

validate_zone() {
  if ! firewall-cmd --get-zones | grep -qw "${ZONE}"; then
    log_error "无效 Firewalld 区域：${ZONE}"
    exit "${ERROR_GENERAL}"
  fi
}
