#!/bin/bash
# auto-update-hosts: 多 DNS 并行解析模块
set -euo pipefail
IFS=$'\n\t'
get_domain_hash() {
  local domain="$1"
  if command -v md5sum >/dev/null 2>&1; then
    printf '%s\n' "${domain}" | md5sum | awk '{print $1}'
  elif command -v md5 >/dev/null 2>&1; then
    printf '%s\n' "${domain}" | md5 | awk '{print $1}'
  else
    printf '%s\n' "${domain}" | sha256sum 2>/dev/null | awk '{print substr($1,1,16)}' || echo "fallback"
  fi
}

# 识别 IP 地址类型
# 参数：$1 - IP 地址
# 返回：ipv4、ipv6 或 unknown
get_ip_type() {
  local ip="$1"
  if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "ipv4"
  elif command -v ping6 >/dev/null 2>&1 && ping6 -c 1 -W 1 "$ip" &>/dev/null; then
    echo "ipv6"
  else
    echo "unknown"
  fi
}

# 解析单个 DNS 服务器的 A/AAAA 记录
# 参数：$1 - 域名，$2 - DNS 服务器地址
# 返回：IP 地址列表（每行一个）
resolve_from_dns() {
  local domain="$1"
  local dns="$2"
  local -a ips=()
  
  if [[ "$IP_MODE" == "True" ]] || [[ "$IP_MODE" == "IPv4" ]]; then
    local ipv4_ips
    ipv4_ips=$(timeout 5 dig +short "@$dns" A "$domain" 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' || true)
    for ip in $ipv4_ips; do
      if [[ -n "$ip" ]]; then
        ips+=("$ip")
      fi
    done
  fi
  
  if [[ "$IP_MODE" == "True" ]] || [[ "$IP_MODE" == "IPv6" ]]; then
    local ipv6_ips
    ipv6_ips=$(timeout 5 dig +short "@$dns" AAAA "$domain" 2>/dev/null | grep -Eo '([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}' || true)
    for ip in $ipv6_ips; do
      if [[ -n "$ip" ]]; then
        ips+=("$ip")
      fi
    done
  fi
  
  printf '%s\n' "${ips[@]}"
}

# 从多个 DNS 服务器并行解析域名获取 IP 地址
# 参数：$1 - 域名，$2 - DNS 服务器数组引用
# 返回：IP 地址数组（格式：IP|DNS，已去重）
resolve_domain_ips() {
  local domain="$1"
  local -n dns_servers_ref="$2"
  local -a all_ips=()
  local pids=()
  local tmp_files=()
  local safe_domain_hash
  safe_domain_hash=$(get_domain_hash "$domain")
  local found_ipv4=0
  
  for dns in "${dns_servers_ref[@]}"; do
    local tmp_file
    tmp_file=$(mktemp "${TMP_DIR}/dns-${dns}-${safe_domain_hash}.XXXXXX") || continue
    tmp_files+=("$tmp_file")
    
    (
      local -a ips
      mapfile -t ips < <(resolve_from_dns "$domain" "$dns")
      for ip in "${ips[@]}"; do
        if [[ -n "$ip" ]]; then
          echo "${ip}|${dns}"
        fi
      done
    ) > "$tmp_file" 2>/dev/null &
    pids+=($!)
  done
  
  if [[ "$IP_MODE" == "IPv4" ]]; then
    local early_found=0
    for pid in "${pids[@]}"; do
      if wait "$pid" 2>/dev/null; then
        for tmp_file in "${tmp_files[@]}"; do
          if [[ -f "$tmp_file" ]]; then
            while IFS= read -r line; do
              if [[ -n "$line" ]]; then
                local ip
                IFS='|' read -r ip _ <<< "$line"
                if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
                  found_ipv4=1
                  early_found=1
                  break 2
                fi
              fi
            done < "$tmp_file"
          fi
        done
      fi
      [[ $early_found -eq 1 ]] && break
    done
    
    for pid in "${pids[@]}"; do
      wait "$pid" 2>/dev/null || true
    done
  else
    for pid in "${pids[@]}"; do
      wait "$pid" 2>/dev/null || true
    done
  fi
  
  for tmp_file in "${tmp_files[@]}"; do
    if [[ -f "$tmp_file" ]]; then
      while IFS= read -r line; do
        if [[ -n "$line" ]]; then
          all_ips+=("$line")
        fi
      done < "$tmp_file"
      rm -f "$tmp_file" 2>/dev/null || true
    fi
  done
  
  if [[ ${#all_ips[@]} -gt 0 ]]; then
    declare -A seen_ips
    local -a unique_ips=()
    for ip_dns in "${all_ips[@]}"; do
      local ip
      IFS='|' read -r ip _ <<< "$ip_dns"
      if [[ -z "${seen_ips[$ip]:-}" ]]; then
        seen_ips["$ip"]=1
        unique_ips+=("$ip_dns")
      fi
    done
    all_ips=("${unique_ips[@]}")
  fi
  
  printf '%s\n' "${all_ips[@]}"
}

# HTTPS 连通性检测（携带 Host 头，跳过证书验证）
# 参数：$1 - IP 地址，$2 - 域名

resolve_domain() {
  set +e
  
  local domain_group="$1"
  local output_file="$2"
  local domain group
  IFS='|' read -r domain group <<< "$domain_group"
  RESOLVE_RESULT="unresolved"
  
  if [[ $CRON_MODE -eq 0 ]]; then
    echo "正在解析域名: $domain" >&2
  fi
  
  local -a all_ips
  mapfile -t all_ips < <(resolve_domain_ips "$domain" DNS_SERVERS)
  
  if [[ ${#all_ips[@]} -eq 0 ]]; then
    if [[ $CRON_MODE -eq 0 ]]; then
      echo "  无法解析到 IP 地址: $domain" >&2
    fi
    echo "# ${domain}  # 无法解析" >> "${output_file}"
    RESOLVE_RESULT="unresolved"
    return
  fi
  
  if [[ $CRON_MODE -eq 0 ]]; then
    echo "  获取到 ${#all_ips[@]} 个候选 IP（IPv4/IPv6），开始三级连通性检测: $domain" >&2
  fi
  
  local -a test_results
  mapfile -t test_results < <(test_ips_concurrently all_ips "$domain")
  
  if [[ ${#test_results[@]} -eq 0 ]]; then
    if [[ $CRON_MODE -eq 0 ]]; then
      echo "  所有 IP 均不可达: $domain" >&2
    fi
    echo "# ${domain}  # 无法连通" >> "${output_file}"
    RESOLVE_RESULT="unreachable"
    return
  fi
  
  local -a selected_ips
  mapfile -t selected_ips < <(select_best_ips test_results "$domain")
  
  if [[ ${#selected_ips[@]} -gt 0 ]]; then
    local -a filtered_selected=()
    local ip_item
    for ip_item in "${selected_ips[@]}"; do
      if [[ -n "$ip_item" && "$ip_item" != "" ]]; then
        filtered_selected+=("$ip_item")
      fi
    done
    selected_ips=("${filtered_selected[@]}")
  fi
  
  if [[ $CRON_MODE -eq 0 ]]; then
    echo "  连通性检测完成，共测试 ${#all_ips[@]} 个 IP，${#test_results[@]} 个可用，选中 ${#selected_ips[@]} 个: $domain" >&2
  fi
  
  local wrote_success=0
  
  if [[ ${#selected_ips[@]} -eq 0 ]]; then
    local first_result="${test_results[0]}"
    local ip dns https_result tcp_result ping_result ping_delay
    IFS='|' read -r ip dns https_result tcp_result ping_result ping_delay <<< "$first_result"
    if [[ -n "$ip" && "$ip" != "" ]]; then
      local method
      method=$(get_detection_method "$https_result" "$tcp_result" "$ping_result")
      local dns_name="${DNS_NAMES[$dns]:-$dns}"
      if [[ $CRON_MODE -eq 0 ]]; then
        echo "  警告：未匹配到满足协议的 IP，已使用首个可用结果: $ip (${method})" >&2
      fi
      print_host_entry "$ip" "$domain" "$method" "$dns_name" >> "${output_file}"
      RESOLVE_RESULT="success"
      wrote_success=1
    fi
  else
    for result in "${selected_ips[@]}"; do
      local ip dns method
      IFS='|' read -r ip dns method <<< "$result"
      [[ -z "$ip" ]] && continue
      local dns_name="${DNS_NAMES[$dns]:-$dns}"
      print_host_entry "$ip" "$domain" "$method" "$dns_name" >> "${output_file}"
      wrote_success=1
    done
  fi
  
  if [[ $wrote_success -eq 1 ]]; then
    RESOLVE_RESULT="success"
  else
    if [[ $CRON_MODE -eq 0 ]]; then
      echo "  未能写入有效 IP，视为解析失败: $domain" >&2
    fi
    echo "# ${domain}  # 无法解析" >> "${output_file}"
    RESOLVE_RESULT="unresolved"
  fi
}

# export -f 已移至 module.sh（所有子模块加载完毕后统一导出）
