#!/bin/bash
# hosts-sync: 三级连通性检测模块
set -euo pipefail
IFS=$'\n\t'
test_https_connectivity() {
  local ip="$1"
  local domain="$2"
  local ip_type
  ip_type=$(get_ip_type "$ip")
  
  # 用 --resolve 把域名钉到待测 IP：带正确 SNI 并校验证书，劫持/污染 IP 无法通过
  if [[ "$ip_type" == "ipv6" ]]; then
    timeout 4 curl -s --connect-timeout 2 -m 3 --resolve "${domain}:443:[${ip}]" "https://${domain}/" -o /dev/null >/dev/null 2>&1
  else
    timeout 4 curl -s --connect-timeout 2 -m 3 --resolve "${domain}:443:${ip}" "https://${domain}/" -o /dev/null >/dev/null 2>&1
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
  local ping_output="$1" delay=""

  if [[ -z "$ping_output" ]]; then
    echo ""
    return 1
  fi
  # 取第一个 time=<毫秒>，四舍五入为整数（LC_ALL=C 保证小数点按 "." 解析）
  if [[ "$ping_output" =~ time=([0-9.]+) ]]; then
    LC_ALL=C printf -v delay '%.0f' "${BASH_REMATCH[1]}" 2>/dev/null || delay=""
  fi
  echo "${delay}"
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

# 并发检测 IP 地址连通性（最多 CONCURRENT_THREADS 路，任一路结束即补位）
# 参数：$1 - IP 地址数组引用（格式：IP|DNS），$2 - 域名，$3 - 域名组名（GitHub 组严格检测）
# 返回：可用 IP 地址列表（格式：IP|DNS|https|tcp|ping|延迟），按输入顺序
test_ips_concurrently() {
  local -n ips_ref="$1"
  local domain="$2" group="${3:-}"
  local -a valid_ips=() tmp_files=()
  local ip_dns ip dns tmp_file line running=0

  for ip_dns in "${ips_ref[@]}"; do
    [[ "${ip_dns%%|*}" != "" ]] && valid_ips+=("$ip_dns")
  done

  for ip_dns in "${valid_ips[@]}"; do
    IFS='|' read -r ip dns <<< "$ip_dns"
    tmp_file=$(create_temp_file "test") || continue
    tmp_files+=("$tmp_file")
    if (( running >= CONCURRENT_THREADS )); then
      wait -n 2>/dev/null || true
      ((running--)) || true
    fi
    (
      local test_result
      test_result=$(test_ip_connectivity "$ip" "$domain" "$group")
      [[ -z "$test_result" ]] || echo "${ip}|${dns}|${test_result}" > "$tmp_file"
    ) &
    ((running++)) || true
  done
  wait 2>/dev/null || true

  for tmp_file in "${tmp_files[@]}"; do
    [[ -s "$tmp_file" ]] || { rm -f "$tmp_file"; continue; }
    while IFS= read -r line; do
      [[ -n "${line%%|*}" ]] && printf '%s\n' "$line"
    done < "$tmp_file"
    rm -f "$tmp_file" 2>/dev/null || true
  done
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
