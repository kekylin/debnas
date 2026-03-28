#!/bin/bash
# Firewalld-IPThreat 自动化威胁情报更新系统

set -euo pipefail
IFS=$'\n\t'

# 设置标准 PATH：cron 环境 PATH 可能不完整，需显式设置标准系统路径
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

# ==================== 运行模式检测 ====================
declare RUN_MODE="manual"
if [[ "${1:-}" == "--cron" ]]; then
  RUN_MODE="cron"
fi

# ==================== 公共库加载 ====================
if [[ "${RUN_MODE}" == "manual" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  # shellcheck source=lib/core/logging.sh
  source "${SCRIPT_DIR}/lib/core/logging.sh"
  # shellcheck source=lib/core/constants.sh
  source "${SCRIPT_DIR}/lib/core/constants.sh"
  # shellcheck source=lib/system/dependency.sh
  source "${SCRIPT_DIR}/lib/system/dependency.sh"
  # shellcheck source=lib/system/tempfile.sh
  source "${SCRIPT_DIR}/lib/system/tempfile.sh"
  # shellcheck source=lib/ui/styles.sh
  source "${SCRIPT_DIR}/lib/ui/styles.sh"
  # shellcheck source=lib/ui/menu.sh
  source "${SCRIPT_DIR}/lib/ui/menu.sh"
else
  # 定时任务模式：最小化日志函数，无颜色输出
  log_status() {
    local status="$1" message="$2"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    printf "[%s] %s %s\n" "$status" "$ts" "$message" >&2
  }
  log_success() { log_status "SUCCESS" "$1"; }
  log_warning() { log_status "WARNING" "$1"; }
  log_info()    { log_status "INFO" "$1"; }
  log_error()   { log_status "FAIL" "$1"; }
  log_fatal()   { log_status "FAIL" "$1"; }
fi

# ==================== 常量定义 ====================
REQUIRED_CMDS=(firewall-cmd ipset wget gzip awk sed grep sort head crontab sipcalc)

DATA_DIR="/var/lib/firewalld-ipthreat"
LOG_DIR="/var/log"
CONFIG_FILE="${DATA_DIR}/ipthreat.conf"
CRON_SCRIPT_PATH="${DATA_DIR}/firewalld_ipthreat.sh"
LOG_FILE="/var/log/firewalld-ipthreat.log"

DEFAULT_THREAT_LEVEL=50
DEFAULT_UPDATE_CRON="0 0 * * *"
ZONE="drop"
IPSET_NAME_IPV4="ipthreat_block_ipv4"
IPSET_NAME_IPV6="ipthreat_block_ipv6"

# hash:net 类型支持 CIDR，MAX_IP_LIMIT 表示 CIDR 条目数限制（非单个 IP 数量）
declare -i MAX_IP_LIMIT=65536
# IP 范围格式限制：威胁情报列表主要使用 CIDR，IP 范围格式较少且通常较小
declare -i MAX_RANGE_SIZE=256

get_threat_list_url() {
  local threat_level="${1:-${DEFAULT_THREAT_LEVEL}}"
  printf "%s%s%s" \
    "https://lists.ipthreat.net/file/ipthreat-lists/" \
    "threat/threat-" \
    "${threat_level}.txt.gz"
}

# ==================== 日志输出模块 ====================
# 统一日志输出：同时输出到终端和日志文件
log_message() {
  local level="${1}" message="${2}"
  local timestamp

  case "${level}" in
    SUCCESS) log_success "${message}" ;;
    INFO)    log_info "${message}" ;;
    WARNING) log_warning "${message}" ;;
    ERROR)   log_error "${message}" ;;
    FATAL)   log_fatal "${message}" ;;
    *)       log_info "${message}" ;;
  esac

  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  printf "[%s] [%s] %s\n" "${timestamp}" "${level}" "${message}" \
    >> "${LOG_FILE}" 2>/dev/null || true
}

