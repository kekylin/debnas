#!/bin/bash
# @module: bbr
# @name: 配置 BBR 加速
# @category: 系统工具
# @depends:
# @version: 1.0.0
# @order: 76
# @interactive: true
# BBR 拥塞控制算法管理工具

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/bootstrap.sh"

readonly BBR_MODULE="tcp_bbr"
readonly BBR_ALGO="bbr"
readonly DEFAULT_ALGO="cubic"
# 文件名须排在 /usr/lib/sysctl.d/50-default.conf 之后：后者设 net.core.default_qdisc=fq_codel，
# systemd-sysctl 按文件名顺序应用、后者覆盖前者，旧名 11-debnas-bbr.conf 的 fq 每次开机都被改回 fq_codel
readonly SYSCONF_FILE="/etc/sysctl.d/99-debnas-bbr.conf"
readonly LEGACY_SYSCONF_FILE="/etc/sysctl.d/11-debnas-bbr.conf"
readonly SYSCONF_KEY="net.ipv4.tcp_congestion_control"
readonly SYSCONF_QDISC_KEY="net.core.default_qdisc"
readonly QDISC_FQ="fq"
readonly DEFAULT_QDISC="fq_codel"

comment_out_sysctl_conf_key() {
  local key="$1"
  local conf="/etc/sysctl.conf"
  [[ -f "$conf" ]] || return 0

  # 按传入的 key 构造正则（转义 .），严格匹配“带等号”的未注释配置行
  local key_re="${key//./\\.}"
  local key_regex="^[[:space:]]*${key_re}[[:space:]]*="

  # 不存在未注释的同名键则无需处理（已注释的行不影响判断）
  if ! LC_ALL=C grep -qE "$key_regex" "$conf" 2>/dev/null; then
    return 0
  fi

  sed -i -E "s|^([[:space:]]*)(${key_re}[[:space:]]*=.*)$|\\1# \\2|" "$conf" 2>/dev/null || true
  if LC_ALL=C grep -qE "$key_regex" "$conf" 2>/dev/null; then
    log_warning "尝试注释 ${conf} 中的 ${key} 失败"
    return 1
  fi
  log_success "已注释 ${conf} 中的重复配置项：${key}"
  return 0
}

check_current_algo() {
  local current_algo supported_algos current_qdisc
  current_algo=$(sysctl -n "$SYSCONF_KEY" 2>/dev/null || echo "未知")
  supported_algos=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo "未知")
  current_qdisc=$(sysctl -n "$SYSCONF_QDISC_KEY" 2>/dev/null || echo "未知")
  log_info "当前: $current_algo"
  log_info "可用: $supported_algos"
  log_info "当前队列规则：$current_qdisc"
}

load_bbr_module() {
  # 模块已加载（awk 读完全部输入再判断，避免 grep -q 提前退出让 lsmod 收到 SIGPIPE）
  if lsmod 2>/dev/null | awk -v m="$BBR_MODULE" '$1 == m { f = 1 } END { exit !f }'; then
    log_success "BBR 模块已加载"
    return 0
  fi

  # 若可用则加载（兼容 .ko 与 .ko.xz）
  if modinfo "$BBR_MODULE" >/dev/null 2>&1; then
    if modprobe "$BBR_MODULE" >/dev/null 2>&1; then
      log_success "BBR 模块"
      return 0
    fi
  fi

  log_error "BBR 模块不可用"
  return 1
}

temp_enable_bbr() {
  log_info "临时启用 BBR..."
  if ! load_bbr_module; then return 1; fi
  if sysctl -w "${SYSCONF_KEY}"="$BBR_ALGO" >/dev/null 2>&1 && \
     sysctl -w "${SYSCONF_QDISC_KEY}"="$QDISC_FQ" >/dev/null 2>&1; then
    log_success "BBR (临时)"
  else
    log_error "BBR 失败"
    return 1
  fi
}

perm_enable_bbr() {
  log_info "永久启用 BBR..."
  if ! load_bbr_module; then return 1; fi
  if ! sysctl -w "${SYSCONF_KEY}"="$BBR_ALGO" >/dev/null 2>&1; then
    log_error "BBR 失败"
    return 1
  fi
  # 同步设置队列规则为 fq
  sysctl -w "${SYSCONF_QDISC_KEY}"="$QDISC_FQ" >/dev/null 2>&1 || true
  # 注释掉 /etc/sysctl.conf 中的同名键，避免重复配置
  comment_out_sysctl_conf_key "$SYSCONF_KEY" || true
  comment_out_sysctl_conf_key "$SYSCONF_QDISC_KEY" || true
  # 持久化到 /etc/sysctl.d/
  sysctl_persist "$SYSCONF_KEY" "$BBR_ALGO" "${SYSCONF_FILE##*/}"
  sysctl_persist "$SYSCONF_QDISC_KEY" "$QDISC_FQ" "${SYSCONF_FILE##*/}"
  # 迁移：新文件写好后删除旧名配置
  if [[ -f "$LEGACY_SYSCONF_FILE" ]]; then
    rm -f "$LEGACY_SYSCONF_FILE"
    log_info "已迁移旧配置 ${LEGACY_SYSCONF_FILE} → ${SYSCONF_FILE}"
  fi
  if service_ensure systemd-sysctl restarted; then
    log_success "BBR (永久)"
  else
    log_warning "配置已写入 $SYSCONF_FILE，但应用失败；已临时启用 BBR"
  fi
}

