#!/bin/bash
# @module: threat-ips
# @name: 威胁 IP 封禁
# @category: 安全防护
# @depends: firewall-cmd,ipset,wget
# @depend_modules: firewall
# @interactive: true
# @version: 2.0.0
# @order: 43
# @cron: true
# @cron_schedule: 0 0 * * *
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

# ==================== 核心功能 ====================
check_services() {
  local rc=0
  # firewalld：已安装但未运行时自动启动
  if service_is_active firewalld; then
    log_info "Firewalld 服务已在运行"
  elif command -v firewall-cmd &>/dev/null; then
    log_info "Firewalld 已安装但未运行，正在自动启动..."
    service_ensure firewalld started || rc=1
  else
    log_error "Firewalld 未安装，请先执行 debnas run firewall"
    rc=1
  fi
  # cron：已安装但未运行时自动启动
  if service_is_active cron; then
    log_info "Cron 服务已在运行"
  elif command -v cron &>/dev/null || dpkg -l cron &>/dev/null; then
    log_info "Cron 已安装但未运行，正在自动启动..."
    service_ensure cron started || rc=1
  else
    log_warning "Cron 未安装，定时任务功能可能不可用"
  fi
  return "${rc}"
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

  # 未经 debnas update 升级（如重跑 install.sh）时旧数据目录可能还没迁移：就地补做一次（幂等）
  if [[ ! -f "${CONFIG_FILE}" ]] && [[ -d "${DEBNAS_LEGACY_THREAT_IPS_DIR:-}" ]] \
    && declare -F migration_layout_threat_ips >/dev/null 2>&1; then
    DEBNAS_MANIFEST_SOURCE="migration" migration_layout_threat_ips || true
  fi

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
        log_error "启用威胁封禁失败"
        return 1
      }
      ;;
    1) disable_auto_update ;;
    2) cron_settings_menu "threat-ips" ;;
    *) log_warning "无效选项" ;;
  esac
}


# ==================== 只读探测契约（docs/ARCHITECTURE.md §4.5） ====================
# 只读 firewalld 永久配置 XML（不调 firewall-cmd：其为 Python 进程、每次 >300ms 且需 root/polkit）

_THREAT_FW_DIR="${THREAT_FW_DIR:-/etc/firewalld}"

# 统计永久 IPSet 条目数
# 参数：$1 - IPSet 名；输出：条目数；返回：0 存在，1 不存在，2 无权读取
_threat_ipset_count() {
  local f="${_THREAT_FW_DIR}/ipsets/${1}.xml" n=""
  if [[ ! -e "$f" ]]; then
    [[ -d "${_THREAT_FW_DIR}/ipsets" && ! -r "${_THREAT_FW_DIR}/ipsets" ]] && return 2
    [[ -d "${_THREAT_FW_DIR}" && ! -x "${_THREAT_FW_DIR}" ]] && return 2
    return 1
  fi
  [[ -r "$f" ]] || return 2
  n=$(grep -c '<entry>' "$f" 2>/dev/null) || n=0
  printf '%s' "${n:-0}"
}

# IPSet 是否已绑定到 drop 区（永久配置）
_threat_ipset_bound() {
  local f="${_THREAT_FW_DIR}/zones/${ZONE}.xml"
  [[ -r "$f" ]] && grep -qF "<source ipset=\"${1}\"/>" "$f" 2>/dev/null
}

# 读取已保存的威胁等级（未启用时为空）
_threat_saved_level() {
  [[ -r "${CONFIG_FILE}" ]] || return 0
  sed -n '/^THREAT_LEVEL=/{s/^THREAT_LEVEL=\([0-9]*\).*/\1/p;q;}' "${CONFIG_FILE}" 2>/dev/null || true
}

# 当前状态：一行 "状态码|说明"
module_status() {
  if ! command -v firewall-cmd &>/dev/null; then
    echo "absent|未安装 firewalld（需先执行 firewall 模块）"
    return 0
  fi
  local c4="" c6="" rc4=0 rc6=0 level enabled=0
  c4=$(_threat_ipset_count "${IPSET_NAME_IPV4}") || rc4=$?
  c6=$(_threat_ipset_count "${IPSET_NAME_IPV6}") || rc6=$?
  level=$(_threat_saved_level)
  feature_enabled "threat-ips" 2>/dev/null && enabled=1

  if [[ $rc4 -eq 2 || $rc6 -eq 2 ]]; then
    if [[ $enabled -eq 1 ]]; then
      echo "unknown|已启用${level:+（等级 ${level}）}；IPSet 条目需 root 查看"
    else
      echo "unknown|IPSet 状态需 root 查看"
    fi
    return 0
  fi
  if [[ $rc4 -ne 0 && $rc6 -ne 0 ]]; then
    if [[ $enabled -eq 1 || -n "$level" ]]; then
      echo "warn|已启用${level:+（等级 ${level}）}但未找到威胁 IPSet（首次更新可能失败）"
    else
      echo "absent|未启用威胁 IP 封禁"
    fi
    return 0
  fi

  local total=$(( ${c4:-0} + ${c6:-0} ))
  local desc="IPv4 ${c4:-0} / IPv6 ${c6:-0} 条${level:+ · 等级 ${level}}"
  if [[ $enabled -ne 1 && -z "$level" ]]; then
    echo "warn|已禁用但 IPSet 仍残留（${desc}）"
    return 0
  fi
  if ! service_is_active firewalld; then
    echo "warn|firewalld 未运行，封禁未生效（${desc}）"
    return 0
  fi
  if ! _threat_ipset_bound "${IPSET_NAME_IPV4}" && ! _threat_ipset_bound "${IPSET_NAME_IPV6}"; then
    echo "partial|IPSet 未绑定到 ${ZONE} 区，封禁未生效（${desc}）"
    return 0
  fi
  if [[ $total -eq 0 ]]; then
    echo "partial|已启用但 IPSet 为空（${desc}）"
    return 0
  fi
  case "$(cron_state threat-ips)" in
    on)  echo "applied|封禁中 · ${desc} · 定时更新已开启" ;;
    off) echo "partial|封禁中 · ${desc} · 未设置定时更新" ;;
    *)   echo "applied|封禁中 · ${desc}（定时任务需 root 查看）" ;;
  esac
}

