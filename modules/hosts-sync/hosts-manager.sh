#!/bin/bash
# hosts-sync: /etc/hosts 读写模块
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
# shellcheck disable=SC2034  # 由 connectivity.sh 的 test_ips_concurrently 使用
readonly CONCURRENT_THREADS=8

# 域名配置文件路径
readonly DOMAINS_CONF_FILE="/etc/debnas/conf.d/hosts-sync-domains.conf"

# 初始化域名配置文件（首次运行时创建，后续不覆盖）
init_domains_config() {
  if [[ -f "${DOMAINS_CONF_FILE}" ]]; then
    return 0  # 已存在，保留用户修改
  fi
  local conf_dir
  conf_dir="$(dirname "${DOMAINS_CONF_FILE}")"
  if [[ ! -d "${conf_dir}" ]]; then
    mkdir -p "${conf_dir}" 2>/dev/null || return 1
  fi
  {
    echo "# DebNAS Hosts-Sync 域名配置文件"
    echo "# 格式：域名|组名（每行一个，以 # 开头的行为注释）"
    echo "# 修改后下次解析生效，删除此文件可恢复默认列表"
    echo "#"
    printf '%s\n' "${_DEFAULT_DOMAINS[@]}"
  } > "${DOMAINS_CONF_FILE}"
  log_info "已创建域名配置文件：${DOMAINS_CONF_FILE}"
}

# 加载域名列表（优先读取配置文件，不存在则使用内置默认值）
load_domains() {
  if [[ -f "${DOMAINS_CONF_FILE}" ]] && [[ -s "${DOMAINS_CONF_FILE}" ]]; then
    # 从配置文件读取（跳过空行和注释行）
    local -a loaded=()
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
      # 去首尾空白（bash 内建，不再每行起 printf|sed）
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      [[ -n "$line" ]] && loaded+=("$line")
    done < "${DOMAINS_CONF_FILE}"
    if [[ ${#loaded[@]} -gt 0 ]]; then
      printf '%s\n' "${loaded[@]}"
      return 0
    fi
  fi
  # 回退：内置默认域名列表
  printf '%s\n' "${_DEFAULT_DOMAINS[@]}"
}

# 内置默认域名（格式：域名|组名）
_DEFAULT_DOMAINS=(
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


# 按评分降序取前 MAX_IPS_PER_PROTOCOL 个结果
# 参数：$1 - 协议标签（IPv4/IPv6，日志用），$2 - 域名（日志用，可空），其余 - 检测结果（IP|DNS|https|tcp|ping|延迟）
# 输出：IP|DNS|检测方法（每行一个）
_select_top_results() {
  local label="$1" domain="$2"
  shift 2
  local result ip dns https_result tcp_result ping_result ping_delay method count=0
  local -a sorted=()
  mapfile -t sorted < <(
    for result in "$@"; do
      IFS='|' read -r ip dns https_result tcp_result ping_result ping_delay <<< "$result"
      echo "$(calculate_ip_score "$https_result" "$tcp_result" "$ping_result" "$ping_delay")|${result}"
    done | sort -t'|' -k1,1rn | sed 's/^[^|]*|//'
  )
  for result in "${sorted[@]}"; do
    [[ -z "$result" ]] && continue
    (( count >= MAX_IPS_PER_PROTOCOL )) && break
    IFS='|' read -r ip dns https_result tcp_result ping_result ping_delay <<< "$result"
    [[ -n "$ip" ]] || continue
    method=$(get_detection_method "$https_result" "$tcp_result" "$ping_result")
    printf '%s\n' "${ip}|${dns}|${method}"
    ((count++)) || true
    if [[ $CRON_MODE -eq 0 && -n "$domain" ]]; then
      echo "  选中 ${label}: $ip (检测方法: $method, 延迟: ${ping_delay:-未知}ms) - $domain" >&2
    fi
  done
}

# 选择最优 IP 地址（按 IP_MODE 决定取哪个协议族，族内按评分取前 MAX_IPS_PER_PROTOCOL 个）
# 参数：$1 - 检测结果数组引用（格式：IP|DNS|https|tcp|ping|延迟），$2 - 域名（可选，用于日志）
# 返回：选中的 IP 地址列表（格式：IP|DNS|检测方法，每行一个）
select_best_ips() {
  local -n results_ref="$1"
  local domain="${2:-}"
  local -a ipv4_results=() ipv6_results=()
  local result select_ipv4=0 select_ipv6=0

  for result in "${results_ref[@]}"; do
    [[ -z "$result" ]] && continue
    case "$(get_ip_type "${result%%|*}")" in
      ipv4) ipv4_results+=("$result") ;;
      ipv6) ipv6_results+=("$result") ;;
    esac
  done

  local n4=${#ipv4_results[@]} n6=${#ipv6_results[@]}
  case "$IP_MODE" in
    IPv4) if (( n4 > 0 )); then select_ipv4=1; elif (( n6 > 0 )); then select_ipv6=1; fi ;;
    IPv6) if (( n6 > 0 )); then select_ipv6=1; elif (( n4 > 0 )); then select_ipv4=1; fi ;;
    *)    (( n4 > 0 )) && select_ipv4=1; (( n6 > 0 )) && select_ipv6=1 ;;
  esac
  if (( select_ipv4 )); then _select_top_results IPv4 "$domain" "${ipv4_results[@]}"; fi
  if (( select_ipv6 )); then _select_top_results IPv6 "$domain" "${ipv6_results[@]}"; fi
  return 0
}