temp_disable_bbr() {
  log_info "临时关闭 BBR..."
  if sysctl -w "${SYSCONF_KEY}"="$DEFAULT_ALGO" >/dev/null 2>&1 && \
     sysctl -w "${SYSCONF_QDISC_KEY}"="$DEFAULT_QDISC" >/dev/null 2>&1; then
    log_success "${DEFAULT_ALGO} 已启用"
  else
    log_error "算法切换失败，请检查系统权限。"
    return 1
  fi
}

perm_disable_bbr() {
  log_info "永久关闭 BBR..."
  if ! sysctl -w "${SYSCONF_KEY}"="$DEFAULT_ALGO" >/dev/null 2>&1; then
    log_error "算法切换失败，请检查系统权限。"
    return 1
  fi
  # 恢复默认队列规则
  sysctl -w "${SYSCONF_QDISC_KEY}"="$DEFAULT_QDISC" >/dev/null 2>&1 || true
  # 注释掉 /etc/sysctl.conf 中的同名键，避免旧方式残留导致关闭不彻底
  comment_out_sysctl_conf_key "$SYSCONF_KEY" || true
  comment_out_sysctl_conf_key "$SYSCONF_QDISC_KEY" || true
  # 移除 BBR 专用配置文件（含旧名文件）
  local f
  for f in "$SYSCONF_FILE" "$LEGACY_SYSCONF_FILE"; do
    if [[ -f "$f" ]]; then
      rm -f "$f"
      log_info "已移除 ${f}"
    fi
  done
  if service_ensure systemd-sysctl restarted; then
    log_success "BBR 已关闭"
  else
    log_warning "配置已从 $SYSCONF_FILE 移除，但应用失败；算法已临时切换"
  fi
}

handle_choice() {
  local choice="$1"
  case "$choice" in
    1) temp_enable_bbr || return 1 ;;
    2) perm_enable_bbr || return 1 ;;
    3) temp_disable_bbr || return 1 ;;
    4) perm_disable_bbr || return 1 ;;
    5) check_current_algo || return 1 ;;
    0) log_info "退出 BBR 管理"; return 0 ;;
    *) log_error "无效编号，请重新选择。"; return 1 ;;
  esac
  module_mark_action
}

# ==================== 只读探测契约（docs/ARCHITECTURE.md §4.5） ====================
# 直接读 /proc/sys（普通用户可读），不调 sysctl/modinfo

_bbr_read_proc() {
  local f="/proc/sys/${1//.//}" v=""
  [[ -r "$f" ]] && v=$(< "$f") 2>/dev/null
  printf '%s' "$v"
}

# 内核是否能用 BBR（已在可用列表，或存在 tcp_bbr 内核模块文件）
_bbr_available() {
  local avail
  avail=$(_bbr_read_proc net.ipv4.tcp_available_congestion_control)
  [[ " ${avail} " == *" ${BBR_ALGO} "* ]] && return 0
  compgen -G "/lib/modules/$(uname -r 2>/dev/null)/kernel/net/ipv4/${BBR_MODULE}.ko*" >/dev/null 2>&1
}

# 持久化配置中是否已写入 bbr
# 参数：$1 - 配置文件（可选，默认新文件名）
_bbr_persisted() {
  local f="${1:-$SYSCONF_FILE}"
  [[ -r "$f" ]] && grep -qE "^[[:space:]]*${SYSCONF_KEY//./\\.}[[:space:]]*=[[:space:]]*${BBR_ALGO}[[:space:]]*$" "$f" 2>/dev/null
}

