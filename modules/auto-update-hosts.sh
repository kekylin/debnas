#!/bin/bash
# 功能：自动更新 /etc/hosts 文件，通过多 DNS 解析和延迟测试选择最优 IP 地址

set -euo pipefail
IFS=$'\n\t'

# 判断运行模式：定时模式（auto_update_hosts）或交互模式
CRON_MODE=0
if [[ "${1:-}" == "auto_update_hosts" ]]; then
  CRON_MODE=1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 根据运行模式加载不同的库
if [[ $CRON_MODE -eq 1 ]]; then
  :
else
  # 交互模式：加载所有公共库
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
readonly DNS_SERVERS=("223.5.5.5" "114.114.114.114" "180.76.76.76")

DOMAINS=(
  # GitHub Domains
  "github.githubassets.com"
  "central.github.com"
  "desktop.githubusercontent.com"
  "camo.githubusercontent.com"
  "github.map.fastly.net"
  "github.global.ssl.fastly.net"
  "gist.github.com"
  "github.io"
  "github.com"
  "api.github.com"
  "raw.githubusercontent.com"
  "user-images.githubusercontent.com"
  "favicons.githubusercontent.com"
  "avatars5.githubusercontent.com"
  "avatars4.githubusercontent.com"
  "avatars3.githubusercontent.com"
  "avatars2.githubusercontent.com"
  "avatars1.githubusercontent.com"
  "avatars0.githubusercontent.com"
  "avatars.githubusercontent.com"
  "codeload.github.com"
  "github-cloud.s3.amazonaws.com"
  "github-com.s3.amazonaws.com"
  "github-production-release-asset-2e65be.s3.amazonaws.com"
  "github-production-user-asset-6210df.s3.amazonaws.com"
  "github-production-repository-file-5c1aeb.s3.amazonaws.com"
  "githubstatus.com"
  "github.community"
  "media.githubusercontent.com"
  "objects.githubusercontent.com"
  "raw.github.com"
  "copilot-proxy.githubusercontent.com"

  # tmdb Domains
  "themoviedb.org"
  "www.themoviedb.org"
  "api.themoviedb.org"
  "tmdb.org"
  "api.tmdb.org"
  "image.tmdb.org"
  "opensubtitles.org"
  "www.opensubtitles.org"
  "api.opensubtitles.org"
  "assets.fanart.tv"
)

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

