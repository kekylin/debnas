#!/bin/bash
# auto-update-hosts: /etc/hosts 读写模块
set -euo pipefail
IFS=$'\n\t'
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

# 协议模式固定为 IPv4
readonly IP_MODE="IPv4"

# 每种协议最多保留 1 个 IP
readonly MAX_IPS_PER_PROTOCOL="1"

TOTAL_DOMAINS=0
SUCCESS_DOMAINS=0
UNRESOLVED_DOMAINS=0
UNREACHABLE_DOMAINS=0
RESOLVE_RESULT="unknown"


select_best_ips() {
  local -n results_ref="$1"
  local domain="${2:-}"
  local -a ipv4_results=()
  local -a ipv6_results=()
  local -a selected_ips=()
  
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
  
  if [[ $select_ipv4 -eq 1 && ${#ipv4_results[@]} -gt 0 ]]; then
    local -a sorted_ipv4
    IFS=$'\n' read -d '' -r -a sorted_ipv4 < <(
      for result in "${ipv4_results[@]}"; do
        local ip dns https_result tcp_result ping_result ping_delay
        IFS='|' read -r ip dns https_result tcp_result ping_result ping_delay <<< "$result"
        local score
        score=$(calculate_ip_score "$https_result" "$tcp_result" "$ping_result" "$ping_delay")
        echo "${score}|${result}"
      done | sort -t'|' -k1,1rn | sed 's/^[^|]*|//'
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
        selected_ips+=("${ip}|${dns}|${method}")
        ((count++))
        
        if [[ $CRON_MODE -eq 0 && -n "$domain" ]]; then
          echo "  选中 IPv4: $ip (检测方法: $method, 延迟: ${ping_delay:-未知}ms) - $domain" >&2
        fi
      fi
    done
  fi
  
  if [[ $select_ipv6 -eq 1 && ${#ipv6_results[@]} -gt 0 ]]; then
    local -a sorted_ipv6
    IFS=$'\n' read -d '' -r -a sorted_ipv6 < <(
      for result in "${ipv6_results[@]}"; do
        local ip dns https_result tcp_result ping_result ping_delay
        IFS='|' read -r ip dns https_result tcp_result ping_result ping_delay <<< "$result"
        local score
        score=$(calculate_ip_score "$https_result" "$tcp_result" "$ping_result" "$ping_delay")
        echo "${score}|${result}"
      done | sort -t'|' -k1,1rn | sed 's/^[^|]*|//'
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

generate_hosts_footer() {
  local output_file="$1"
  
  {
    echo ""
    echo "$END_MARK"
  } >> "${output_file}"
}

process_all_domains() {
  local hosts_content="$1"
  
  if [[ $CRON_MODE -eq 0 ]]; then
    echo "开始解析 ${#DOMAINS[@]} 个域名..." >&2
  fi
  
  TOTAL_DOMAINS=0
  SUCCESS_DOMAINS=0
  UNRESOLVED_DOMAINS=0
  UNREACHABLE_DOMAINS=0
  
  local -a GROUP_ORDER=("GitHub" "TMDB" "OpenSubtitles" "Fanart")
  declare -A group_files
  
  for domain_group in "${DOMAINS[@]}"; do
    local domain group
    IFS='|' read -r domain group <<< "$domain_group"
    
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
# 返回：0 成功，非 0 失败
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

