#!/bin/bash
# hosts-sync: 三级连通性检测模块
set -euo pipefail
IFS=$'\n\t'
test_https_connectivity() {
  local ip="$1"
  local domain="$2"
  local ip_type
  ip_type=$(get_ip_type "$ip")
  
  if [[ "$ip_type" == "ipv6" ]]; then
    timeout 4 curl -s -k --connect-timeout 2 -m 2 -H "Host: $domain" "https://[$ip]" >/dev/null 2>&1
  else
    timeout 4 curl -s -k --connect-timeout 2 -m 2 -H "Host: $domain" "https://$ip" >/dev/null 2>&1
  fi
}

# TCP 端口连通性检测
# 参数：$1 - IP 地址，$2 - 端口（默认 443）
# 返回：0 成功，非 0 失败
test_tcp_connectivity() {
  local ip="$1"
  local port="${2:-443}"
  local ip_type
  ip_type=$(get_ip_type "$ip")
  
  if [[ "$ip_type" == "ipv6" ]]; then
    if timeout 3 bash -c "exec 3<>/dev/tcp/[$ip]/$port" 2>/dev/null; then
      exec 3>&- 3<&-
      return 0
    fi
  else
    if timeout 3 bash -c "exec 3<>/dev/tcp/$ip/$port" 2>/dev/null; then
      exec 3>&- 3<&-
      return 0
    fi
  fi
  return 1
}

# 解析 ping 输出中的延迟值
# 参数：$1 - ping 输出文本
# 返回：延迟值（毫秒，整数），失败返回空字符串
parse_ping_delay() {
  local ping_output="$1"
  local delay=""
  
  if [[ -z "$ping_output" ]]; then
    echo ""
    return 1
  fi
  
  if command -v grep >/dev/null 2>&1 && grep -oP 'time=\K[0-9.]+' <<< "$ping_output" >/dev/null 2>&1; then
    delay=$(grep -oP 'time=\K[0-9.]+' <<< "$ping_output" | head -1)
  fi
  
  if [[ -z "$delay" ]] && command -v awk >/dev/null 2>&1; then
    delay=$(awk -F'=' '/time=/{print $NF}' <<< "$ping_output" | awk '{print $1}' | head -1)
  fi
  
  if [[ -n "$delay" ]] && command -v awk >/dev/null 2>&1; then
    delay=$(awk "BEGIN {printf \"%.0f\", $delay}")
  fi
  
  echo "${delay:-}"
}

# Ping 连通性检测并返回延迟值
# 参数：$1 - IP 地址
# 返回：延迟值（毫秒，整数），失败返回空字符串
test_ping_connectivity() {
  local ip="$1"
  local ip_type
  ip_type=$(get_ip_type "$ip")
  local ping_output
  local delay=""
  
  if [[ "$ip_type" == "ipv6" ]]; then
    ping_output=$(timeout 3 ping6 -c 1 -W 2 "$ip" 2>&1 || echo "")
  else
    ping_output=$(timeout 3 ping -c 1 -W 2 "$ip" 2>&1 || echo "")
  fi
  
  delay=$(parse_ping_delay "$ping_output")
  echo "${delay:-}"
}

# 判断是否为需要严格检测的域名
# 参数：$1 - 域名组名
# 返回：0 需要严格检测，1 普通检测
is_strict_domain() {
  local group="$1"
  if [[ "$group" == "GitHub" ]]; then
    return 0
  fi
  return 1
}

# 三级连通性检测（汇总所有检测结果和延迟）
# 参数：$1 - IP 地址，$2 - 域名，$3 - 域名组名（可选）
# 返回：检测结果（格式：https|tcp|ping|延迟）
#       https/tcp/ping 字段：1表示通过，0表示失败
#       延迟字段：ping延迟毫秒数（整数），无延迟则为空
test_ip_connectivity() {
  local ip="$1"
  local domain="$2"
  local group="${3:-}"
  local https_result=0
  local tcp_result=0
  local ping_result=0
  local ping_delay=""
  
  if test_https_connectivity "$ip" "$domain"; then
    https_result=1
  fi
  
  if test_tcp_connectivity "$ip" 443; then
    tcp_result=1
  fi
  
  ping_delay=$(test_ping_connectivity "$ip")
  if [[ -n "$ping_delay" ]]; then
    ping_result=1
  fi
  
  if is_strict_domain "$group"; then
    if [[ $https_result -eq 1 ]] && [[ $tcp_result -eq 1 ]]; then
      echo "${https_result}|${tcp_result}|${ping_result}|${ping_delay}"
      return 0
    fi
    echo ""
    return 1
  fi
  
  if [[ $https_result -eq 1 ]] || [[ $tcp_result -eq 1 ]] || [[ $ping_result -eq 1 ]]; then
    echo "${https_result}|${tcp_result}|${ping_result}|${ping_delay}"
    return 0
  fi
  
  echo ""
  return 1
}

# 并发检测 IP 地址连通性
# 参数：$1 - IP 地址数组引用（格式：IP|DNS），$2 - 域名
# 返回：可用 IP 地址列表（格式：IP|DNS|https|tcp|ping|延迟）

