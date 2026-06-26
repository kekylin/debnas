#!/bin/bash
# @module: block-threat-ips
# @name: IP 封禁工具
# @category: 安全防护
# @depends: firewall-cmd,ipset,wget,gzip,awk,sed,grep,sort,comm,head,crontab,sipcalc
# @depend_modules: install-firewall
# @version: 2.0.0
# @order: 43
# @cron: true
# @cron_schedule: 0 */6 * * *
# 功能：Firewalld-IPThreat 自动化威胁情报更新系统（目录模块入口）

set -euo pipefail
IFS=$'\n\t'

# 设置标准 PATH
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

# ==================== 运行模式检测 ====================
declare RUN_MODE="manual"
if [[ "${1:-}" == "--cron" ]]; then
  RUN_MODE="cron"
fi

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

# ==================== 日志输出模块 ====================
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


# ==================== 初始化函数 ====================
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


# ==================== 菜单函数 ====================
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