# 输出移除 DebNAS 区块并去掉末尾空行后的 hosts 内容（不修改文件本身）
# 仅删除成对的 START/END 区块；缺少 END 的残缺区块原样保留，避免误删用户条目
# 用户 hosts 中间的空行保持不变
render_hosts_without_block() {
  awk -v start="$START_MARK" -v end="$END_MARK" '
    function emit(line) {
      if (line ~ /^[[:space:]]*$/) { blanks = blanks line "\n"; return }
      printf "%s%s\n", blanks, line; blanks = ""
    }
    !inblock && $0 == start { inblock = 1; held = $0 "\n"; next }
    inblock {
      if ($0 == end) { inblock = 0; held = ""; next }
      held = held $0 "\n"; next
    }
    { emit($0) }
    END {
      if (inblock) { n = split(held, arr, "\n"); for (i = 1; i < n; i++) emit(arr[i]) }
    }
  ' "${HOSTS_FILE}"
}

# 将内容写回 /etc/hosts：原地覆盖，保留原文件的权限/属主/inode（兼容 bind mount）
# 参数：$1 - 包含完整新内容的文件
write_hosts_file() {
  local src="$1"
  [[ -s "$src" ]] || return 1
  cat "$src" > "${HOSTS_FILE}"
}

# 从 /etc/hosts 移除 DebNAS 区块（禁用同步时调用）
remove_hosts_block() {
  [[ -f "${HOSTS_FILE}" ]] || return 0
  if ! grep -qxF "$START_MARK" "${HOSTS_FILE}"; then
    return 0
  fi
  local temp_hosts
  temp_hosts=$(create_temp_file "hosts-cleanup") || {
    echo "无法创建临时文件" >&2
    return 1
  }
  render_hosts_without_block > "${temp_hosts}" || {
    rm -f "${temp_hosts}"
    return 1
  }
  write_hosts_file "${temp_hosts}" || {
    rm -f "${temp_hosts}"
    return 1
  }
  rm -f "${temp_hosts}"
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
  local -a DOMAINS=()
  local domain_count

  # 从配置文件或内置默认加载域名列表
  mapfile -t DOMAINS < <(load_domains)
  domain_count=${#DOMAINS[@]}

  if [[ $CRON_MODE -eq 0 ]]; then
    echo "开始解析 ${domain_count} 个域名..." >&2
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
      group_file=$(create_temp_file "group-${group}") || continue
      group_files["$group"]="$group_file"
    fi
    
    local group_file="${group_files[$group]}"
    resolve_domain "$domain_group" "${group_file}" || true
    ((TOTAL_DOMAINS++)) || true
    case "$RESOLVE_RESULT" in
      success) ((SUCCESS_DOMAINS++)) || true ;;
      unresolved) ((UNRESOLVED_DOMAINS++)) || true ;;
      unreachable) ((UNREACHABLE_DOMAINS++)) || true ;;
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
    echo "解析完成" >&2
  fi
}

# 更新 /etc/hosts 文件
# 先完成全部解析，再一次性写回；无任何成功解析时保留原 hosts 不动
# 返回：0 成功，非 0 失败
update_hosts() {
  if [[ $CRON_MODE -eq 0 ]]; then
    log_info "更新 Hosts..."
  fi
  
  export TMP_DIR START_MARK END_MARK HOSTS_FILE
  
  local block_content
  block_content=$(create_temp_file "hosts-block") || {
    if [[ $CRON_MODE -eq 0 ]]; then
      log_error "无法创建临时文件"
    else
      echo "无法创建临时文件" >&2
    fi
    return 1
  }
  process_all_domains "${block_content}"

  if [[ $SUCCESS_DOMAINS -eq 0 ]]; then
    rm -f "${block_content}"
    if [[ $CRON_MODE -eq 0 ]]; then
      log_warning "没有任何域名解析成功，保留现有 Hosts 不变"
    else
      echo "没有任何域名解析成功，保留现有 Hosts 不变" >&2
    fi
    return 1
  fi

  local hosts_content
  hosts_content=$(create_temp_file "hosts-content") || {
    rm -f "${block_content}"
    echo "无法创建临时文件" >&2
    return 1
  }
  render_hosts_without_block > "${hosts_content}"

  local need_blank_line=0
  if [[ -s "${hosts_content}" ]]; then
    need_blank_line=1
  fi
  local block_header
  block_header=$(create_temp_file "hosts-header") || {
    rm -f "${block_content}" "${hosts_content}"
    echo "无法创建临时文件" >&2
    return 1
  }
  generate_hosts_header "${block_header}" "$need_blank_line"
  cat "${block_header}" "${block_content}" >> "${hosts_content}"
  generate_hosts_footer "${hosts_content}"
  rm -f "${block_header}" "${block_content}"

  if ! write_hosts_file "${hosts_content}"; then
    rm -f "${hosts_content}"
    echo "写入 ${HOSTS_FILE} 失败" >&2
    return 1
  fi
  rm -f "${hosts_content}"
  
  if [[ $CRON_MODE -eq 0 ]]; then
    log_success "Hosts 已更新"
    log_info "域名统计：总计 ${TOTAL_DOMAINS}，成功 ${SUCCESS_DOMAINS}，解析失败 ${UNRESOLVED_DOMAINS}，不可达 ${UNREACHABLE_DOMAINS}"
  else
    printf '域名统计：总计 %d，成功 %d，解析失败 %d，不可达 %d\n' \
      "$TOTAL_DOMAINS" "$SUCCESS_DOMAINS" "$UNRESOLVED_DOMAINS" "$UNREACHABLE_DOMAINS" >&2
  fi
  
  return 0
}