# 预演：每行 "类型|目标|备注"（交互式模块：列出各菜单动作可能的影响）
module_plan() {
  local IFS=$' \n\t'
  local -a missing=()
  local cmd pkg
  # firewall-cmd 属服务依赖（不自动安装，由 firewall 模块负责），下方单列 risk
  for cmd in ipset wget; do
    command -v "$cmd" &>/dev/null && continue
    pkg="${cmd_to_pkg[$cmd]:-$cmd}"
    missing+=("$pkg")
  done

  echo "info|threat-ips|交互式菜单：启用（输入威胁等级 0-100，默认 ${DEFAULT_THREAT_LEVEL}）/ 禁用 / 定时设置，按选择执行"
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "pkg|${missing[*]}|启用时按 @depends 检查/安装"
  fi
  if ! command -v firewall-cmd &>/dev/null; then
    echo "risk|firewalld|未安装 firewalld，启用会失败；请先执行 firewall 模块"
  elif ! service_is_active firewalld; then
    echo "service|firewalld|启用时自动启动"
  fi
  echo "write|${CONFIG_FILE}|启用时写入威胁等级（直接覆盖，不另做备份）；禁用时删除"
  echo "write|firewalld 永久配置|启用：建 IPSet ${IPSET_NAME_IPV4}/${IPSET_NAME_IPV6}（hash:net）并绑定到 ${ZONE} 区；禁用：解绑并删除（firewall-cmd --permanent，不另做备份）"
  echo "info|威胁情报|启用时联网下载 lists.ipthreat.net 列表（最多 ${MAX_IP_LIMIT} 条/协议族），执行时探测"
  echo "info|${WHITELIST_FILE}|白名单（若存在）、私有网段、本机地址及当前 SSH/登录来源不会被封禁"
  if [[ "$(cron_state threat-ips)" == "on" ]]; then
    echo "info|cron|定时更新已开启（$(cron_get_schedule threat-ips 2>/dev/null || echo 已注册)）；禁用时移除"
  else
    echo "cron|threat-ips|仅当在「定时设置」中启用时写入 root crontab（默认 ${DEFAULT_UPDATE_CRON}）；禁用时移除"
  fi
  echo "risk|误封|威胁情报列表可能包含正常地址，被封来源完全无法访问本机（drop 区丢弃）；等级越低封禁越多"
  return 0
}

# ==================== 主函数 ====================
main() {
  register_temp_cleanup

  if [[ "${1:-}" == "enable" ]]; then
    init_manual
    ensure_module_deps threat-ips || exit "${ERROR_DEPENDENCY}"
    check_services || exit "${ERROR_GENERAL}"
    validate_zone
    enable_auto_update
    exit $?
  fi
  if [[ "${1:-}" == "disable" ]]; then
    disable_auto_update
    exit $?
  fi

  if ! [[ "${MAX_IP_LIMIT}" =~ ^[0-9]+$ ]]; then
    log_error "无效 MAX_IP_LIMIT：${MAX_IP_LIMIT}"
    exit "${ERROR_GENERAL}"
  fi

  if [[ "${DEBNAS_CRON_MODE:-0}" -eq 0 ]]; then
    init_manual
    local -a items=("启用威胁封禁" "禁用威胁封禁" "定时设置")
    local choice menu_result
    while true; do
      display_threat_status
      menu_result=$(mktemp)
      # ui_menu 非零（254 Esc / 255 Q 等）均退出模块
      UI_MENU_BLANK_BEFORE=1 UI_MENU_BACK_LABEL="← 返回上级" UI_MENU_RESULT_FILE="$menu_result" ui_menu "威胁 IP 封禁" "${items[@]}" || {
        rm -f "$menu_result"
        mark_normal_exit
        return 0
      }
      choice=$(cat "$menu_result")
      rm -f "$menu_result"
      # 单项操作失败（如依赖/服务检查未通过）只提示，不让 set -e 退出整个工具
      _handle_threat_action "$choice" || true
      sleep 1
    done
  else
    init_cron || exit "${ERROR_GENERAL}"
    validate_zone
    update_threat_ips
    mark_normal_exit
  fi
}

# 契约守卫：DEBNAS_MODULE_ACTION=status|plan 时只加载函数供只读探测，不执行 main（docs/ARCHITECTURE.md §4.5）
if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi
