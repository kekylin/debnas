#!/bin/bash
# hosts-sync: 多 DNS 并行解析模块
set -euo pipefail
IFS=$'\n\t'

# 识别 IP 地址类型
# 参数：$1 - IP 地址
# 返回：ipv4、ipv6 或 unknown
get_ip_type() {
  local ip="$1"
  if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "ipv4"
  elif [[ "$ip" =~ ^([0-9a-fA-F]{0,4}:){2,} ]]; then
    echo "ipv6"
  else
    echo "unknown"
  fi
}

# 判断 IP 是否可作为 hosts 条目（排除 DNS 污染常见的 0.0.0.0/回环/私网/保留地址）
# 参数：$1 - IP 地址
# 返回：0 可用，1 不可用
is_usable_public_ip() {
  local ip="$1"
  local a b c d
  if [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
    a=$((10#${BASH_REMATCH[1]})); b=$((10#${BASH_REMATCH[2]}))
    c=$((10#${BASH_REMATCH[3]})); d=$((10#${BASH_REMATCH[4]}))
    (( a > 255 || b > 255 || c > 255 || d > 255 )) && return 1
    (( a == 0 || a == 10 || a == 127 || a >= 224 )) && return 1
    (( a == 100 && b >= 64 && b <= 127 )) && return 1
    (( a == 169 && b == 254 )) && return 1
    (( a == 172 && b >= 16 && b <= 31 )) && return 1
    (( a == 192 && b == 168 )) && return 1
    (( a == 192 && b == 0 && (c == 0 || c == 2) )) && return 1
    (( a == 198 && (b == 18 || b == 19) )) && return 1
    (( a == 198 && b == 51 && c == 100 )) && return 1
    (( a == 203 && b == 0 && c == 113 )) && return 1
    return 0
  fi
  local lower="${ip,,}"
  case "$lower" in
    ::|::1|::ffff:*|fe8*|fe9*|fea*|feb*|fc*|fd*|ff*|2001:db8:*|64:ff9b:*) return 1 ;;
  esac
  [[ "$lower" == *:* ]]
}

# 从 dig +short 输出中筛选 IP：整行必须就是一个地址
# dig 的报错（如 ";; communications error to 223.5.5.5#53: timed out"）也写在 stdout，
# 旧实现用 grep -o 抠 IP 会把 DNS 服务器自己的地址当成解析结果
# 参数：$1 - 类型 A/AAAA，$2 - DNS 服务器地址；stdin 为 dig +short 输出
# 输出：可用的 IP（每行一个）
filter_dig_answers() {
  local rtype="$1" dns="$2" line
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "$line" || "$line" == ';'* ]] && continue
    if [[ "$rtype" == "A" ]]; then
      [[ "$line" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || continue
    else
      [[ "$line" =~ ^[0-9a-fA-F:]+$ && "$line" == *:*:* ]] || continue
    fi
    [[ "$line" == "$dns" ]] && continue
    is_usable_public_ip "$line" && printf '%s\n' "$line"
  done
  return 0
}

# 解析单个 DNS 服务器的 A/AAAA 记录
# 参数：$1 - 域名，$2 - DNS 服务器地址
# 返回：IP 地址列表（每行一个）
resolve_from_dns() {
  local domain="$1"
  local dns="$2"

  if [[ "$IP_MODE" == "True" ]] || [[ "$IP_MODE" == "IPv4" ]]; then
    timeout 5 dig +short "@$dns" A "$domain" 2>/dev/null | filter_dig_answers A "$dns" || true
  fi

  if [[ "$IP_MODE" == "True" ]] || [[ "$IP_MODE" == "IPv6" ]]; then
    timeout 5 dig +short "@$dns" AAAA "$domain" 2>/dev/null | filter_dig_answers AAAA "$dns" || true
  fi
  return 0
}

# 从多个 DNS 服务器并行解析域名获取 IP 地址
# 参数：$1 - 域名，$2 - DNS 服务器数组引用
# 返回：IP 地址数组（格式：IP|DNS，已去重）
resolve_domain_ips() {
  local domain="$1"
  local -n dns_servers_ref="$2"
  local -a all_ips=()
  local -a pids=() tmp_files=()
  local dns tmp_file pid line

  # 临时文件名由 mktemp 保证唯一，无需再按域名哈希区分
  for dns in "${dns_servers_ref[@]}"; do
    tmp_file=$(create_temp_file "dns-${dns}") || continue
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
  
  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done

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
  
  # 按 IP 去重（保留首个 DNS 来源）；无结果时不输出任何行（空行会被调用方 mapfile 当成 1 个候选）
  local -A seen_ips=()
  local ip_dns ip
  for ip_dns in "${all_ips[@]}"; do
    ip="${ip_dns%%|*}"
    [[ -n "${seen_ips[$ip]:-}" ]] && continue
    seen_ips["$ip"]=1
    printf '%s\n' "$ip_dns"
  done
}

# 解析单个域名、检测连通性并把选中的 IP 追加到输出文件
# 参数：$1 - "域名|组名"，$2 - 输出文件
# 结果写全局 RESOLVE_RESULT（success / unresolved / unreachable），由 process_all_domains 统计
# shellcheck disable=SC2034  # RESOLVE_RESULT 由 hosts-manager.sh 读取
resolve_domain() {
  # local - 使 set +e 仅在本函数内生效，返回时恢复调用方的 errexit
  local -
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
  mapfile -t test_results < <(test_ips_concurrently all_ips "$domain" "$group")
  
  if [[ ${#test_results[@]} -eq 0 ]]; then
    if [[ $CRON_MODE -eq 0 ]]; then
      echo "  所有 IP 均不可达: $domain" >&2
    fi
    echo "# ${domain}  # 无法连通" >> "${output_file}"
    RESOLVE_RESULT="unreachable"
    return
  fi
  
  # select_best_ips 无结果时不输出任何行
  local -a selected_ips
  mapfile -t selected_ips < <(select_best_ips test_results "$domain")
  
  if [[ $CRON_MODE -eq 0 ]]; then
    echo "  连通性检测完成，共测试 ${#all_ips[@]} 个 IP，${#test_results[@]} 个可用，选中 ${#selected_ips[@]} 个: $domain" >&2
  fi
  
  local wrote_success=0
  
  if [[ ${#selected_ips[@]} -eq 0 ]]; then
    local first_result="${test_results[0]}"
    local ip dns https_result tcp_result ping_result
    IFS='|' read -r ip dns https_result tcp_result ping_result _ <<< "$first_result"
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