# ==================== 临时文件管理 ====================
# 交互模式：由 tempfile.sh 库统一管理（register_temp_cleanup / create_temp_file）
# 定时任务模式：使用最小化自包含实现
if [[ "${RUN_MODE}" == "cron" ]]; then
  DEBNAS_TMP_BASE="${DEBNAS_TMP_BASE:-/tmp/debnas}"
  declare -a _DEBNAS_TEMP_FILES=()
  declare -g _DEBNAS_NORMAL_EXIT=0

  init_temp_dir() {
    if [[ ! -d "${DEBNAS_TMP_BASE}" ]]; then
      mkdir -p "${DEBNAS_TMP_BASE}" || {
        log_error "创建临时目录失败：${DEBNAS_TMP_BASE}"
        exit "${ERROR_GENERAL}"
      }
      chmod 700 "${DEBNAS_TMP_BASE}"
    fi
  }

  create_temp_file() {
    local prefix="$1" suffix="${2:-.tmp}"
    local temp_file
    init_temp_dir
    temp_file=$(mktemp "${DEBNAS_TMP_BASE}/${prefix}.XXXXXX${suffix}")
    _DEBNAS_TEMP_FILES+=("${temp_file}")
    printf "%s" "${temp_file}"
  }

  cleanup_temp_files() {
    local item i
    for (( i=${#_DEBNAS_TEMP_FILES[@]}-1; i>=0; i-- )); do
      item="${_DEBNAS_TEMP_FILES[$i]}"
      rm -f "${item}" 2>/dev/null || true
    done
    _DEBNAS_TEMP_FILES=()
    if [[ -d "${DEBNAS_TMP_BASE}" ]] \
      && [[ -z "$(ls -A "${DEBNAS_TMP_BASE}" 2>/dev/null)" ]]; then
      rmdir "${DEBNAS_TMP_BASE}" 2>/dev/null || true
    fi
  }

  register_temp_cleanup() {
    trap 'cleanup_temp_files' EXIT
    trap 'cleanup_temp_files; exit "${ERROR_GENERAL}"' INT TERM
  }

  mark_normal_exit() {
    _DEBNAS_NORMAL_EXIT=1
  }
fi

# ==================== 工具函数 ====================
check_ipset_exists() {
  local ipset_name="$1"
  firewall-cmd --permanent --get-ipsets | grep -qw "${ipset_name}"
}

check_ipset_bound() {
  local ipset_name="$1" zone="$2"
  firewall-cmd --permanent --zone="${zone}" --list-sources \
    | grep -qw "ipset:${ipset_name}"
}

# 使用 sipcalc 验证 IPv4 地址（支持 CIDR 格式）
validate_ipv4() {
  local ip=$1 sipcalc_output
  if [[ ! "${ip}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){0,3}(/[0-9]{1,2})?$ ]]; then
    return 1
  fi
  if sipcalc_output=$(sipcalc "${ip}" 2>/dev/null); then
    if printf "%s" "${sipcalc_output}" | grep -qiE "^\\-\\[ipv4\\s*:"; then
      return 0
    fi
  fi
  return 1
}

# 使用 sipcalc 验证 IPv6 地址（支持 CIDR 格式）
validate_ipv6() {
  local ip=$1 sipcalc_output
  if [[ ! "${ip}" =~ ^[0-9a-fA-F:]+(/[0-9]{1,3})?$ ]]; then
    return 1
  fi
  if sipcalc_output=$(sipcalc "${ip}" 2>/dev/null); then
    if printf "%s" "${sipcalc_output}" | grep -qiE "^\\-\\[ipv6\\s*:"; then
      return 0
    fi
  fi
  return 1
}

# 使用 sipcalc 验证 IP 地址并返回类型（输出 "ipv4" 或 "ipv6"）
validate_ip() {
  local ip=$1 sipcalc_output
  if sipcalc_output=$(sipcalc "${ip}" 2>/dev/null); then
    if printf "%s" "${sipcalc_output}" | grep -qiE "^\\-\\[ipv4\\s*:"; then
      printf "ipv4"
      return 0
    elif printf "%s" "${sipcalc_output}" | grep -qiE "^\\-\\[ipv6\\s*:"; then
      printf "ipv6"
      return 0
    fi
  fi
  return 1
}

# 验证 IPv4 CIDR 格式并提取前缀和掩码（输出 "前缀 掩码"）
validate_cidr_ipv4() {
  local input=$1 prefix mask sipcalc_output
  if [[ ! ${input} =~ ^([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})/([0-9]{1,2})$ ]]; then
    return 1
  fi
  prefix=${BASH_REMATCH[1]}
  mask=${BASH_REMATCH[2]}
  if [[ ! ${mask} =~ ^[0-9]+$ ]] || [[ ${mask} -gt 32 ]] || [[ ${mask} -lt 0 ]]; then
    return 1
  fi
  if sipcalc_output=$(sipcalc "${input}" 2>/dev/null); then
    if printf "%s" "${sipcalc_output}" | grep -qiE "^\\-\\[ipv4\\s*:"; then
      printf "%s %s" "${prefix}" "${mask}"
      return 0
    fi
  fi
  return 1
}

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
      log_message "WARNING" "无效 IPv6 CIDR 掩码：${cidr}"
      return 1
    fi
    if ! validate_ipv6 "${cidr}"; then
      log_message "WARNING" "无效 IPv6 CIDR 格式：${cidr}"
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
      log_message "WARNING" "无效 IPv4 范围地址：${range}"
      return 1
    fi
    IFS='.' read -r a b c d <<< "${start_ip}"
    start_num=$(( (a * 16777216) + (b * 65536) + (c * 256) + d ))
    IFS='.' read -r a b c d <<< "${end_ip}"
    end_num=$(( (a * 16777216) + (b * 65536) + (c * 256) + d ))
    if [[ ${start_num} -gt ${end_num} ]]; then
      log_message "WARNING" "无效 IPv4 范围：${range}（起始地址大于结束地址）"
      return 1
    fi
    ip_count=$((end_num - start_num + 1))
    if [[ ${ip_count} -gt ${MAX_RANGE_SIZE} ]]; then
      log_message "WARNING" \
        "IPv4 范围过大：${range}（${ip_count} 条，建议使用 CIDR 格式）"
      return 1
    fi
    local awk_output
    if ! awk_output=$(expand_ipv4_range "${start_num}" "${end_num}" 2>&1); then
      log_message "ERROR" "解析 IPv4 范围失败：${range}"
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
      log_message "WARNING" "无效 IPv6 范围：${range}"
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

  log_message "WARNING" "无效输入：${input}"
  return 1
}

# ==================== 核心功能 ====================
check_services() {
  local missing=0
  if ! systemctl is-active firewalld &>/dev/null; then
    log_message "ERROR" \
      "Firewalld 服务未运行（请执行 systemctl start firewalld）"
    missing=1
  fi
  if ! systemctl is-active cron &>/dev/null; then
    log_message "ERROR" \
      "Cron 服务未运行（请执行 systemctl start cron）"
    missing=1
  fi
  return "${missing}"
}

# ==================== 通用 IPSet 操作模块 ====================
# 配置单个 IPSet：创建并绑定到区域
# 返回：0 表示需要重载，1 表示无需重载
configure_single_ipset() {
  local ipset_name="$1" ip_family="$2" ip_type="$3"
  local need_log=0 need_reload=0

  if ! check_ipset_exists "${ipset_name}"; then
    need_log=1
    if ! firewall-cmd --permanent \
      --new-ipset="${ipset_name}" \
      --type=hash:net \
      --option=family="${ip_family}" \
      --option=maxelem=${MAX_IP_LIMIT} &>/dev/null; then
      log_message "ERROR" "配置 ${ip_type} IPSet 失败（请检查 Firewalld 配置）"
      exit "${ERROR_GENERAL}"
    fi
    need_reload=1
  fi
  if ! check_ipset_bound "${ipset_name}" "${ZONE}"; then
    need_log=1
    if ! firewall-cmd --permanent \
      --zone="${ZONE}" \
      --add-source="ipset:${ipset_name}" &>/dev/null; then
      log_message "ERROR" "配置 ${ip_type} IPSet 失败"
      exit "${ERROR_GENERAL}"
    fi
    need_reload=1
  fi
  if [[ ${need_log} -eq 1 ]]; then
    log_message "INFO" "配置 ${ip_type} IPSet 于 drop 区域"
  fi
  [[ ${need_reload} -eq 1 ]]
}

configure_ipset() {
  local need_reload=0
  if configure_single_ipset "${IPSET_NAME_IPV4}" "inet" "IPv4"; then
    need_reload=1
  fi
  if configure_single_ipset "${IPSET_NAME_IPV6}" "inet6" "IPv6"; then
    need_reload=1
  fi
  [[ ${need_reload} -eq 1 ]]
}

validate_zone() {
  if ! firewall-cmd --get-zones | grep -qw "${ZONE}"; then
    log_message "ERROR" "无效 Firewalld 区域：${ZONE}"
    exit "${ERROR_GENERAL}"
  fi
}

reload_firewalld() {
  local need_reload="${1:-0}"
  if [[ ${need_reload} -eq 1 ]]; then
    local cmd_output
    if ! cmd_output=$(firewall-cmd --reload 2>&1); then
      log_message "ERROR" "Firewalld 规则重载失败：${cmd_output}"
      return 1
    fi
    log_message "SUCCESS" "Firewalld 规则重载成功"
  fi
}

download_threat_list() {
  local threat_level="${1:-${THREAT_LEVEL:-${DEFAULT_THREAT_LEVEL}}}"
  local temp_gz="$2" temp_txt="$3"

  if ! [[ "${threat_level}" =~ ^[0-9]+$ ]] \
    || [[ "${threat_level}" -lt 0 || "${threat_level}" -gt 100 ]]; then
    log_message "WARNING" \
      "无效威胁等级：${threat_level}，使用默认：${DEFAULT_THREAT_LEVEL}"
    threat_level=${DEFAULT_THREAT_LEVEL}
  fi

  local download_url
  download_url=$(get_threat_list_url "${threat_level}")
  log_message "INFO" "下载威胁等级 ${threat_level} 的 IP 列表"

  if ! wget -q "${download_url}" -O "${temp_gz}"; then
    log_message "ERROR" \
      "下载威胁 IP 列表失败（威胁等级：${threat_level}）"
    return 1
  fi
  if ! gzip -dc "${temp_gz}" > "${temp_txt}"; then
    log_message "ERROR" "解压威胁 IP 列表失败"
    return 1
  fi
  rm -f "${temp_gz}"
  log_message "SUCCESS" "威胁 IP 列表下载完成（威胁等级：${threat_level}）"
}

# ==================== IP 列表处理模块 ====================
# 准备输入文件：过滤空行和注释
prepare_input_file() {
  local input_file="$1"
  local temp_input
  temp_input=$(create_temp_file "processed_input" ".txt")
  grep -v '^\s*$' "${input_file}" | grep -v '^\s*#' > "${temp_input}" || {
    log_message "INFO" "IP 列表为空或仅包含注释，无需处理"
    return 1
  }
  printf "%s" "${temp_input}"
}

# 解析 IP 条目：逐行解析并统计
parse_ip_entries() {
  local temp_input="$1" temp_file_ipv4="$2" temp_file_ipv6="$3"
  local total_count valid_count=0 invalid_count=0 ip

  total_count=$(wc -l < "${temp_input}")
  log_message "INFO" "解析 IP 列表中..."

  while IFS= read -r ip; do
    [[ -z "${ip}" ]] && continue
    if parse_ip_range "${ip}" "${temp_file_ipv4}" "${temp_file_ipv6}"; then
      ((valid_count += 1))
    else
      ((invalid_count += 1))
    fi
  done < "${temp_input}"

  if [[ ${valid_count} -gt 0 ]]; then
    log_message "INFO" \
      "解析 IP 列表：${valid_count} 条有效，${invalid_count} 条无效"
  fi
  if [[ ${invalid_count} -eq ${total_count} ]]; then
    log_message "INFO" "所有输入 IP (${invalid_count} 条) 无效，已跳过"
    return 1
  fi
}

deduplicate_and_sort_ips() {
  local temp_file="$1" output_file="$2"
  sort -u "${temp_file}" > "${output_file}" 2>/dev/null
}

check_and_limit_ip_count() {
  local ip_file="$1" ip_type="$2"
  local count
  count=$(wc -l < "${ip_file}")
  if [[ ${count} -gt ${MAX_IP_LIMIT} ]]; then
    log_message "WARNING" \
      "${ip_type} IP 数量超出上限 ${MAX_IP_LIMIT}，截取前 ${MAX_IP_LIMIT} 条"
    head -n "${MAX_IP_LIMIT}" "${ip_file}" > "${ip_file}.tmp" \
      && mv "${ip_file}.tmp" "${ip_file}"
    count=${MAX_IP_LIMIT}
  fi
  printf "%s" "${count}"
}

apply_ips_to_single_ipset() {
  local ip_file="$1" ipset_name="$2" ip_type="$3" mode="$4"
  local count
  count=$(wc -l < "${ip_file}" 2>/dev/null || printf "0")
  if [[ ${count} -eq 0 ]]; then
    return 0
  fi
  if ! apply_ip_changes "${ip_file}" "${ipset_name}" "${mode}"; then
    log_message "ERROR" "应用 ${ip_type} IP 变更失败"
    return 1
  fi
  printf "%s" "${count}"
}

apply_ips_to_ipsets() {
  local output_file_ipv4="$1" output_file_ipv6="$2" mode="$3"
  local ipv4_count ipv6_count

  ipv4_count=$(apply_ips_to_single_ipset \
    "${output_file_ipv4}" "${IPSET_NAME_IPV4}" "IPv4" "${mode}") || return 1
  ipv6_count=$(apply_ips_to_single_ipset \
    "${output_file_ipv6}" "${IPSET_NAME_IPV6}" "IPv6" "${mode}") || return 1

  if [[ -z "${ipv4_count}" ]] && [[ -z "${ipv6_count}" ]]; then
    log_message "INFO" "无 IP 需要处理"
    return 0
  fi
  log_message "SUCCESS" \
    "已处理 IPv4: ${ipv4_count:-0} 条 IPv6: ${ipv6_count:-0} 条"
}

# 去重排序单个 IP 类型文件
_process_single_ip_file() {
  local temp_file="$1" output_file="$2" ip_type="$3"
  if ! deduplicate_and_sort_ips "${temp_file}" "${output_file}"; then
    return 1
  fi
  check_and_limit_ip_count "${output_file}" "${ip_type}" >/dev/null
}

# 处理 IP 列表：解析、去重、排序、限制数量并应用到 IPSet
process_ip_list() {
  local input_file="$1" output_file_ipv4="$2" output_file_ipv6="$3"
  local mode="$4"
  local temp_file_ipv4 temp_file_ipv6 temp_input

  temp_file_ipv4=$(create_temp_file "expanded_ips_ipv4" ".txt")
  temp_file_ipv6=$(create_temp_file "expanded_ips_ipv6" ".txt")
  : > "${temp_file_ipv4}"
  : > "${temp_file_ipv6}"

  temp_input=$(prepare_input_file "${input_file}") || return 0

  if ! parse_ip_entries "${temp_input}" "${temp_file_ipv4}" "${temp_file_ipv6}"; then
    return 0
  fi

  if [[ ! -s "${temp_file_ipv4}" && ! -s "${temp_file_ipv6}" ]]; then
    log_message "ERROR" "无有效 IP（请检查输入格式）"
    return 1
  fi

  _process_single_ip_file "${temp_file_ipv4}" "${output_file_ipv4}" "IPv4" \
    || return 1
  _process_single_ip_file "${temp_file_ipv6}" "${output_file_ipv6}" "IPv6" \
    || return 1

  apply_ips_to_ipsets "${output_file_ipv4}" "${output_file_ipv6}" "${mode}"
}

apply_ip_changes() {
  local ip_file="$1" ipset_name="$2" mode="$3"
  local ip_count_before

  if ! check_ipset_exists "${ipset_name}"; then
    log_message "ERROR" "IPSet 不存在：${ipset_name}"
    return 1
  fi

  if ! sort -u "${ip_file}" > "${ip_file}.tmp" 2>/dev/null; then
    log_message "ERROR" "去重失败：${ip_file}"
    return 1
  fi
  mv "${ip_file}.tmp" "${ip_file}"
  ip_count_before=$(wc -l < "${ip_file}")

  if [[ ${ip_count_before} -eq 0 ]]; then
    log_message "INFO" "输入文件为空，无需${mode}操作"
    return 0
  fi

  if [[ "${mode}" == "add" ]]; then
    if [[ ${ip_count_before} -gt ${MAX_IP_LIMIT} ]]; then
      log_message "WARNING" \
        "输入条目数超过 IPSet 上限：${ipset_name}（${ip_count_before} > ${MAX_IP_LIMIT}）"
      return 1
    fi
    if ! firewall-cmd --permanent \
      --ipset="${ipset_name}" \
      --add-entries-from-file="${ip_file}" &>/dev/null; then
      log_message "ERROR" "添加 IP 到 IPSet 失败：${ipset_name}"
      return 1
    fi
  elif [[ "${mode}" == "remove" ]]; then
    if ! firewall-cmd --permanent \
      --ipset="${ipset_name}" \
      --remove-entries-from-file="${ip_file}" &>/dev/null; then
      log_message "ERROR" "从 IPSet 移除 IP 失败：${ipset_name}"
      return 1
    fi
  fi
}

# ==================== IP 移除模块 ====================
remove_ips_from_single_ipset() {
  local ipset_name="$1" temp_file="$2" ip_type="$3"
  local sources
  sources=$(firewall-cmd --permanent \
    --ipset="${ipset_name}" --get-entries 2>/dev/null)
  if [[ -z "${sources}" ]]; then
    return 0
  fi
  printf "%s" "${sources}" | tr ' ' '\n' > "${temp_file}"
  apply_ip_changes "${temp_file}" "${ipset_name}" "remove" || {
    log_message "WARNING" "移除 ${ip_type} IP 失败，继续执行清理"
  }
}

remove_ips_from_ipsets() {
  local temp_ipv4 temp_ipv6
  temp_ipv4=$(create_temp_file "remove_ipv4" ".txt")
  temp_ipv6=$(create_temp_file "remove_ipv6" ".txt")
  remove_ips_from_single_ipset "${IPSET_NAME_IPV4}" "${temp_ipv4}" "IPv4"
  remove_ips_from_single_ipset "${IPSET_NAME_IPV6}" "${temp_ipv6}" "IPv6"
}

# 从区域解绑单个 IPSet（返回：0 需要重载，1 无需重载）
unbind_single_ipset_from_zone() {
  local ipset_name="$1" ip_type="$2"
  local ipset_bound need_reload=0
  ipset_bound=$(firewall-cmd --permanent --zone=drop --list-sources \
    | grep -w "ipset:${ipset_name}" || true)
  if [[ -z "${ipset_bound}" ]]; then
    return 0
  fi
  log_message "INFO" "从 drop 区域解绑 ${ip_type} IPSet"
  if firewall-cmd --permanent --zone=drop \
    --remove-source="ipset:${ipset_name}" &>/dev/null; then
    need_reload=1
  else
    log_message "WARNING" "解绑 ${ip_type} IPSet 失败，继续执行清理"
  fi
  [[ ${need_reload} -eq 1 ]]
}

unbind_ipsets_from_zone() {
  local need_reload=0
  if unbind_single_ipset_from_zone "${IPSET_NAME_IPV4}" "IPv4"; then
    need_reload=1
  fi
  if unbind_single_ipset_from_zone "${IPSET_NAME_IPV6}" "IPv6"; then
    need_reload=1
  fi
  [[ ${need_reload} -eq 1 ]]
}

delete_single_ipset() {
  local ipset_name="$1" ip_type="$2" need_reload=0
  local ipset_old_file="/etc/firewalld/ipsets/${ipset_name}.xml.old"

  if ! check_ipset_exists "${ipset_name}"; then
    if [[ -f "${ipset_old_file}" ]]; then
      rm -f "${ipset_old_file}" 2>/dev/null || true
    fi
    return 0
  fi
  log_message "INFO" "删除 ${ip_type} IPSet：${ipset_name}"
  if firewall-cmd --permanent --delete-ipset="${ipset_name}" &>/dev/null; then
    need_reload=1
    if [[ -f "${ipset_old_file}" ]]; then
      rm -f "${ipset_old_file}" 2>/dev/null || true
    fi
  else
    log_message "WARNING" "删除 ${ip_type} IPSet 失败，继续执行清理"
  fi
  [[ ${need_reload} -eq 1 ]]
}

delete_ipsets() {
  local need_reload=0
  if delete_single_ipset "${IPSET_NAME_IPV4}" "IPv4"; then
    need_reload=1
  fi
  if delete_single_ipset "${IPSET_NAME_IPV6}" "IPv6"; then
    need_reload=1
  fi
  [[ ${need_reload} -eq 1 ]]
}

# 清理 drop 区域配置：仅在区域完全清空时删除自定义配置文件
cleanup_drop_zone_config() {
  local drop_xml_file="/etc/firewalld/zones/drop.xml"
  local remaining_sources drop_zone_info need_reload=0

  remaining_sources=$(firewall-cmd --permanent --zone=drop --list-sources \
    2>/dev/null | grep -v "^$" || true)
  drop_zone_info=$(firewall-cmd --permanent --zone=drop --list-all \
    2>/dev/null || true)

  local has_services has_ports has_protocols has_rich_rules
  has_services=$(printf "%s" "${drop_zone_info}" \
    | grep -E "^  services:" | grep -v "services: $" || true)
  has_ports=$(printf "%s" "${drop_zone_info}" \
    | grep -E "^  ports:" | grep -v "ports: $" || true)
  has_protocols=$(printf "%s" "${drop_zone_info}" \
    | grep -E "^  protocols:" | grep -v "protocols: $" || true)
  has_rich_rules=$(printf "%s" "${drop_zone_info}" \
    | grep -E "^  rich rules:" | grep -v "rich rules: $" || true)

  if [[ -z "${remaining_sources}" ]] && [[ -z "${has_services}" ]] \
    && [[ -z "${has_ports}" ]] && [[ -z "${has_protocols}" ]] \
    && [[ -z "${has_rich_rules}" ]]; then
    if [[ -f "${drop_xml_file}" ]]; then
      log_message "INFO" \
        "drop 区域已清空，删除自定义配置文件：${drop_xml_file}"
      if rm -f "${drop_xml_file}"; then
        need_reload=1
        local drop_old_file="/etc/firewalld/zones/drop.xml.old"
        if [[ -f "${drop_old_file}" ]]; then
          rm -f "${drop_old_file}" 2>/dev/null || true
        fi
      else
        log_message "WARNING" \
          "删除 drop 区域配置文件失败：${drop_xml_file}，继续执行清理"
      fi
    fi
  elif [[ -n "${remaining_sources}" ]]; then
    log_message "INFO" "drop 区域仍有其他 sources，保留配置文件"
  fi
  [[ ${need_reload} -eq 1 ]]
}

remove_all_ips() {
  local need_reload=0

  if ! check_ipset_exists "${IPSET_NAME_IPV4}" \
    && ! check_ipset_exists "${IPSET_NAME_IPV6}"; then
    log_message "INFO" "未配置 IPSet"
    return 0
  fi

  remove_ips_from_ipsets

  if unbind_ipsets_from_zone; then
    need_reload=1
  fi
  if delete_ipsets; then
    need_reload=1
  fi
  if cleanup_drop_zone_config; then
    need_reload=1
  fi

  reload_firewalld ${need_reload} || {
    log_message "WARNING" "Firewalld 重载失败，但继续执行清理"
  }
  log_message "SUCCESS" "已移除所有封禁 IP"
}

# ==================== 自动更新管理 ====================
enable_auto_update() {
  local cron_schedule threat_level input

  print_prompt "请输入威胁等级（0-100，留空使用默认：${DEFAULT_THREAT_LEVEL}）："
  read -r input || true
  threat_level="${input:-${DEFAULT_THREAT_LEVEL}}"
  if ! [[ "${threat_level}" =~ ^[0-9]+$ ]] \
    || [[ "${threat_level}" -lt 0 ]] || [[ "${threat_level}" -gt 100 ]]; then
    log_message "WARNING" \
      "无效威胁等级：${threat_level}，使用默认：${DEFAULT_THREAT_LEVEL}"
    threat_level=${DEFAULT_THREAT_LEVEL}
  fi
  THREAT_LEVEL=${threat_level}
  export THREAT_LEVEL

  print_prompt "请输入 Cron 规则（留空使用默认：${DEFAULT_UPDATE_CRON}）："
  read -r input || true
  cron_schedule="${input:-${DEFAULT_UPDATE_CRON}}"
  if ! printf "%s" "${cron_schedule}" \
    | grep -qE '^[0-9*,/-]+[[:space:]]+[0-9*,/-]+[[:space:]]+[0-9*,/-]+[[:space:]]+[0-9*,/-]+[[:space:]]+[0-9*,/-]+$'; then
    log_message "WARNING" \
      "无效 Cron 规则：${cron_schedule}，使用默认：${DEFAULT_UPDATE_CRON}"
    cron_schedule=${DEFAULT_UPDATE_CRON}
  fi

  init_data_dir
  if [[ ! -d "${LOG_DIR}" ]]; then
    log_message "INFO" "创建日志目录：${LOG_DIR}"
    mkdir -p "${LOG_DIR}" || {
      log_message "ERROR" "创建日志目录失败：${LOG_DIR}"
      return 1
    }
    chmod 755 "${LOG_DIR}"
  fi
  if [[ ! -f "${LOG_FILE}" ]]; then
    log_message "INFO" "创建日志文件：${LOG_FILE}"
    touch "${LOG_FILE}" || {
      log_message "ERROR" "创建日志文件失败：${LOG_FILE}"
      return 1
    }
    chmod 644 "${LOG_FILE}"
  fi
  if [[ ! -w "${LOG_FILE}" ]]; then
    log_message "ERROR" "日志文件不可写：${LOG_FILE}（请检查权限）"
    return 1
  fi

  printf "THREAT_LEVEL=%s\n" "${threat_level}" > "${CONFIG_FILE}" || {
    log_message "ERROR" "写入配置文件失败：${CONFIG_FILE}"
    return 1
  }
  printf "UPDATE_CRON=%s\n" "${cron_schedule}" >> "${CONFIG_FILE}" || {
    log_message "ERROR" "写入配置文件失败：${CONFIG_FILE}"
    return 1
  }
  chmod 644 "${CONFIG_FILE}" 2>/dev/null

  cp -f "$0" "${CRON_SCRIPT_PATH}" || {
    log_message "ERROR" "复制脚本失败：${CRON_SCRIPT_PATH}"
    return 1
  }
  chmod 755 "${CRON_SCRIPT_PATH}" 2>/dev/null

  local temp_cron
  temp_cron=$(create_temp_file "cron")
  crontab -l > "${temp_cron}" 2>/dev/null || true
  sed -i '/# IPThreat Firewalld Update/d' "${temp_cron}"
  printf "%s /bin/bash %s --cron # IPThreat Firewalld Update\n" \
    "${cron_schedule}" "${CRON_SCRIPT_PATH}" >> "${temp_cron}"
  if ! crontab "${temp_cron}"; then
    log_message "ERROR" "设置 crontab 失败（请检查 cron 服务）"
    return 1
  fi
  log_message "SUCCESS" \
    "启用自动更新：威胁等级 ${threat_level}，定时 ${cron_schedule}"

  if ! update_threat_ips "${threat_level}"; then
    log_message "WARNING" \
      "首次更新失败，但自动更新已启用（将在下次定时任务时重试）"
  fi
}

disable_auto_update() {
  local temp_cron
  temp_cron=$(create_temp_file "cron")
  crontab -l > "${temp_cron}" 2>/dev/null || true
  sed -i '/# IPThreat Firewalld Update/d' "${temp_cron}"
  if ! crontab "${temp_cron}"; then
    log_message "ERROR" "移除 crontab 失败（请检查 cron 服务）"
    exit "${ERROR_GENERAL}"
  fi

  remove_all_ips || {
    log_message "WARNING" "清理防火墙配置时出现警告，继续执行清理"
  }

  if [[ -f "${CONFIG_FILE}" ]]; then
    log_message "INFO" "删除配置文件：${CONFIG_FILE}"
    rm -f "${CONFIG_FILE}" || {
      log_message "ERROR" "删除配置文件失败：${CONFIG_FILE}"
      exit "${ERROR_GENERAL}"
    }
  fi
  if [[ -f "${CRON_SCRIPT_PATH}" ]]; then
    log_message "INFO" "删除脚本文件：${CRON_SCRIPT_PATH}"
    rm -f "${CRON_SCRIPT_PATH}" || {
      log_message "ERROR" "删除脚本文件失败：${CRON_SCRIPT_PATH}"
      exit "${ERROR_GENERAL}"
    }
  fi
  if [[ -d "${DATA_DIR}" ]]; then
    if [[ -z "$(ls -A "${DATA_DIR}" 2>/dev/null)" ]]; then
      log_message "INFO" "删除数据目录：${DATA_DIR}"
      rmdir "${DATA_DIR}" 2>/dev/null || true
    else
      log_message "WARNING" "数据目录 ${DATA_DIR} 非空，保留目录"
    fi
  fi

  log_message "SUCCESS" "已禁用自动更新并清理所有相关配置"
}

view_cron_jobs() {
  local cron_jobs
  cron_jobs=$(crontab -l 2>/dev/null \
    | grep '# IPThreat Firewalld Update' || true)
  if [[ -z "${cron_jobs}" ]]; then
    log_message "INFO" "未设置任何与 IPThreat Firewalld 相关的定时任务"
  else
    printf "%s\n" "${cron_jobs}" | while IFS= read -r line; do
      log_message "INFO" "定时任务：${line}"
    done
  fi
}

update_threat_ips() {
  local threat_level="${1:-${THREAT_LEVEL:-${DEFAULT_THREAT_LEVEL}}}"
  local temp_gz temp_txt temp_file_ipv4 temp_file_ipv6

  if ! [[ "${threat_level}" =~ ^[0-9]+$ ]] \
    || [[ "${threat_level}" -lt 0 || "${threat_level}" -gt 100 ]]; then
    log_message "WARNING" \
      "无效威胁等级：${threat_level}，使用默认：${DEFAULT_THREAT_LEVEL}"
    threat_level=${DEFAULT_THREAT_LEVEL}
  fi

  temp_gz=$(create_temp_file "threat" ".gz")
  temp_txt=$(create_temp_file "threat" ".txt")
  temp_file_ipv4=$(create_temp_file "valid_ips_ipv4" ".txt")
  temp_file_ipv6=$(create_temp_file "valid_ips_ipv6" ".txt")

  if ! check_ipset_exists "${IPSET_NAME_IPV4}" \
    && ! check_ipset_exists "${IPSET_NAME_IPV6}"; then
    configure_ipset || true
  fi

  if ! download_threat_list "${threat_level}" "${temp_gz}" "${temp_txt}"; then
    log_message "ERROR" "下载威胁 IP 列表失败，终止更新"
    return 1
  fi

  if ! filter_and_add_ips "${temp_txt}" "${temp_file_ipv4}" "${temp_file_ipv6}"; then
    log_message "ERROR" "处理 IP 列表失败，终止更新"
    return 1
  fi
}

# ==================== IP 过滤和添加模块 ====================
clear_single_ipset_entries() {
  local ipset_name="$1" ip_type="$2"
  local existing_entries temp_file
  if ! check_ipset_exists "${ipset_name}"; then
    return 0
  fi
  existing_entries=$(firewall-cmd --permanent \
    --ipset="${ipset_name}" --get-entries 2>/dev/null || printf "")
  if [[ -z "${existing_entries}" ]]; then
    return 0
  fi
  temp_file=$(create_temp_file "clear_${ip_type}" ".txt")
  printf "%s" "${existing_entries}" | tr ' ' '\n' > "${temp_file}" 2>/dev/null
  if [[ -s "${temp_file}" ]]; then
    apply_ip_changes "${temp_file}" "${ipset_name}" "remove" || {
      log_message "WARNING" "清空 ${ip_type} IPSet 时出现警告，继续执行"
    }
  fi
}

clear_all_ipsets() {
  clear_single_ipset_entries "${IPSET_NAME_IPV4}" "IPv4"
  clear_single_ipset_entries "${IPSET_NAME_IPV6}" "IPv6"
}

filter_and_add_ips() {
  local temp_txt="$1" temp_file_ipv4="$2" temp_file_ipv6="$3"
  local need_reload=0

  [[ ! -f "${temp_txt}" ]] && {
    log_message "ERROR" "IP 列表文件不存在：${temp_txt}"
    return 1
  }

  if configure_ipset; then
    need_reload=1
  fi
  clear_all_ipsets

  if ! process_ip_list "${temp_txt}" "${temp_file_ipv4}" "${temp_file_ipv6}" "add"; then
    log_message "ERROR" "处理 IP 列表失败"
    return 1
  fi

  # 使用 --permanent 修改 IPSet 后必须重载防火墙才能生效
  need_reload=1

  if ! reload_firewalld ${need_reload}; then
    log_message "ERROR" "Firewalld 重载失败"
    return 1
  fi
}

# ==================== 初始化函数 ====================
init_data_dir() {
  if [[ ! -d "${DATA_DIR}" ]]; then
    log_message "INFO" "创建数据目录：${DATA_DIR}"
    mkdir -p "${DATA_DIR}" || {
      log_message "ERROR" "创建数据目录失败：${DATA_DIR}"
      exit "${ERROR_GENERAL}"
    }
    chmod 755 "${DATA_DIR}"
  fi
}

init_manual() {
  if [[ ! -d "${LOG_DIR}" ]]; then
    log_message "INFO" "创建日志目录：${LOG_DIR}"
    mkdir -p "${LOG_DIR}" || {
      log_message "ERROR" "创建日志目录失败：${LOG_DIR}"
      exit "${ERROR_GENERAL}"
    }
    chmod 755 "${LOG_DIR}"
  fi
  if [[ ! -f "${LOG_FILE}" ]]; then
    log_message "INFO" "创建日志文件：${LOG_FILE}"
    touch "${LOG_FILE}" || {
      log_message "ERROR" "创建日志文件失败：${LOG_FILE}"
      exit "${ERROR_GENERAL}"
    }
    chmod 644 "${LOG_FILE}"
  fi
  if [[ ! -w "${LOG_FILE}" ]]; then
    log_message "ERROR" "日志文件不可写：${LOG_FILE}（请检查权限）"
    exit "${ERROR_GENERAL}"
  fi
  THREAT_LEVEL=${DEFAULT_THREAT_LEVEL}
}

init_cron() {
  if [[ ! -f "${LOG_FILE}" ]]; then
    log_message "ERROR" "日志文件不存在：${LOG_FILE}"
    exit "${ERROR_GENERAL}"
  fi
  if [[ ! -w "${LOG_FILE}" ]]; then
    log_message "ERROR" "日志文件不可写：${LOG_FILE}（请检查权限）"
    exit "${ERROR_GENERAL}"
  fi

  init_data_dir

  if [[ ! -f "${CONFIG_FILE}" ]]; then
    log_message "ERROR" "配置文件不存在：${CONFIG_FILE}"
    exit "${ERROR_GENERAL}"
  fi
  while IFS='=' read -r key value; do
    case "${key}" in
      THREAT_LEVEL)
        if [[ "${value}" =~ ^[0-9]+$ ]] \
          && [[ "${value}" -ge 0 ]] && [[ "${value}" -le 100 ]]; then
          THREAT_LEVEL="${value}"
        else
          log_message "WARNING" \
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
    log_message "WARNING" \
      "配置文件中的威胁等级无效，使用默认值：${THREAT_LEVEL}"
  fi
  export THREAT_LEVEL
}

# ==================== 菜单函数（仅交互模式使用） ====================
# 依赖检查包装函数：先检查后尝试自动安装
check_required_dependencies() {
  if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
    log_message "INFO" "检测到部分依赖未安装，尝试自动安装..."
    if ! install_missing_dependencies "${REQUIRED_CMDS[@]}"; then
      log_message "ERROR" "依赖安装失败，请手动安装缺失的依赖"
      list_missing_dependencies "${REQUIRED_CMDS[@]}"
      return 1
    fi
    if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
      log_message "ERROR" "依赖安装后仍有缺失，请手动安装"
      list_missing_dependencies "${REQUIRED_CMDS[@]}"
      return 1
    fi
  fi
}

show_menu() {
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

  print_separator "-"
  print_info "工作区域: ${ZONE}"
  print_info "威胁等级: ${threat_level}"
  print_info "IP 使用： IPv4 ${ipv4_count}/${MAX_IP_LIMIT} IPv6 ${ipv6_count}/${MAX_IP_LIMIT}"
  print_separator "-"
  print_menu_item "1" "启用自动更新"
  print_menu_item "2" "禁用自动更新"
  print_menu_item "3" "查看定时任务"
  print_menu_item "0" "退出" "true"
  print_separator "-"

  local choice
  print_prompt "请选择编号: "
  read -r choice || {
    log_message "INFO" "输入流结束，退出脚本"
    mark_normal_exit
    exit 0
  }
  choice=$(printf "%s" "${choice}" | tr -d '[:space:]')

  case "${choice}" in
    1)
      check_required_dependencies || return 1
      check_services || return 1
      validate_zone
      enable_auto_update || {
        log_message "ERROR" "启用自动更新失败"
        return 1
      }
      ;;
    2) disable_auto_update ;;
    3) view_cron_jobs ;;
    0) mark_normal_exit; exit 0 ;;
    *) log_message "WARNING" "无效选项：${choice}" ;;
  esac
}

# ==================== 主函数 ====================
main() {
  register_temp_cleanup

  if ! [[ "${MAX_IP_LIMIT}" =~ ^[0-9]+$ ]]; then
    log_message "ERROR" "无效 MAX_IP_LIMIT：${MAX_IP_LIMIT}"
    exit "${ERROR_GENERAL}"
  fi

  if [[ "${RUN_MODE}" == "manual" ]]; then
    init_manual
    while true; do
      show_menu
    done
  else
    init_cron
    validate_zone
    update_threat_ips
    mark_normal_exit
  fi
}

main "$@"
