#!/bin/bash
# 功能：自动更新 /etc/hosts 文件，通过多 DNS 并行解析和三级连通性检测选择最优 IP 地址

set -euo pipefail
IFS=$'\n\t'

# 确定运行模式：定时任务（auto_update_hosts）或交互模式
CRON_MODE=0
if [[ "${1:-}" == "auto_update_hosts" ]]; then
  CRON_MODE=1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 根据运行模式加载不同的库
if [[ $CRON_MODE -eq 1 ]]; then
  :
else
  # 交互模式下加载公共库
source "${SCRIPT_DIR}/lib/core/constants.sh"
source "${SCRIPT_DIR}/lib/core/logging.sh"
source "${SCRIPT_DIR}/lib/system/dependency.sh"
  source "${SCRIPT_DIR}/lib/system/utils.sh"
source "${SCRIPT_DIR}/lib/ui/menu.sh"
source "${SCRIPT_DIR}/lib/ui/styles.sh"
fi

# 全局配置
readonly HOSTS_FILE="/etc/hosts"
readonly START_MARK="# DebNAS Hosts Start"
readonly END_MARK="# DebNAS Hosts End"

# DNS 服务器配置（固定顺序）
readonly -a DNS_NAME_ORDER=("AliDNS" "TencentDNS" "BaiduDNS" "DNS114")
declare -Ar DNS_IP_BY_NAME=(
  ["AliDNS"]="223.5.5.5"
  ["TencentDNS"]="119.29.29.29"
  ["BaiduDNS"]="180.76.76.76"
  ["DNS114"]="114.114.114.114"
)

# 构建 DNS 服务器列表与名称映射
declare -A DNS_NAMES=()
DNS_SERVERS=()
for dns_name in "${DNS_NAME_ORDER[@]}"; do
  ip="${DNS_IP_BY_NAME[$dns_name]}"
  DNS_SERVERS+=("$ip")
  DNS_NAMES["$ip"]="$dns_name"
done

# 按固定列对齐的输出函数
print_host_entry() {
  local ip="$1"
  local domain="$2"
  local method="$3"
  local dns_name="$4"

  printf '%-39s %-60s # %-5s | DNS: %s\n' "$ip" "$domain" "$method" "$dns_name"
}

# 并行检测线程上限
readonly CONCURRENT_THREADS=8

# 域名配置（格式：域名|组名）
DOMAINS=(
  # ==== GitHub ====
  "github.githubassets.com|GitHub"
  "central.github.com|GitHub"
  "desktop.githubusercontent.com|GitHub"
  "camo.githubusercontent.com|GitHub"
  "github.map.fastly.net|GitHub"
  "github.global.ssl.fastly.net|GitHub"
  "gist.github.com|GitHub"
  "github.io|GitHub"
  "github.com|GitHub"
  "api.github.com|GitHub"
  "raw.githubusercontent.com|GitHub"
  "user-images.githubusercontent.com|GitHub"
  "favicons.githubusercontent.com|GitHub"
  "avatars5.githubusercontent.com|GitHub"
  "avatars4.githubusercontent.com|GitHub"
  "avatars3.githubusercontent.com|GitHub"
  "avatars2.githubusercontent.com|GitHub"
  "avatars1.githubusercontent.com|GitHub"
  "avatars0.githubusercontent.com|GitHub"
  "avatars.githubusercontent.com|GitHub"
  "codeload.github.com|GitHub"
  "github-cloud.s3.amazonaws.com|GitHub"
  "github-com.s3.amazonaws.com|GitHub"
  "github-production-release-asset-2e65be.s3.amazonaws.com|GitHub"
  "github-production-user-asset-6210df.s3.amazonaws.com|GitHub"
  "github-production-repository-file-5c1aeb.s3.amazonaws.com|GitHub"
  "githubstatus.com|GitHub"
  "github.community|GitHub"
  "media.githubusercontent.com|GitHub"
  "objects.githubusercontent.com|GitHub"
  "raw.github.com|GitHub"
  "copilot-proxy.githubusercontent.com|GitHub"

  # ==== TMDB ====
  "themoviedb.org|TMDB"
  "www.themoviedb.org|TMDB"
  "api.themoviedb.org|TMDB"
  "tmdb.org|TMDB"
  "api.tmdb.org|TMDB"
  "image.tmdb.org|TMDB"
  # ==== OpenSubtitles ====
  "opensubtitles.org|OpenSubtitles"
  "www.opensubtitles.org|OpenSubtitles"
  "api.opensubtitles.org|OpenSubtitles"
  # ==== Fanart ====
  "assets.fanart.tv|Fanart"
)

