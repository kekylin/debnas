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

  if ! wget -q --timeout=60 --tries=3 "${download_url}" -O "${temp_gz}"; then
    log_error \
      "下载威胁 IP 列表失败（威胁等级：${threat_level}）"
    return 1
  fi
  if ! gzip -dc "${temp_gz}" > "${temp_txt}"; then
    log_error "解压威胁 IP 列表失败"
    return 1
  fi
  if [[ ! -s "${temp_txt}" ]]; then
    log_error "威胁 IP 列表为空，放弃本次更新（保留现有封禁）"
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

# 收集受保护地址（不得被封禁）：保留/私有网段、本机地址、当前登录会话来源、用户白名单
collect_protected_addresses() {
  printf '%s\n' 0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 \
    172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 240.0.0.0/4
  if command -v ip &>/dev/null; then
    ip -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 || true
  fi
  if [[ -n "${SSH_CLIENT:-}" ]]; then
    printf '%s\n' "${SSH_CLIENT%% *}"
  fi
  if command -v who &>/dev/null; then
    who 2>/dev/null | grep -oE '\([0-9a-fA-F:.]+\)' | tr -d '()' || true
  fi
  if [[ -f "${WHITELIST_FILE}" ]]; then
    sed 's/#.*//' "${WHITELIST_FILE}" | awk 'NF {print $1}' || true
  fi
}

# 剔除受保护地址与过宽条目，并把 IPv4 规范化为十进制（去前导 0、CIDR 取网络地址）
# 参数：$1 - IP 文件（原地改写），$2 - 类型 IPv4/IPv6
filter_protected_entries() {
  local ip_file="$1" ip_type="$2"
  local protected_file stat_file filtered_file stats
  protected_file=$(create_temp_file "protected" ".txt") || return 1
  stat_file=$(create_temp_file "filter_stat" ".txt") || return 1
  filtered_file=$(create_temp_file "filtered_${ip_type}" ".txt") || return 1
  collect_protected_addresses > "${protected_file}"

  if [[ "${ip_type}" == "IPv4" ]]; then
    awk -v minmask="${MIN_IPV4_PREFIX}" -v statfile="${stat_file}" '
      function ip2n(s,   o, i) {
        if (split(s, o, ".") != 4) return -1
        for (i = 1; i <= 4; i++) if (o[i] !~ /^[0-9]+$/ || o[i] + 0 > 255) return -1
        return ((o[1] * 256 + o[2]) * 256 + o[3]) * 256 + o[4]
      }
      function parse(s,   t, p, m, n, blk) {
        p = s; m = 32
        if (index(s, "/")) { split(s, t, "/"); p = t[1]; m = t[2] }
        if (m !~ /^[0-9]+$/ || m + 0 > 32) return 0
        m += 0; n = ip2n(p)
        if (n < 0) return 0
        blk = 2 ^ (32 - m)
        R_S = int(n / blk) * blk; R_E = R_S + blk - 1; R_M = m
        return 1
      }
      NR == FNR { if ($1 !~ /:/ && parse($1)) { ps[++np] = R_S; pe[np] = R_E }; next }
      {
        if (!parse($1)) { bad++; next }
        if (R_M < minmask) { wide++; next }
        for (k = 1; k <= np; k++) if (R_S <= pe[k] && R_E >= ps[k]) { prot++; next }
        n = R_S
        printf "%d.%d.%d.%d", int(n / 16777216), int(n / 65536) % 256, int(n / 256) % 256, n % 256
        if (index($1, "/")) printf "/%d", R_M
        printf "\n"
      }
      END { print bad + 0, wide + 0, prot + 0 > statfile }
    ' "${protected_file}" "${ip_file}" > "${filtered_file}"
  else
    awk -v minmask="${MIN_IPV6_PREFIX}" -v statfile="${stat_file}" '
      NR == FNR { if ($1 ~ /:/) { a = tolower($1); sub(/\/128$/, "", a); own[a] = 1 }; next }
      {
        e = tolower($1); addr = e; m = 128
        if (index(e, "/")) { split(e, t, "/"); addr = t[1]; m = t[2] + 0 }
        if (m < minmask) { wide++; next }
        if (addr == "::" || addr == "::1" || addr ~ /^(fe[89ab]|f[cd]|ff)/ || (addr in own)) { prot++; next }
        print $1
      }
      END { print 0, wide + 0, prot + 0 > statfile }
    ' "${protected_file}" "${ip_file}" > "${filtered_file}"
  fi

  mv "${filtered_file}" "${ip_file}"
  stats=$(cat "${stat_file}" 2>/dev/null) || stats=""
  rm -f "${protected_file}" "${stat_file}"
  local s_bad s_wide s_prot
  IFS=' ' read -r s_bad s_wide s_prot <<< "${stats:-0 0 0}"
  if [[ "${s_wide:-0}" -gt 0 || "${s_prot:-0}" -gt 0 || "${s_bad:-0}" -gt 0 ]]; then
    log_warning "${ip_type} 已剔除：过宽网段 ${s_wide:-0} 条，命中保护/白名单 ${s_prot:-0} 条，格式无效 ${s_bad:-0} 条"
  fi
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