# 从多个 DNS 服务器解析域名获取 IP 地址
# 参数：$1 - 域名，$2 - DNS 服务器数组引用
# 返回：IP 地址数组（每行一个）
resolve_domain_ips() {
  local domain="$1"
  local -n dns_servers_ref="$2"
  local -a all_ips=()
  
  for dns in "${dns_servers_ref[@]}"; do
    local ips
    ips=$(timeout 5 dig +short "@$dns" A "$domain" 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' || true)
    for ip in $ips; do
      if [[ -n "$ip" ]]; then
        all_ips+=("$ip")
      fi
    done
  done
  
  if [[ ${#all_ips[@]} -gt 0 ]]; then
    local -a unique_ips
    IFS=$'\n' read -d '' -r -a unique_ips < <(printf '%s\n' "${all_ips[@]}" | sort -u) || true
    all_ips=("${unique_ips[@]}")
  fi
  
  printf '%s\n' "${all_ips[@]}"
}

# 测试 IP 地址延迟并返回最优 IP
# 参数：$1 - IP 地址数组引用，$2 - 域名（可选，用于日志）
# 返回：最优 IP 和延迟（格式：IP|延迟）
select_best_ip() {
  local -n ips_ref="$1"
  local domain="${2:-}"
  declare -A ip_delays
  local best_ip=""
  local best_delay=9999
  
  for ip in "${ips_ref[@]}"; do
    local delay="9999"
    local ping_output
    ping_output=$(timeout 5 ping -c 1 -W 2 "$ip" 2>&1 || echo "")
    local ping_status=$?
    if [[ $ping_status -eq 0 && -n "$ping_output" ]]; then
      delay=$(echo "$ping_output" | grep -oP 'time=\K[0-9.]+' | head -1)
      if [[ -z "$delay" ]]; then
        delay=$(echo "$ping_output" | awk -F'=' '/time=/{print $NF}' | awk '{print $1}')
      fi
      delay="${delay:-9999}"
    fi
    ip_delays["$ip"]="$delay"
    
    if [[ $CRON_MODE -eq 0 && -n "$domain" ]]; then
      echo "    IP $ip 延迟: ${delay}ms" >&2
    fi
  done
  
  for ip in "${!ip_delays[@]}"; do
    local delay="${ip_delays[$ip]}"
    if (( ${delay%.*} < ${best_delay%.*} )); then
      best_ip="$ip"
      best_delay="$delay"
    fi
  done
  
  best_delay="${best_delay:-9999}"
  printf '%s|%s\n' "${best_ip}" "${best_delay}"
}

# 解析域名并选择延迟最低的 IP 地址
# 参数：$1 - 域名，$2 - 输出文件路径
resolve_domain() {
  set +e
  
  local domain="$1"
  local output_file="$2"
  
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
    return
  fi
  
  if [[ $CRON_MODE -eq 0 ]]; then
    echo "  获取到 ${#all_ips[@]} 个候选 IP，开始测试延迟: $domain" >&2
  fi
  
  local result
  result=$(select_best_ip all_ips "$domain")
  local best_ip best_delay
  IFS='|' read -r best_ip best_delay <<< "$result"
  
  if [[ $CRON_MODE -eq 0 ]]; then
    echo "  延迟测试完成，共测试 ${#all_ips[@]} 个 IP" >&2
    if [[ -n "$best_ip" && "$best_delay" != "9999" ]]; then
      echo "  最优 IP: $best_ip (延迟 ${best_delay}ms) - $domain" >&2
    else
      echo "  所有 IP 均不可达: $domain" >&2
    fi
  fi
  
  if [[ -n "$best_ip" && "$best_delay" != "9999" ]]; then
    printf "%-16s%s\n" "$best_ip" "$domain" >> "${output_file}"
  else
    echo "# ${domain}  # 无法ping通" >> "${output_file}"
  fi
}

export -f resolve_domain

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
    echo "# 更新时间: $(date '+%Y年%m月%d日 %H:%M:%S')"
    echo ""
  } > "${output_file}"
}

# 生成 hosts 文件尾部标记
generate_hosts_footer() {
  local output_file="$1"
  
  {
    echo ""
    echo "# DebNAS:https://github.com/kekylin/debnas"
    echo "$END_MARK"
  } >> "${output_file}"
}

# 解析所有域名并生成 hosts 内容
process_all_domains() {
  local hosts_content="$1"
  
  if [[ $CRON_MODE -eq 0 ]]; then
    echo "开始解析 ${#DOMAINS[@]} 个域名..." >&2
  fi
  
  for domain in "${DOMAINS[@]}"; do
    local domain_file
    domain_file=$(mktemp "${TMP_DIR}/domain-result.XXXXXX") || {
      if [[ $CRON_MODE -eq 0 ]]; then
        echo "无法创建临时文件" >&2
      fi
      continue
    }
    resolve_domain "$domain" "${domain_file}" || true
    
    if [[ -f "$domain_file" ]]; then
      cat "${domain_file}" >> "${hosts_content}"
      rm -f "${domain_file}"
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
  fi
  
  return 0
}

# 检查并安装必需的系统依赖
check_required_dependencies() {
  local required_cmds=("dig" "ping" "awk" "sed" "grep")
  
  if ! check_dependencies "${required_cmds[@]}"; then
    log_warning "检测到部分依赖缺失，尝试自动安装..."
    if ! install_missing_dependencies "${required_cmds[@]}"; then
      log_error "依赖安装失败，请手动安装：dnsutils (dig)、iputils-ping (ping)"
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
    if ! is_root_user; then
      log_error "脚本需要以 root 权限运行。"
      exit "${ERROR_PERMISSION}"
    fi
    
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