# 协议模式固定为双栈
readonly IP_MODE="True"

# 每种协议最多保留 1 个 IP
readonly MAX_IPS_PER_PROTOCOL="1"

# 统计计数器
TOTAL_DOMAINS=0
SUCCESS_DOMAINS=0
UNRESOLVED_DOMAINS=0
UNREACHABLE_DOMAINS=0
RESOLVE_RESULT="unknown"

# 初始化临时文件目录
setup_temp_environment() {
  local base_tmp_dir="/tmp/debian-homenas"
  
  if [[ ! -d "$base_tmp_dir" ]]; then
    if ! mkdir -p "${base_tmp_dir}"; then
      echo "无法创建临时目录: ${base_tmp_dir}" >&2
      return 1
    fi
  fi
  
  local current_mode
  current_mode=$(stat -c %a "${base_tmp_dir}" 2>/dev/null || echo "")
  if [[ "$current_mode" != "700" ]]; then
    if ! chmod 700 "${base_tmp_dir}"; then
      echo "无法设置临时目录权限" >&2
      return 1
    fi
  fi
  
  export TMP_DIR="${base_tmp_dir}"
}

# 识别 IP 地址类型
# 参数：$1 - IP 地址
# 返回：ipv4、ipv6 或 unknown
get_ip_type() {
  local ip="$1"
  if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "ipv4"
  elif [[ "$ip" =~ ^([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}$ ]]; then
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
  
  # 按协议模式筛选解析结果
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
  
  # 为每个 DNS 服务器创建临时文件
  for dns in "${dns_servers_ref[@]}"; do
    local tmp_file
    tmp_file=$(mktemp "${TMP_DIR}/dns-${dns}-${domain}.XXXXXX") || continue
    tmp_files+=("$tmp_file")
    
    # 后台并行解析，记录DNS来源
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
  
  # 等待所有 DNS 查询完成
  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
  
  # 收集所有 IP 地址（带DNS信息）
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
  
  # 去重（保留第一个出现的DNS来源）
  if [[ ${#all_ips[@]} -gt 0 ]]; then
    declare -A seen_ips
    local -a unique_ips=()
    for ip_dns in "${all_ips[@]}"; do
      local ip
      ip=$(echo "$ip_dns" | cut -d'|' -f1)
      if [[ -z "${seen_ips[$ip]:-}" ]]; then
        seen_ips["$ip"]=1
        unique_ips+=("$ip_dns")
      fi
    done
    all_ips=("${unique_ips[@]}")
  fi
  
  printf '%s\n' "${all_ips[@]}"
}

# HTTPS 直连检测（携带 Host 头，跳过证书验证）
# 参数：$1 - IP 地址，$2 - 域名
# 返回：0成功，非0失败
test_https_connectivity() {
  local ip="$1"
  local domain="$2"
  local ip_type
  ip_type=$(get_ip_type "$ip")
  
  if [[ "$ip_type" == "ipv6" ]]; then
    timeout 5 curl -s -k -m 3 --connect-timeout 2 -H "Host: $domain" "https://[$ip]" >/dev/null 2>&1
  else
    timeout 5 curl -s -k -m 3 --connect-timeout 2 -H "Host: $domain" "https://$ip" >/dev/null 2>&1
  fi
}

# TCP 443 端口连通性检测
# 参数：$1 - IP 地址，$2 - 端口（默认443）
# 返回：0成功，非0失败
test_tcp_connectivity() {
  local ip="$1"
  local port="${2:-443}"
  local ip_type
  ip_type=$(get_ip_type "$ip")
  
  if [[ "$ip_type" == "ipv6" ]]; then
    timeout 3 bash -c "exec 3<>/dev/tcp/[$ip]/$port" 2>/dev/null && exec 3<&- && exec 3>&-
  else
    timeout 3 bash -c "exec 3<>/dev/tcp/$ip/$port" 2>/dev/null && exec 3<&- && exec 3>&-
  fi
}

# Ping 检测（IPv4/IPv6 自动适配）并返回延迟值
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
  
  if [[ -n "$ping_output" ]]; then
    # 提取延迟值（支持 time=XX.XXX 或 time=XX 格式）
    delay=$(echo "$ping_output" | grep -oP 'time=\K[0-9.]+' | head -1)
    if [[ -z "$delay" ]]; then
      delay=$(echo "$ping_output" | awk -F'=' '/time=/{print $NF}' | awk '{print $1}' | head -1)
    fi
    # 转换为整数毫秒（四舍五入）
    if [[ -n "$delay" ]]; then
      delay=$(awk "BEGIN {printf \"%.0f\", $delay}")
    fi
  fi
  
  echo "${delay:-}"
}

# 三级连通性检测（汇总所有检测结果和延迟）
# 参数：$1 - IP 地址，$2 - 域名
# 返回：检测结果（格式：https|tcp|ping|延迟）
#       https/tcp/ping 字段：1表示通过，0表示失败
#       延迟字段：ping延迟毫秒数（整数），无延迟则为空
test_ip_connectivity() {
  local ip="$1"
  local domain="$2"
  local https_result=0
  local tcp_result=0
  local ping_result=0
  local ping_delay=""
  
  # 检测 HTTPS
  if test_https_connectivity "$ip" "$domain"; then
    https_result=1
  fi
  
  # 检测 TCP
  if test_tcp_connectivity "$ip" 443; then
    tcp_result=1
  fi
  
  # 检测 Ping 并获取延迟
  ping_delay=$(test_ping_connectivity "$ip")
  if [[ -n "$ping_delay" ]]; then
    ping_result=1
  fi
  
  # 至少有一种检测通过才返回结果
  if [[ $https_result -eq 1 ]] || [[ $tcp_result -eq 1 ]] || [[ $ping_result -eq 1 ]]; then
    echo "${https_result}|${tcp_result}|${ping_result}|${ping_delay}"
    return 0
  fi
  
  echo ""
  return 1
}

# 并发检测 IP 地址连通性（使用进程计数控制并发数）
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
  
  # 过滤空 IP，创建有效 IP 数组
  local -a valid_ips=()
  for ip_dns in "${ips_ref[@]}"; do
    if [[ -n "$ip_dns" && "$ip_dns" != "" ]]; then
      local ip
      ip=$(echo "$ip_dns" | cut -d'|' -f1)
      if [[ -n "$ip" && "$ip" != "" ]]; then
        valid_ips+=("$ip_dns")
      fi
    fi
  done

  # 如果没有有效 IP，直接返回
  if [[ ${#valid_ips[@]} -eq 0 ]]; then
    return 0
  fi
  
  # 为每个有效 IP 创建临时文件
  for ip_dns in "${valid_ips[@]}"; do
    local ip
    ip=$(echo "$ip_dns" | cut -d'|' -f1)
    local tmp_file
    tmp_file=$(mktemp "${TMP_DIR}/test-${ip}.XXXXXX") || continue
    tmp_files+=("$tmp_file")
  done
  
  # 并发检测：控制同时运行的进程数不超过 CONCURRENT_THREADS
  while [[ $index -lt ${#valid_ips[@]} ]] || [[ $running -gt 0 ]]; do
    # 启动新进程（如果还有 IP 未检测且并发数未达到上限）
    while [[ $running -lt $CONCURRENT_THREADS ]] && [[ $index -lt ${#valid_ips[@]} ]]; do
      local ip_dns="${valid_ips[$index]}"
      local tmp_file="${tmp_files[$index]}"
      local ip dns
      IFS='|' read -r ip dns <<< "$ip_dns"
      
      # 后台并发检测
      (
        local test_result
        test_result=$(test_ip_connectivity "$ip" "$domain")
        if [[ -n "$test_result" ]]; then
          echo "${ip}|${dns}|${test_result}" > "$tmp_file"
        fi
      ) &
      pids+=($!)
      ((running++))
      ((index++))
    done
    
    # 等待至少一个进程完成
    if [[ $running -gt 0 ]]; then
      local wait_pid
      for wait_pid in "${pids[@]}"; do
        if wait "$wait_pid" 2>/dev/null; then
          ((running--))
          # 从 pids 数组中移除已完成的进程
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
  
  # 等待所有剩余进程完成
  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
  
  # 收集检测结果（验证 IP 不为空）
  for tmp_file in "${tmp_files[@]}"; do
    if [[ -f "$tmp_file" ]]; then
      while IFS= read -r line; do
        if [[ -n "$line" ]]; then
          local ip dns
          IFS='|' read -r ip dns <<< "$line"
          # 确保 IP 不为空才添加到结果中
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

# 计算 IP 评分（功能分 - 延迟惩罚）
# 参数：$1 - https结果（1/0），$2 - tcp结果（1/0），$3 - ping结果（1/0），$4 - ping延迟（毫秒，可为空）
# 返回：评分（整数，越高越好）
calculate_ip_score() {
  local https_result="$1"
  local tcp_result="$2"
  local ping_result="$3"
  local ping_delay="$4"
  
  # 功能分：HTTPS +100，TCP +50，Ping +25
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
  
  # 延迟惩罚：有延迟则用 ping_ms/10，否则固定15
  local latency_penalty=15
  if [[ -n "$ping_delay" ]] && [[ "$ping_delay" =~ ^[0-9]+$ ]]; then
    latency_penalty=$((ping_delay / 10))
  fi
  
  # 最终分数 = 功能分 - 延迟惩罚
  local score=$((function_score - latency_penalty))
  echo "$score"
}

# 确定检测方法名称（优先级：https > tcp > ping）
# 参数：$1 - https结果（1/0），$2 - tcp结果（1/0），$3 - ping结果（1/0）
# 返回：检测方法名称
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

# 选择最优 IP 地址（基于评分系统）
# 参数：$1 - 检测结果数组引用（格式：IP|DNS|https|tcp|ping|延迟），$2 - 域名（可选，用于日志）
# 返回：选中的 IP 地址列表（格式：IP|DNS|检测方法，每行一个）
select_best_ips() {
  local -n results_ref="$1"
  local domain="${2:-}"
  local -a ipv4_results=()
  local -a ipv6_results=()
  local -a selected_ips=()
  
  # 分离 IPv4 和 IPv6 结果
  for result in "${results_ref[@]}"; do
    [[ -z "$result" ]] && continue
    local ip dns https_result tcp_result ping_result ping_delay
    IFS='|' read -r ip dns https_result tcp_result ping_result ping_delay <<< "$result"
    local ip_type
    ip_type=$(get_ip_type "$ip")
    
    if [[ "$ip_type" == "ipv4" ]]; then
      ipv4_results+=("$result")
    elif [[ "$ip_type" == "ipv6" ]]; then
      ipv6_results+=("$result")
    fi
  done
  
  # 确定协议选择策略
  local select_ipv4=0
  local select_ipv6=0
  
  if [[ "$IP_MODE" == "True" ]]; then
    if [[ ${#ipv4_results[@]} -gt 0 ]]; then
      select_ipv4=1
    fi
    if [[ ${#ipv6_results[@]} -gt 0 ]]; then
      select_ipv6=1
    fi
  elif [[ "$IP_MODE" == "IPv4" ]]; then
    if [[ ${#ipv4_results[@]} -gt 0 ]]; then
      select_ipv4=1
    elif [[ ${#ipv6_results[@]} -gt 0 ]]; then
      select_ipv6=1
    fi
  elif [[ "$IP_MODE" == "IPv6" ]]; then
    if [[ ${#ipv6_results[@]} -gt 0 ]]; then
      select_ipv6=1
    elif [[ ${#ipv4_results[@]} -gt 0 ]]; then
      select_ipv4=1
    fi
  else
    if [[ ${#ipv4_results[@]} -gt 0 ]]; then
      select_ipv4=1
    fi
    if [[ ${#ipv6_results[@]} -gt 0 ]]; then
      select_ipv6=1
    fi
  fi
  
  # 选择 IPv4 IP（按评分排序）
  if [[ $select_ipv4 -eq 1 && ${#ipv4_results[@]} -gt 0 ]]; then
    local -a sorted_ipv4
    IFS=$'\n' read -d '' -r -a sorted_ipv4 < <(
      for result in "${ipv4_results[@]}"; do
        local ip dns https_result tcp_result ping_result ping_delay
        IFS='|' read -r ip dns https_result tcp_result ping_result ping_delay <<< "$result"
        local score
        score=$(calculate_ip_score "$https_result" "$tcp_result" "$ping_result" "$ping_delay")
        # 输出格式：评分|原始结果（用于排序后提取）
        echo "${score}|${result}"
      done | sort -t'|' -k1,1rn | cut -d'|' -f2-
    ) || true
    
    local count=0
    for result in "${sorted_ipv4[@]}"; do
      [[ -z "$result" ]] && continue
      if [[ $count -ge $MAX_IPS_PER_PROTOCOL ]]; then
        break
      fi
      local ip dns https_result tcp_result ping_result ping_delay
      IFS='|' read -r ip dns https_result tcp_result ping_result ping_delay <<< "$result"
      if [[ -n "$ip" && "$ip" != "" ]]; then
        local method
        method=$(get_detection_method "$https_result" "$tcp_result" "$ping_result")
        # 输出格式：IP|DNS|检测方法
        selected_ips+=("${ip}|${dns}|${method}")
        ((count++))
        
        if [[ $CRON_MODE -eq 0 && -n "$domain" ]]; then
          echo "  选中 IPv4: $ip (检测方法: $method, 延迟: ${ping_delay:-未知}ms) - $domain" >&2
        fi
      fi
    done
  fi
  
  # 选择 IPv6 IP（按评分排序）
  if [[ $select_ipv6 -eq 1 && ${#ipv6_results[@]} -gt 0 ]]; then
    local -a sorted_ipv6
    IFS=$'\n' read -d '' -r -a sorted_ipv6 < <(
      for result in "${ipv6_results[@]}"; do
        local ip dns https_result tcp_result ping_result ping_delay
        IFS='|' read -r ip dns https_result tcp_result ping_result ping_delay <<< "$result"
        local score
        score=$(calculate_ip_score "$https_result" "$tcp_result" "$ping_result" "$ping_delay")
        echo "${score}|${result}"
      done | sort -t'|' -k1,1rn | cut -d'|' -f2-
    ) || true
    
    local count=0
    for result in "${sorted_ipv6[@]}"; do
      [[ -z "$result" ]] && continue
      if [[ $count -ge $MAX_IPS_PER_PROTOCOL ]]; then
        break
      fi
      local ip dns https_result tcp_result ping_result ping_delay
      IFS='|' read -r ip dns https_result tcp_result ping_result ping_delay <<< "$result"
      if [[ -n "$ip" && "$ip" != "" ]]; then
        local method
        method=$(get_detection_method "$https_result" "$tcp_result" "$ping_result")
        selected_ips+=("${ip}|${dns}|${method}")
        ((count++))
        
        if [[ $CRON_MODE -eq 0 && -n "$domain" ]]; then
          echo "  选中 IPv6: $ip (检测方法: $method, 延迟: ${ping_delay:-未知}ms) - $domain" >&2
        fi
      fi
    done
  fi
  
  printf '%s\n' "${selected_ips[@]}"
}

# 解析域名并选择最优 IP 地址
# 参数：$1 - 域名（格式：域名|组名），$2 - 输出文件路径
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
  
  # 并行从多个 DNS 服务器解析
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
  
  # 并发检测 IP 连通性
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
  
  # 选择最优 IP
  local -a selected_ips
  mapfile -t selected_ips < <(select_best_ips test_results "$domain")
  
  # 过滤空元素，确保统计与写入一致
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
  
  # 写入 hosts 文件（格式：IP 域名  # 检测方法 | DNS: DNS服务器名称）
  if [[ ${#selected_ips[@]} -eq 0 ]]; then
    # 既然有可用IP但未选中，使用首个可用结果兜底
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

export -f resolve_domain get_ip_type test_https_connectivity test_tcp_connectivity test_ping_connectivity test_ip_connectivity

# 清理 hosts 文件中的旧内容
cleanup_old_hosts() {
  if grep -q "$START_MARK" "${HOSTS_FILE}" && grep -q "$END_MARK" "${HOSTS_FILE}"; then
    sed -i "/$START_MARK/,/$END_MARK/d" "${HOSTS_FILE}"
  fi
  
  local temp_hosts
  temp_hosts=$(mktemp "${TMP_DIR}/hosts-cleanup.XXXXXX") || {
    echo "无法创建临时文件" >&2
    return 1
  }
  tac "${HOSTS_FILE}" 2>/dev/null | sed '/^[[:space:]]*$/d' | tac > "${temp_hosts}" || cat "${HOSTS_FILE}" > "${temp_hosts}"
  mv "${temp_hosts}" "${HOSTS_FILE}"
}

# 生成 hosts 文件头部标记
generate_hosts_header() {
  local output_file="$1"
  local need_blank_line="$2"
  
  {
    if [[ $need_blank_line -eq 1 ]]; then
      echo ""
    fi
    echo "$START_MARK"
    echo "# 项目地址:https://github.com/kekylin/debnas"
    echo "# 更新时间: $(date '+%Y年%m月%d日 %H:%M:%S')"
    echo ""
  } > "${output_file}"
}

# 生成 hosts 文件尾部标记
generate_hosts_footer() {
  local output_file="$1"
  
  {
    echo ""
    echo "$END_MARK"
  } >> "${output_file}"
}

# 解析所有域名并生成 hosts 内容（按域名组分类）
process_all_domains() {
  local hosts_content="$1"
  
  if [[ $CRON_MODE -eq 0 ]]; then
    echo "开始解析 ${#DOMAINS[@]} 个域名..." >&2
  fi
  
  TOTAL_DOMAINS=0
  SUCCESS_DOMAINS=0
  UNRESOLVED_DOMAINS=0
  UNREACHABLE_DOMAINS=0
  
  # 定义组输出顺序
  local -a GROUP_ORDER=("GitHub" "TMDB" "OpenSubtitles" "Fanart")
  declare -A group_files
  
  # 按域名组分类处理
  for domain_group in "${DOMAINS[@]}"; do
    local domain group
    IFS='|' read -r domain group <<< "$domain_group"
    
    # 初始化组级临时文件
    if [[ -z "${group_files[$group]:-}" ]]; then
      local group_file
      group_file=$(mktemp "${TMP_DIR}/group-${group}.XXXXXX") || continue
      group_files["$group"]="$group_file"
    fi
    
    local group_file="${group_files[$group]}"
    resolve_domain "$domain_group" "${group_file}" || true
    ((TOTAL_DOMAINS++))
    case "$RESOLVE_RESULT" in
      success) ((SUCCESS_DOMAINS++)) ;;
      unresolved) ((UNRESOLVED_DOMAINS++)) ;;
      unreachable) ((UNREACHABLE_DOMAINS++)) ;;
    esac
  done
  
  local first_group_written=0

  # 按预设顺序输出各组
  for group in "${GROUP_ORDER[@]}"; do
    local group_file="${group_files[$group]:-}"
    if [[ -n "$group_file" ]] && [[ -f "$group_file" ]] && [[ -s "$group_file" ]]; then
      if [[ $first_group_written -eq 1 ]]; then
        echo "" >> "${hosts_content}"
      fi
      echo "# ==== ${group} ====" >> "${hosts_content}"
      cat "${group_file}" >> "${hosts_content}"
      rm -f "${group_file}"
      first_group_written=1
    fi
  done
  
  # 输出未列入预设顺序的其余组
  for group in "${!group_files[@]}"; do
    local found=0
    for ordered_group in "${GROUP_ORDER[@]}"; do
      if [[ "$group" == "$ordered_group" ]]; then
        found=1
        break
      fi
    done
    
    if [[ $found -eq 0 ]]; then
      local group_file="${group_files[$group]}"
      if [[ -f "$group_file" ]] && [[ -s "$group_file" ]]; then
        if [[ $first_group_written -eq 1 ]]; then
          echo "" >> "${hosts_content}"
        fi
        echo "# ==== ${group} ====" >> "${hosts_content}"
        cat "${group_file}" >> "${hosts_content}"
        rm -f "${group_file}"
        first_group_written=1
      fi
    fi
  done

  if [[ $CRON_MODE -eq 0 ]]; then
    echo "所有域名解析任务完成" >&2
  fi
}

# 更新 /etc/hosts 文件
# 返回：0成功，非0失败
update_hosts() {
  if [[ $CRON_MODE -eq 0 ]]; then
    log_action "开始更新 /etc/hosts 文件..."
  fi
  
  export TMP_DIR START_MARK END_MARK HOSTS_FILE
  
  cleanup_old_hosts
  
  local last_line
  last_line=$(tail -n 1 "${HOSTS_FILE}" 2>/dev/null | sed 's/[[:space:]]*$//' || echo "")
  local need_blank_line=0
  if [[ -n "$last_line" ]]; then
    need_blank_line=1
  fi
  
  local hosts_content
  hosts_content=$(mktemp "${TMP_DIR}/hosts-content.XXXXXX") || {
    if [[ $CRON_MODE -eq 0 ]]; then
      log_error "无法创建临时文件"
    else
      echo "无法创建临时文件" >&2
    fi
    return 1
  }
  generate_hosts_header "${hosts_content}" "$need_blank_line"
  
  process_all_domains "${hosts_content}"
  
  generate_hosts_footer "${hosts_content}"
  cat "${hosts_content}" >> "${HOSTS_FILE}"
  rm -f "${hosts_content}"
  
  if [[ $CRON_MODE -eq 0 ]]; then
    log_success "/etc/hosts 文件已更新完成。"
    log_info "域名统计：总计 ${TOTAL_DOMAINS}，成功 ${SUCCESS_DOMAINS}，解析失败 ${UNRESOLVED_DOMAINS}，不可达 ${UNREACHABLE_DOMAINS}"
  else
    printf '域名统计：总计 %d，成功 %d，解析失败 %d，不可达 %d\n' \
      "$TOTAL_DOMAINS" "$SUCCESS_DOMAINS" "$UNRESOLVED_DOMAINS" "$UNREACHABLE_DOMAINS" >&2
  fi
  
  return 0
}

# 检查并安装必需的系统依赖
check_required_dependencies() {
  local required_cmds=("dig" "ping" "curl" "awk" "sed" "grep")
  
  if ! check_dependencies "${required_cmds[@]}"; then
    log_warning "检测到部分依赖缺失，尝试自动安装..."
    if ! install_missing_dependencies "${required_cmds[@]}"; then
      log_error "依赖安装失败，请手动安装：dnsutils (dig)、iputils-ping (ping)、curl"
      exit "${ERROR_DEPENDENCY}"
    fi
  fi
}

# 创建定时任务
# 返回：0成功，非0失败
create_cron_job() {
  local script_path
  local cron_job

  if [[ -n "${USER:-}" ]]; then
    local user_home
    user_home=$(getent passwd "$USER" 2>/dev/null | cut -d: -f6 || echo "$HOME")
    script_path="${user_home}/.debnas_hosts_update.sh"
  else
    script_path="${HOME}/.debnas_hosts_update.sh"
  fi

  if crontab -l 2>/dev/null | grep -q "# DebNAS Hosts Update"; then
    log_action "定时任务已存在，正在删除旧任务..."
    crontab -l 2>/dev/null | grep -v "# DebNAS Hosts Update" | crontab - || true
  fi

  if ! update_hosts; then
    log_fail "取消创建定时任务。"
    return 1
  fi

  cp "$0" "$script_path"
  chmod +x "$script_path"

  cron_job="0 0,6,12,18 * * * /bin/bash $script_path auto_update_hosts # DebNAS Hosts Update"
  (crontab -l 2>/dev/null; echo "$cron_job") | crontab -

  log_success "定时任务已创建，每天0点、6点、12点和18点自动执行。"
  log_success "hosts 自动更新相关配置已全部完成。"
  return 0
}

# 删除定时任务
remove_cron_job() {
  if crontab -l 2>/dev/null | grep -q "# DebNAS Hosts Update"; then
    crontab -l 2>/dev/null | grep -v "# DebNAS Hosts Update" | crontab - || true
    log_success "定时任务已删除。"
  else
    log_info "未找到定时任务。"
  fi
}

# 查询定时任务
list_cron_jobs() {
  log_info "定时任务如下："
  if crontab -l 2>/dev/null | grep -q "# DebNAS Hosts Update"; then
    crontab -l 2>/dev/null | grep "# DebNAS Hosts Update"
  else
    log_info "当前没有 hosts 更新定时任务。"
  fi
}

# 交互式菜单
menu() {
  while true; do
    print_separator "-"
    print_menu_item "1" "单次更新"
    print_menu_item "2" "定时更新"
    print_menu_item "3" "删除定时任务"
    print_menu_item "4" "查询定时任务"
    print_menu_item "0" "返回" "true"
    print_separator "-"
    print_prompt "请选择编号: "
    read -r choice

    case "$choice" in
      1)
        log_action "执行单次更新"
        update_hosts
        ;;
      2)
        log_action "创建定时更新任务"
        create_cron_job
        ;;
      3)
        log_action "删除定时任务"
        remove_cron_job
        ;;
      4)
        list_cron_jobs
        ;;
      0)
        return 0
        ;;
      *)
        log_fail "无效选择，请重新输入。"
        ;;
    esac
  done
}

# 主函数
main() {
  if [[ $CRON_MODE -eq 0 ]]; then
    setup_temp_environment
    check_required_dependencies
    menu
  else
    setup_temp_environment
    update_hosts
    exit 0
  fi
}

main "$@"