# 当前状态：一行 "状态码|说明"
module_status() {
  local algo qdisc
  algo=$(_bbr_read_proc "$SYSCONF_KEY")
  qdisc=$(_bbr_read_proc "$SYSCONF_QDISC_KEY")
  if [[ -z "$algo" ]]; then
    echo "unknown|无法读取当前拥塞控制算法"
    return 0
  fi
  if [[ "$algo" == "$BBR_ALGO" ]]; then
    if _bbr_persisted; then
      echo "applied|BBR 已启用（队列 ${qdisc:-未知}）· 已持久化"
    elif _bbr_persisted "$LEGACY_SYSCONF_FILE"; then
      echo "partial|BBR 已启用（队列 ${qdisc:-未知}），持久化在旧文件 ${LEGACY_SYSCONF_FILE}（fq 开机会被 50-default.conf 覆盖），重新永久启用即可迁移"
    else
      echo "partial|BBR 临时启用（队列 ${qdisc:-未知}），重启后失效"
    fi
    return 0
  fi
  if _bbr_persisted; then
    echo "warn|已写入 ${SYSCONF_FILE} 但当前算法为 ${algo}（配置未生效）"
  elif ! _bbr_available; then
    echo "absent|当前 ${algo}；内核未提供 BBR 模块"
  else
    echo "absent|当前 ${algo}（队列 ${qdisc:-未知}），未启用 BBR"
  fi
}

# 预演：每行 "类型|目标|备注"（交互式模块：列出各菜单动作可能的影响）
module_plan() {
  local IFS=$' \n\t'
  local algo key dup=""
  algo=$(_bbr_read_proc "$SYSCONF_KEY")
  echo "info|bbr|交互式菜单：临时启用 / 永久启用 / 临时停用 / 永久停用 / 查看状态（当前算法 ${algo:-未知}）；无参数且非终端时只查看状态"
  if ! _bbr_available; then
    echo "risk|${BBR_MODULE}|内核未提供 BBR 模块，启用会失败"
  elif [[ " $(_bbr_read_proc net.ipv4.tcp_available_congestion_control) " != *" ${BBR_ALGO} "* ]]; then
    echo "info|${BBR_MODULE}|启用时 modprobe 加载内核模块"
  fi
  echo "info|sysctl|临时启/停：sysctl -w ${SYSCONF_KEY}=${BBR_ALGO}/${DEFAULT_ALGO}、${SYSCONF_QDISC_KEY}=${QDISC_FQ}/${DEFAULT_QDISC}，重启后失效"
  if _bbr_persisted; then
    echo "info|${SYSCONF_FILE}|已持久化 BBR（永久启用时已满足）；永久停用时删除该文件（不另做备份）"
  else
    echo "write|${SYSCONF_FILE}|永久启用时写入 ${SYSCONF_KEY}/${SYSCONF_QDISC_KEY}（旧文件备份到 /var/backups/debnas/）；永久停用时删除"
  fi
  if [[ -f "$LEGACY_SYSCONF_FILE" ]]; then
    echo "write|${LEGACY_SYSCONF_FILE}|旧名配置（排在 50-default.conf 之前，fq 会被覆盖）：永久启/停时删除，改用 ${SYSCONF_FILE}"
  fi
  for key in "$SYSCONF_KEY" "$SYSCONF_QDISC_KEY"; do
    if [[ -r /etc/sysctl.conf ]] && LC_ALL=C grep -qE "^[[:space:]]*${key//./\\.}[[:space:]]*=" /etc/sysctl.conf 2>/dev/null; then
      dup+="${dup:+、}${key}"
    fi
  done
  [[ -n "$dup" ]] && echo "write|/etc/sysctl.conf|永久启/停时注释掉重复项 ${dup}（sed -i 原地修改，不另做备份）"
  echo "service|systemd-sysctl|永久启/停后重启以应用配置"
  return 0
}

main() {
  if [[ "${DEBNAS_CRON_MODE:-0}" -eq 1 ]]; then
    log_info "cron 模式下不支持交互操作，已跳过"
    return 0
  fi

  # 非交互模式：通过参数指定操作（1=启用临时 2=启用永久 3=禁用临时 4=禁用永久 5=状态）
  if [[ ! -t 0 ]] || [[ -n "${1:-}" ]]; then
    local choice="${1:-5}"
    handle_choice "$choice"
    return $?
  fi

  local -a items=("临时启用 BBR" "永久启用 BBR" "临时停用 BBR" "永久停用 BBR" "查看 BBR 状态")
  local choice menu_result
  while true; do
    menu_result=$(mktemp)
    # ui_menu 非零（254 Esc / 255 Q 等）均退出模块
    UI_MENU_BLANK_BEFORE=1 UI_MENU_RESULT_FILE="$menu_result" ui_menu "配置 BBR 加速" "${items[@]}" || {
      rm -f "$menu_result"
      return 0
    }
    choice=$(cat "$menu_result")
    rm -f "$menu_result"
    # ui_menu 返回 0-based 索引，handle_choice 使用 1-based
    # 单项操作失败只提示，不让 set -e 退出整个菜单
    handle_choice "$((choice + 1))" || true
    echo
  done
}

# 契约守卫：DEBNAS_MODULE_ACTION=status|plan 时只加载函数供只读探测，不执行 main（docs/ARCHITECTURE.md §4.5）
if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi
