#!/bin/bash
# threat-ips: IPSet 管理模块

set -euo pipefail
IFS=$'\n\t'

# ==================== 工具函数 ====================
# 查询结果先取进变量再匹配：管道里 grep -q 提前退出会让 firewall-cmd 收到 SIGPIPE，pipefail 下误判为不存在
check_ipset_exists() {
  local ipset_name="$1" out
  out=$(firewall-cmd --permanent --get-ipsets) || return 1
  grep -qw "${ipset_name}" <<< "${out}"
}

check_ipset_bound() {
  local ipset_name="$1" zone="$2" out
  out=$(firewall-cmd --permanent --zone="${zone}" --list-sources) || return 1
  grep -qw "ipset:${ipset_name}" <<< "${out}"
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
  local zones
  zones=$(firewall-cmd --get-zones) || zones=""
  if ! grep -qw "${ZONE}" <<< "${zones}"; then
    log_error "无效 Firewalld 区域：${ZONE}"
    exit "${ERROR_GENERAL}"
  fi
}
