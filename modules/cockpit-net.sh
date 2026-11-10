#!/bin/bash
# @module: cockpit-net
# @name: 网络管理器
# @category: 管理面板
# @depends:
# @depend_modules: cockpit
# @version: 1.0.0
# @order: 34
# 功能：设置 Cockpit 管理网络

set -euo pipefail
IFS=$'\n\t'

# 加载公共模块，确保依赖函数和常量可用
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/bootstrap.sh"

# ==================== 只读探测契约（docs/ARCHITECTURE.md §4.5） ====================

_CNET_IFACES_FILE="/etc/network/interfaces"
_CNET_NM_CONF="/etc/NetworkManager/NetworkManager.conf"
_CNET_NETWORKD_DIR="/etc/systemd/network"
_CNET_NETPLAN_DIR="/etc/netplan"

# 递归列出 ifupdown 配置文件：/etc/network/interfaces 及其 source / source-directory 引入的文件（去重、防循环）
# 相对路径按所在文件的目录解析；source-directory 只取文件名匹配 ^[a-zA-Z0-9_-]+$ 的文件（与 ifupdown 一致）
# 输出：文件路径，每行一个
_cnet_ifupdown_files() {
  local start="$_CNET_IFACES_FILE"
  local -a queue=() out=()
  local -A seen=()
  local f kw arg base dir sub line i=0
  [[ -f "$start" ]] || return 0
  queue=("$start")
  while (( i < ${#queue[@]} && i < 256 )); do
    f="${queue[i]}"
    ((i++)) || true
    [[ -f "$f" && -r "$f" && -z "${seen[$f]:-}" ]] || continue
    seen["$f"]=1
    out+=("$f")
    base="${f%/*}"
    while IFS=$' \t' read -r kw arg _ || [[ -n "$kw" ]]; do
      [[ "$kw" == "source" || "$kw" == "source-directory" ]] || continue
      [[ -n "$arg" ]] || continue
      [[ "$arg" == /* ]] || arg="${base}/${arg}"
      if [[ "$kw" == "source" ]]; then
        # source 支持 shell 通配
        for sub in $arg; do
          [[ -f "$sub" ]] && queue+=("$sub")
        done
      else
        for dir in $arg; do
          [[ -d "$dir" ]] || continue
          for sub in "$dir"/*; do
            line="${sub##*/}"
            [[ -f "$sub" && "$line" =~ ^[a-zA-Z0-9_-]+$ ]] && queue+=("$sub")
          done
        done
      fi
    done < "$f"
  done
  [[ ${#out[@]} -gt 0 ]] && printf '%s\n' "${out[@]}"
  return 0
}

# 与 main 相同的阻断检测（ifupdown 部分）：输出 "文件: 行"，每行一条
# - 静态/手动网卡（lo、DHCP、SLAAC 除外）：注释后 NM 只会按 DHCP 接管，静态 IP 丢失
# - 网桥/绑定/VLAN/无线认证/钩子脚本指令（bridge_ports、bond-*、vlan-raw-device、wpa-*、pre-up、up 等）：NM 无法等价接管
_cnet_static_ifaces() {
  local -a files=()
  mapfile -t files < <(_cnet_ifupdown_files)
  [[ ${#files[@]} -gt 0 ]] || return 0
  awk '
    { line = $0; sub(/^[[:space:]]+/, "", line) }
    line == "" || line ~ /^#/ { next }
    $1 == "iface" && $2 != "lo" && ($3 == "inet" || $3 == "inet6") \
      && $4 != "dhcp" && $4 != "auto" && $4 != "loopback" { print FILENAME ": " line; next }
    $1 ~ /^(bridge[-_]ports|bond[-_].+|vlan[-_]raw[-_]device|wpa[-_].+|pre-up|up|post-up|down|pre-down|post-down)$/ { print FILENAME ": " line }
  ' "${files[@]}" 2>/dev/null || true
}

# 由其他网络管理器（systemd-networkd / netplan）负责的配置：输出 "路径: 说明"，每行一条
# 这类系统（如云镜像）切换后 NM 与 networkd 会同时管理同一网卡，出现双 DHCP/地址冲突
_cnet_other_managers() {
  local f
  for f in "${_CNET_NETPLAN_DIR}"/*.yaml "${_CNET_NETPLAN_DIR}"/*.yml; do
    [[ -e "$f" ]] && echo "${f}: netplan 配置"
  done
  for f in "${_CNET_NETWORKD_DIR}"/*.network; do
    [[ -e "$f" ]] && echo "${f}: systemd-networkd 配置"
  done
  return 0
}

# 调用 cockpit 模块里"NetworkManager 不接管 systemd-networkd 网卡"的函数（子 shell 中加载，只取函数、不执行其 main）
# 参数：$1 - 函数名（configure_nm_networkd_guard / _cockpit_nm_guard_plan / _cockpit_nm_guard_state）
_cnet_cockpit_call() {
  local mod="${SCRIPT_DIR}/modules/cockpit.sh"
  [[ -r "$mod" ]] || return 0
  (
    DEBNAS_MODULE_ACTION=status
    # shellcheck source=/dev/null
    source "$mod"
    "$1"
  )
}

# 全部阻断项（ifupdown 静态/特殊指令 + netplan/networkd）
_cnet_blockers() {
  _cnet_static_ifaces
  _cnet_other_managers
}

# ifupdown 中仍配置的非 lo 网卡（逗号分隔，去重）
_cnet_ifupdown_ifaces() {
  local -a files=()
  mapfile -t files < <(_cnet_ifupdown_files)
  [[ ${#files[@]} -gt 0 ]] || return 0
  awk '$1 == "iface" && $2 != "lo" && !seen[$2]++ {printf "%s%s", sep, $2; sep = ","}' "${files[@]}" 2>/dev/null || true
}

# /etc/network/interfaces 中仍生效（未注释）的行数
_cnet_ifupdown_active_lines() {
  [[ -r "$_CNET_IFACES_FILE" ]] || { echo 0; return 0; }
  grep -c '^[^#]' "$_CNET_IFACES_FILE" 2>/dev/null || true
}

# NetworkManager.conf 的 [ifupdown] 段是否为 managed=true
_cnet_nm_managed() {
  [[ -r "$_CNET_NM_CONF" ]] || return 1
  awk '/^\[/ { sec = $0; next }
       sec == "[ifupdown]" && /^managed=/ { val = $0 }
       END { exit (val == "managed=true" ? 0 : 1) }' "$_CNET_NM_CONF" 2>/dev/null
}

_cnet_nm_installed() {
  command -v nmcli &>/dev/null || systemctl list-unit-files NetworkManager.service &>/dev/null
}

# 当前状态：一行 "状态码|说明"
module_status() {
  if ! _cnet_nm_installed; then
    echo "absent|未安装 NetworkManager"
    return 0
  fi
  local static active managed=0
  static=$(_cnet_blockers)
  if [[ -n "$static" ]]; then
    local first="${static%%$'\n'*}"
    local guard
    guard=$(_cnet_cockpit_call _cockpit_nm_guard_state 2>/dev/null) || guard=""
    case "${guard%%|*}" in
      conflict | unwritten-conflict)
        echo "warn|网卡 ${guard#*|} 被 NetworkManager 与 systemd-networkd 同时管理（会多出一个 DHCP 地址）；执行本模块不切换，只让 NetworkManager 放开这些网卡"
        return 0
        ;;
    esac
    echo "warn|存在 NetworkManager 无法安全接管的网络配置（${first}），执行时将跳过切换（网络保持原样）"
    return 0
  fi
  local ifaces
  active=$(_cnet_ifupdown_active_lines)
  ifaces=$(_cnet_ifupdown_ifaces)
  _cnet_nm_managed && managed=1
  if ! service_is_active NetworkManager; then
    echo "warn|NetworkManager 未运行"
    return 0
  fi
  if [[ -n "$ifaces" ]]; then
    if [[ $managed -eq 0 ]]; then
      echo "absent|网卡 ${ifaces} 仍由 ifupdown 管理"
    else
      echo "partial|已设 managed=true，但 ifupdown 仍配置网卡 ${ifaces}"
    fi
    return 0
  fi
  # ifupdown 无网卡配置：看实际网卡是否被 NM 接管（nmcli 普通用户可读）
  local unmanaged="" connected="" note=""
  if command -v nmcli &>/dev/null; then
    local dev_lines
    dev_lines=$(timeout 1 nmcli -t -f DEVICE,TYPE,STATE device status 2>/dev/null) || dev_lines=""
    # 只看物理网卡（/sys/class/net/<dev>/device 存在），排除 veth/网桥等虚拟设备
    local dev type state
    while IFS=: read -r dev type state; do
      [[ "$type" == "ethernet" && -e "/sys/class/net/${dev}/device" ]] || continue
      case "$state" in
        unmanaged) unmanaged+="${unmanaged:+,}${dev}" ;;
        connected*) connected+="${connected:+,}${dev}" ;;
      esac
    done <<< "$dev_lines"
  fi
  if [[ -n "$unmanaged" ]]; then
    echo "warn|网卡未被 NetworkManager 管理：${unmanaged}"
    return 0
  fi
  [[ "${active:-0}" -gt 0 ]] && note+=" · interfaces 残留 ${active} 行未注释"
  [[ $managed -eq 0 && -r "$_CNET_NM_CONF" ]] && note+=" · [ifupdown] 未设 managed=true"
  echo "applied|网络由 NetworkManager 管理${connected:+（${connected} 已连接）}${note}"
}

# 预演：每行 "类型|目标|备注"（无副作用；与 main 的判断保持一致）
module_plan() {
  local IFS=$' \n\t'
  if ! _cnet_nm_installed; then
    echo "info|NetworkManager|未安装，执行时不做任何网络配置变更（本模块不负责安装）"
    return 0
  fi
  local static line
  static=$(_cnet_blockers)
  if [[ -n "$static" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] && echo "risk|${line%%: *}|${line#*: }：执行时将告警并跳过切换（不报错、不做任何变更）"
    done <<< "$static"
    echo "info|处理方法|ifupdown 静态/特殊配置：先用 nmcli 或 Cockpit 建立等价连接并移除原配置；netplan/networkd 管理的系统（如云镜像）请勿切换，Cockpit 可直接只读查看网络"
    # netplan/networkd 系统：跳过切换，但会让 NetworkManager 放开 networkd 已管理的网卡
    [[ -z "$(_cnet_other_managers)" ]] || _cnet_cockpit_call _cockpit_nm_guard_plan 2>/dev/null || true
    return 0
  fi
  local changed=0 active
  active=$(_cnet_ifupdown_active_lines)
  if [[ ! -f "$_CNET_IFACES_FILE" ]]; then
    echo "info|${_CNET_IFACES_FILE}|不存在，跳过"
  elif [[ "${active:-0}" -gt 0 ]]; then
    echo "write|${_CNET_IFACES_FILE}|注释全部 ${active} 行生效配置（交由 NetworkManager 接管）；旧文件备份到 /var/backups/debnas/"
    changed=1
  else
    echo "info|${_CNET_IFACES_FILE}|已全部注释（已满足）"
  fi
  if [[ ! -f "$_CNET_NM_CONF" ]]; then
    echo "info|${_CNET_NM_CONF}|不存在，跳过"
  elif _cnet_nm_managed; then
    echo "info|${_CNET_NM_CONF}|[ifupdown] managed=true（已满足）"
  else
    echo "write|${_CNET_NM_CONF}|设置 [ifupdown] managed=true；旧文件备份到 /var/backups/debnas/"
    changed=1
  fi
  if [[ $changed -eq 1 ]]; then
    echo "service|NetworkManager cockpit|配置变更后重启"
    local ifaces
    ifaces=$(_cnet_ifupdown_ifaces)
    echo "risk|网络中断|重启 NetworkManager 时网络短暂中断，SSH 会话可能断开${ifaces:+；网卡 ${ifaces} 改由 NM 以 DHCP 获取地址，IP 可能变化}"
  else
    echo "info|服务|配置均已满足，不重启服务"
  fi
  return 0
}

main() {
  local -a REQUIRED_CMDS=(sed systemctl)
  local config_changed=0 static_ifaces line current new_content

  # 检查 sed、systemctl 依赖，确保后续操作可用
  if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
    log_error "缺少 sed 或 systemctl，请先手动安装。"
    exit "${ERROR_DEPENDENCY}"
  fi

  # 设置 Cockpit 接管网络配置，将网络管理工具由 network 切换为 NetworkManager
  log_info "配置 Cockpit 网络..."

  # 先确认 NetworkManager 已安装：否则注释掉 interfaces 后无人接管网络，重启即失联
  if ! _cnet_nm_installed; then
    log_warning "NetworkManager 未安装，未做任何网络配置变更"
    exit 0
  fi

  # 由 netplan / systemd-networkd 管理网络的系统（如云镜像）：切换后 NM 与 networkd 争抢同一网卡，跳过
  local other_managers
  other_managers=$(_cnet_other_managers)
  if [[ -n "$other_managers" ]]; then
    # 本模块是可选项：不切换不影响任何功能，因此告警后跳过（返回成功），避免一键方案在此中断
    log_warning "检测到本机网络由 netplan / systemd-networkd 管理，切换到 NetworkManager 会与其争抢网卡（双 DHCP、地址冲突甚至失联），已跳过，未做任何变更："
    while IFS= read -r line; do
      log_warning "  ${line}"
    done <<< "$other_managers"
    # 不切换，但 NetworkManager 既已装上就会自己接管这些网卡（多出一个 DHCP 地址）：让它放开 networkd 管理的网卡
    _cnet_cockpit_call configure_nm_networkd_guard || true
    log_info "此类系统无需执行本模块；如确需由 NetworkManager 接管，请先删除 /etc/NetworkManager/conf.d/10-debnas-unmanaged.conf（如有）并 systemctl reload NetworkManager，"
    log_info "再把 netplan 的 renderer 改为 NetworkManager 并 netplan apply，确认网络正常后再运行。"
    exit 0
  fi

  # 检测 ifupdown（含 source / source-directory 引入的文件）中的静态/手动网卡配置（lo、DHCP、SLAAC 除外），
  # 以及网桥/绑定/VLAN/无线认证/钩子脚本等 NM 无法等价接管的指令；注释后 NM 只会按 DHCP 接管，导致远程失联，因此拒绝自动切换
  static_ifaces=$(_cnet_static_ifaces)
  if [[ -n "$static_ifaces" ]]; then
    # 同上：静态 IP 是 NAS 最常见的配置，告警后跳过（返回成功），不中断一键方案；网络保持原样
    log_warning "检测到 ifupdown 静态/手动网卡或网桥/绑定/VLAN/钩子等配置，自动切换到 NetworkManager 会丢失这些配置并导致失联，已跳过，网络配置保持原样："
    while IFS= read -r line; do
      log_warning "  ${line}"
    done <<< "$static_ifaces"
    log_info "请先用 nmcli（如 nmcli con add type ethernet ifname <网卡> ipv4.method manual ipv4.addresses <IP/掩码> ipv4.gateway <网关> ipv4.dns <DNS>）"
    log_info "或在 Cockpit 中建立等价连接，再移除上述 ifupdown 配置后重新运行本模块。"
    exit 0
  fi

  # 注释 /etc/network/interfaces 中的内容，避免与 NetworkManager 冲突
  if [[ -f "$_CNET_IFACES_FILE" ]]; then
    current=$(cat "$_CNET_IFACES_FILE")
    local commented_interfaces
    commented_interfaces=$(sed '/^[^#]/ s/^/#/' <<< "$current")
    if write_file_if_changed "$_CNET_IFACES_FILE" "$commented_interfaces"; then
      config_changed=1
      log_success "已注释 $_CNET_IFACES_FILE 中的配置。"
    else
      log_info "$_CNET_IFACES_FILE 无需变更。"
    fi
  else
    log_warning "文件 '$_CNET_IFACES_FILE' 不存在，跳过操作。"
  fi

  # 修改 NetworkManager 配置文件，确保 [ifupdown] 段 managed=true
  if [[ -f "$_CNET_NM_CONF" ]]; then
    current=$(cat "$_CNET_NM_CONF")
    if ! grep -q '^\[ifupdown\]' <<< "$current"; then
      new_content="$current

[ifupdown]
managed=true"
      log_info "已添加 [ifupdown] 配置段。"
    else
      # 删除 [ifupdown] 段内已有的 managed= 行，再紧跟段头插入 managed=true
      new_content=$(sed '/^\[ifupdown\]/,/^\[/ {/^\[ifupdown\]/!{/^managed=/d}}' <<< "$current" | sed '/^\[ifupdown\]/a managed=true')
    fi
    if write_file_if_changed "$_CNET_NM_CONF" "$new_content"; then
      config_changed=1
    fi
  else
    log_warning "文件 '$_CNET_NM_CONF' 不存在，跳过操作。"
  fi

  # 仅在配置变更时重启服务
  if [[ "$config_changed" -eq 1 ]]; then
    if ! service_ensure "NetworkManager" "restarted"; then
      log_error "NetworkManager 重启失败"
      exit "${ERROR_GENERAL}"
    fi
    log_success "NetworkManager 已重启"

    if service_ensure "cockpit" "restarted"; then
      log_success "Cockpit 网络就绪"
    else
      log_warning "cockpit 服务重启失败，但网络配置已生效。"
    fi
  else
    log_info "配置未变更，跳过服务重启。"
  fi
}

# 契约守卫：DEBNAS_MODULE_ACTION=status|plan 时只加载函数供只读探测，不执行 main（docs/ARCHITECTURE.md §4.5）
if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi
