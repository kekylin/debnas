#!/bin/bash
# @module: threat-ips
# @name: 威胁 IP 封禁
# @category: 安全防护
# @depends: firewall-cmd,ipset,wget,sipcalc
# @depend_modules: firewall
# @interactive: true
# @version: 2.0.0
# @order: 43
# @cron: true
# @cron_schedule: 0 */6 * * *
# 功能：Firewalld-IPThreat 自动化威胁情报更新系统（目录模块入口）

set -euo pipefail
IFS=$'\n\t'

# 设置标准 PATH
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

# ==================== 公共库加载 ====================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/bootstrap.sh"

# ==================== 加载子模块 ====================
source "${MODULE_DIR}/config/ipthreat.conf.default"
source "${MODULE_DIR}/download.sh"
source "${MODULE_DIR}/ipset.sh"
source "${MODULE_DIR}/firewall.sh"
source "${MODULE_DIR}/cron.sh"

# ==================== IP 解析处理模块 ====================
# 清理输入：移除注释和空白字符
normalize_ip_input() {
  local input="$1" clean_ip
  [[ -z "${input}" ]] && return 1
  clean_ip=$(printf "%s" "${input}" | cut -d'#' -f1 | xargs)
  [[ -z "${clean_ip}" ]] && return 1
  printf "%s" "${clean_ip}"
}

process_ipv4_cidr() {
  local cidr="$1" output_file="$2"
  local result prefix mask
  result=$(validate_cidr_ipv4 "${cidr}") || return 1
  read -r prefix mask <<< "${result}"
  printf "%s\n" "${cidr}" >> "${output_file}"
}

process_ipv6_cidr() {
  local cidr="$1" output_file="$2"
  local ipv6_mask
  if [[ ${cidr} =~ ^([0-9a-fA-F:]+)/([0-9]{1,3})$ ]]; then
    ipv6_mask=${BASH_REMATCH[2]}
    if [[ ! "${ipv6_mask}" =~ ^[0-9]+$ ]] \
      || [[ "${ipv6_mask}" -gt 128 ]] || [[ "${ipv6_mask}" -lt 0 ]]; then
      log_warning "无效 IPv6 CIDR 掩码：${cidr}"
      return 1
    fi
    if ! validate_ipv6 "${cidr}"; then
      log_warning "无效 IPv6 CIDR 格式：${cidr}"
      return 1
    fi
    printf "%s\n" "${cidr}" >> "${output_file}"
    return 0
  fi
  return 1
}

expand_ipv4_range() {
  local start_num="$1" end_num="$2"
  awk -v start="${start_num}" -v end="${end_num}" \
    'BEGIN {
      for (i=start; i<=end; i++) {
        a=int(i/16777216)
        b=int((i%16777216)/65536)
        c=int((i%65536)/256)
        d=i%256
        printf "%d.%d.%d.%d\n", a, b, c, d
      }
    }'
}

process_ipv4_range() {
  local range="$1" output_file="$2"
  local start_ip end_ip start_num end_num ip_count a b c d
  if [[ ${range} =~ ^([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})-([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})$ ]]; then
    start_ip=${BASH_REMATCH[1]}
    end_ip=${BASH_REMATCH[2]}
    if ! validate_ipv4 "${start_ip}" || ! validate_ipv4 "${end_ip}"; then
      log_warning "无效 IPv4 范围地址：${range}"
      return 1
    fi
    IFS='.' read -r a b c d <<< "${start_ip}"
    start_num=$(( (a * 16777216) + (b * 65536) + (c * 256) + d ))
    IFS='.' read -r a b c d <<< "${end_ip}"
    end_num=$(( (a * 16777216) + (b * 65536) + (c * 256) + d ))
    if [[ ${start_num} -gt ${end_num} ]]; then
      log_warning "无效 IPv4 范围：${range}（起始地址大于结束地址）"
      return 1
    fi
    ip_count=$((end_num - start_num + 1))
    if [[ ${ip_count} -gt ${MAX_RANGE_SIZE} ]]; then
      log_warning \
        "IPv4 范围过大：${range}（${ip_count} 条，建议使用 CIDR 格式）"
      return 1
    fi
    local awk_output
    if ! awk_output=$(expand_ipv4_range "${start_num}" "${end_num}" 2>&1); then
      log_error "解析 IPv4 范围失败：${range}"
      return 1
    fi
    printf "%s\n" "${awk_output}" >> "${output_file}"
    return 0
  fi
  return 1
}

process_ipv6_range() {
  local range="$1" output_file="$2"
  local start_ip end_ip
  if [[ ${range} =~ ^([0-9a-fA-F:]+)-([0-9a-fA-F:]+)$ ]]; then
    start_ip=${BASH_REMATCH[1]}
    end_ip=${BASH_REMATCH[2]}
    if ! validate_ipv6 "${start_ip}" || ! validate_ipv6 "${end_ip}"; then
      log_warning "无效 IPv6 范围：${range}"
      return 1
    fi
    printf "%s\n%s\n" "${start_ip}" "${end_ip}" >> "${output_file}"
    return 0
  fi
  return 1
}

process_single_ip() {
  local ip="$1" output_file_ipv4="$2" output_file_ipv6="$3"
  local protocol
  protocol=$(validate_ip "${ip}") || return 1
  if [[ "${protocol}" == "ipv4" ]]; then
    printf "%s\n" "${ip}" >> "${output_file_ipv4}"
  else
    printf "%s\n" "${ip}" >> "${output_file_ipv6}"
  fi
}

# 解析 IP 范围：按优先级尝试处理（CIDR > 范围 > 单个 IP）
parse_ip_range() {
  local input="$1" output_file_ipv4="$2" output_file_ipv6="$3"
  local clean_ip

  [[ -z "${input}" ]] && return 1

  clean_ip=$(normalize_ip_input "${input}") || return 1
  [[ -z "${clean_ip}" ]] && return 1

  process_ipv4_cidr "${clean_ip}" "${output_file_ipv4}" && return 0
  process_ipv6_cidr "${clean_ip}" "${output_file_ipv6}" && return 0
  process_ipv4_range "${clean_ip}" "${output_file_ipv4}" && return 0
  process_ipv6_range "${clean_ip}" "${output_file_ipv6}" && return 0
  process_single_ip "${clean_ip}" "${output_file_ipv4}" "${output_file_ipv6}" && return 0

  log_warning "无效输入：${input}"
  return 1
}


# ==================== 核心功能 ====================
check_services() {
  local missing=0
  # firewalld：已安装但未运行时自动启动
  if systemctl is-active firewalld &>/dev/null; then
    log_info "Firewalld 服务已在运行"
  elif command -v firewall-cmd &>/dev/null; then
    log_info "Firewalld 已安装但未运行，正在自动启动..."
    service_ensure firewalld started || missing=1
  else
    log_error "Firewalld 未安装，请先执行 debnas run firewall"
    missing=1
  fi
  # cron：已安装但未运行时自动启动
  if systemctl is-active cron &>/dev/null; then
    log_info "Cron 服务已在运行"
  elif command -v cron &>/dev/null || dpkg -l cron &>/dev/null 2>&1; then
    log_info "Cron 已安装但未运行，正在自动启动..."
    service_ensure cron started || missing=1
  else
    log_warning "Cron 未安装，定时任务功能可能不可用"
  fi
  return "${missing}"
}


# ==================== 初始化函数 ====================
init_data_dir() {
  if [[ ! -d "${DATA_DIR}" ]]; then
    log_info "创建数据目录：${DATA_DIR}"
    mkdir -p "${DATA_DIR}" || {
      log_error "创建数据目录失败：${DATA_DIR}"
      return 1
    }
    chmod 755 "${DATA_DIR}"
  fi
}

init_manual() {
  # 文件日志由 lib/core/logging.sh 统一管理（main() 中调用 log_to_file）
  log_to_file "threat-ips" 2>/dev/null || true
  THREAT_LEVEL=${DEFAULT_THREAT_LEVEL}
}

init_cron() {
  # 文件日志由 lib/core/logging.sh 统一管理（main() 中调用 log_to_file）
  log_to_file "threat-ips" 2>/dev/null || true

  init_data_dir || return 1

  if [[ ! -f "${CONFIG_FILE}" ]]; then
    log_error "配置文件不存在：${CONFIG_FILE}"
    return 1
  fi
  while IFS='=' read -r key value; do
    case "${key}" in
      THREAT_LEVEL)
        if [[ "${value}" =~ ^[0-9]+$ ]] \
          && [[ "${value}" -ge 0 ]] && [[ "${value}" -le 100 ]]; then
          THREAT_LEVEL="${value}"
        else
          log_warning \
            "配置文件中的威胁等级无效：${value}，使用默认值"
          THREAT_LEVEL=${DEFAULT_THREAT_LEVEL}
        fi
        ;;
      UPDATE_CRON)
        # 兼容旧配置文件中可能存在的引号包裹
        UPDATE_CRON="${value//\"/}"
        export UPDATE_CRON
        ;;
    esac
  done < <(grep -E '^(THREAT_LEVEL|UPDATE_CRON)=' "${CONFIG_FILE}" \
    2>/dev/null || true)
  if ! [[ "${THREAT_LEVEL}" =~ ^[0-9]+$ ]] \
    || [[ "${THREAT_LEVEL}" -lt 0 || "${THREAT_LEVEL}" -gt 100 ]]; then
    THREAT_LEVEL=${DEFAULT_THREAT_LEVEL}
    log_warning \
      "配置文件中的威胁等级无效，使用默认值：${THREAT_LEVEL}"
  fi
  export THREAT_LEVEL
}


# ==================== 菜单函数（仅交互模式使用） ====================

# 显示威胁 IP 状态信息（动态查询，每次菜单渲染前刷新）
display_threat_status() {
  local ipv4_count=0 ipv6_count=0
  if check_ipset_exists "${IPSET_NAME_IPV4}"; then
    ipv4_count=$(firewall-cmd --permanent \
      --ipset="${IPSET_NAME_IPV4}" --get-entries | wc -l)
    [[ ! "${ipv4_count}" =~ ^[0-9]+$ ]] && ipv4_count=0
  fi
  if check_ipset_exists "${IPSET_NAME_IPV6}"; then
    ipv6_count=$(firewall-cmd --permanent \
      --ipset="${IPSET_NAME_IPV6}" --get-entries | wc -l)
    [[ ! "${ipv6_count}" =~ ^[0-9]+$ ]] && ipv6_count=0
  fi

  local threat_level=${DEFAULT_THREAT_LEVEL}
  if [[ -f "${CONFIG_FILE}" ]]; then
    local config_threat_level
    config_threat_level=$(grep -E '^THREAT_LEVEL=' "${CONFIG_FILE}" \
      2>/dev/null | cut -d'=' -f2 || printf "")
    if [[ -n "${config_threat_level}" ]] \
      && [[ "${config_threat_level}" =~ ^[0-9]+$ ]] \
      && [[ "${config_threat_level}" -ge 0 ]] \
      && [[ "${config_threat_level}" -le 100 ]]; then
      threat_level=${config_threat_level}
    fi
  fi

  log_info "工作区域: ${ZONE}"
  log_info "威胁等级: ${threat_level}"
  log_info "IP 使用： IPv4 ${ipv4_count}/${MAX_IP_LIMIT} IPv6 ${ipv6_count}/${MAX_IP_LIMIT}"
}

# 威胁 IP 菜单操作分发（从旧 show_menu 的 case 块提取）
_handle_threat_action() {
  local choice="$1"
  case "${choice}" in
    0)
      ensure_module_deps threat-ips || return 1
      check_services || return 1
      validate_zone
      enable_auto_update || {
        log_error "启用自动更新失败"
        return 1
      }
      ;;
    1) disable_auto_update ;;
    2) view_cron_jobs ;;
    *) log_warning "无效选项" ;;
  esac
}


# ==================== 主函数 ====================
main() {
  register_temp_cleanup

  if ! [[ "${MAX_IP_LIMIT}" =~ ^[0-9]+$ ]]; then
    log_error "无效 MAX_IP_LIMIT：${MAX_IP_LIMIT}"
    exit "${ERROR_GENERAL}"
  fi

  if [[ "${DEBNAS_CRON_MODE:-0}" -eq 0 ]]; then
    init_manual
    local -a items=("启用自动更新" "禁用自动更新" "查看定时任务")
    local choice exit_code menu_result
    while true; do
      display_threat_status
      menu_result=$(mktemp)
      UI_MENU_BACK_LABEL="← 返回上级" UI_MENU_RESULT_FILE="$menu_result" ui_menu "威胁 IP 封禁" "${items[@]}" || {
        exit_code=$?
        rm -f "$menu_result"
        case $exit_code in
          254) mark_normal_exit; return 0 ;;   # Esc：退出模块
          255) mark_normal_exit; return 0 ;;   # Q：退出模块
          *)   mark_normal_exit; return 0 ;;
        esac
      }
      choice=$(cat "$menu_result")
      rm -f "$menu_result"
      _handle_threat_action "$choice"
      sleep 1
    done
  else
    init_cron || exit "${ERROR_GENERAL}"
    validate_zone
    update_threat_ips
    mark_normal_exit
  fi
}

main "$@"