test_ips_concurrently() {
  local -n ips_ref="$1"
  local domain="$2"
  local -a results=()
  local pids=()
  local tmp_files=()
  local running=0
  local index=0
  
  local -a valid_ips=()
  for ip_dns in "${ips_ref[@]}"; do
    if [[ -n "$ip_dns" && "$ip_dns" != "" ]]; then
      local ip
      IFS='|' read -r ip _ <<< "$ip_dns"
      if [[ -n "$ip" && "$ip" != "" ]]; then
        valid_ips+=("$ip_dns")
      fi
    fi
  done

  if [[ ${#valid_ips[@]} -eq 0 ]]; then
    return 0
  fi
  
  for ip_dns in "${valid_ips[@]}"; do
    local ip safe_ip_hash
    IFS='|' read -r ip _ <<< "$ip_dns"
    safe_ip_hash=$(get_domain_hash "$ip")
    local tmp_file
    tmp_file=$(create_temp_file "test-${safe_ip_hash}") || continue
    tmp_files+=("$tmp_file")
  done
  
  while [[ $index -lt ${#valid_ips[@]} ]] || [[ $running -gt 0 ]]; do
    while [[ $running -lt $CONCURRENT_THREADS ]] && [[ $index -lt ${#valid_ips[@]} ]]; do
      local ip_dns="${valid_ips[$index]}"
      local tmp_file="${tmp_files[$index]}"
      local ip dns
      IFS='|' read -r ip dns <<< "$ip_dns"
      
      (
        local test_result
        local domain_group_info
        domain_group_info=$(printf '%s\n' "${DOMAINS[@]}" | grep "^${domain}|" | head -1 || echo "")
        local group=""
        if [[ -n "$domain_group_info" ]]; then
          IFS='|' read -r _ group <<< "$domain_group_info"
        fi
        test_result=$(test_ip_connectivity "$ip" "$domain" "$group")
        if [[ -n "$test_result" ]]; then
          echo "${ip}|${dns}|${test_result}" > "$tmp_file"
        fi
      ) &
      pids+=($!)
      ((running++)) || true
      ((index++)) || true
    done
    
    if [[ $running -gt 0 ]]; then
      local wait_pid
      for wait_pid in "${pids[@]}"; do
        if wait "$wait_pid" 2>/dev/null; then
          ((running--)) || true
          local -a new_pids=()
          local pid
          for pid in "${pids[@]}"; do
            if [[ "$pid" != "$wait_pid" ]]; then
              new_pids+=("$pid")
            fi
          done
          pids=("${new_pids[@]}")
          break
        fi
      done
    fi
  done
  
  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
  
  for tmp_file in "${tmp_files[@]}"; do
    if [[ -f "$tmp_file" ]]; then
      while IFS= read -r line; do
        if [[ -n "$line" ]]; then
          local ip
          IFS='|' read -r ip _ <<< "$line"
          if [[ -n "$ip" && "$ip" != "" ]]; then
            results+=("$line")
          fi
        fi
      done < "$tmp_file"
      rm -f "$tmp_file" 2>/dev/null || true
    fi
  done
  
  printf '%s\n' "${results[@]}"
}

# 计算延迟分数
# 参数：$1 - ping 延迟（毫秒，整数）
# 返回：延迟分数（0-100，越高越好）
calculate_latency_score() {
  local delay="$1"
  local score=0
  
  if [[ -z "$delay" ]] || ! [[ "$delay" =~ ^[0-9]+$ ]]; then
    echo "50"
    return 0
  fi
  
  if [[ $delay -le 200 ]]; then
    score=100
  elif [[ $delay -le 400 ]]; then
    score=80
  elif [[ $delay -le 600 ]]; then
    score=60
  elif [[ $delay -le 800 ]]; then
    score=40
  elif [[ $delay -le 1000 ]]; then
    score=20
  else
    score=0
  fi
  
  echo "$score"
}

# 计算 IP 评分
# 参数：$1 - HTTPS 结果（1/0），$2 - TCP 结果（1/0），$3 - Ping 结果（1/0），$4 - Ping 延迟（毫秒，可为空）
# 返回：评分（整数，越高越好）
calculate_ip_score() {
  local https_result="$1"
  local tcp_result="$2"
  local ping_result="$3"
  local ping_delay="$4"
  
  local function_score=0
  if [[ "$https_result" == "1" ]]; then
    ((function_score += 100))
  fi
  
  if [[ "$tcp_result" == "1" ]]; then
    ((function_score += 50))
  fi
  
  if [[ "$ping_result" == "1" ]]; then
    ((function_score += 25))
  fi
  
  local latency_score=0
  if [[ -n "$ping_delay" ]] && [[ "$ping_delay" =~ ^[0-9]+$ ]]; then
    latency_score=$(calculate_latency_score "$ping_delay")
  else
    latency_score=50
  fi
  
  local latency_weighted=$((latency_score * 30 / 100))
  local score=$((function_score + latency_weighted))
  
  echo "$score"
}

# 确定检测方法名称
# 参数：$1 - HTTPS 结果（1/0），$2 - TCP 结果（1/0），$3 - Ping 结果（1/0）
# 返回：检测方法名称（优先级：https > tcp > ping）
get_detection_method() {
  local https_result="$1"
  local tcp_result="$2"
  local ping_result="$3"
  
  if [[ "$https_result" == "1" ]]; then
    echo "https"
  elif [[ "$tcp_result" == "1" ]]; then
    echo "tcp"
  elif [[ "$ping_result" == "1" ]]; then
    echo "ping"
  else
    echo ""
  fi
}

# 选择最优 IP 地址
# 参数：$1 - 检测结果数组引用（格式：IP|DNS|https|tcp|ping|延迟），$2 - 域名（可选，用于日志）
# 返回：选中的 IP 地址列表（格式：IP|DNS|检测方法，每行一个）
