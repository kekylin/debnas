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

# 与 main 相同的静态/手动网卡检测（lo、DHCP、SLAAC 除外）；输出 "文件: iface 行"，每行一条
_cnet_static_ifaces() {
  local -a files=("$_CNET_IFACES_FILE")
  local f
  [[ -f "$_CNET_IFACES_FILE" ]] || return 0
  for f in /etc/network/interfaces.d/*; do
    [[ -f "$f" ]] && files+=("$f")
  done
  awk '$1 == "iface" && $2 != "lo" && ($3 == "inet" || $3 == "inet6") \
    && $4 != "dhcp" && $4 != "auto" && $4 != "loopback" {print FILENAME ": " $0}' \
    "${files[@]}" 2>/dev/null || true
}

# ifupdown 中仍配置的非 lo 网卡（逗号分隔，去重）
_cnet_ifupdown_ifaces() {
  local -a files=()
  local f
  for f in "$_CNET_IFACES_FILE" /etc/network/interfaces.d/*; do
    [[ -f "$f" && -r "$f" ]] && files+=("$f")
  done
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
  static=$(_cnet_static_ifaces)
  if [[ -n "$static" ]]; then
    local first="${static%%$'\n'*}"
    echo "warn|ifupdown 有静态/手动网卡配置（${first##*: }），执行会拒绝切换"
    return 0
  fi
  local ifaces
  active=$(_cnet_ifupdown_active_lines)
  ifaces=$(_cnet_ifupdown_ifaces)
  _cnet_nm_managed && managed=1
  if ! systemctl is-active --quiet NetworkManager 2>/dev/null; then
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
  static=$(_cnet_static_ifaces)
  if [[ -n "$static" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] && echo "risk|${line%%: *}|静态/手动配置 ${line#*: }：执行将拒绝切换并报错退出，不做任何变更"
    done <<< "$static"
    echo "info|处理方法|先用 nmcli 或 Cockpit 建立等价静态连接，移除 ifupdown 配置后再运行"
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
source "${SCRIPT_DIR}/lib/system/state.sh"

# 检查 sed、systemctl 依赖，确保后续操作可用
REQUIRED_CMDS=(sed systemctl)
if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
  log_error "缺少 sed 或 systemctl，请先手动安装。"
  exit "${ERROR_DEPENDENCY}"
fi

# 设置 Cockpit 接管网络配置，将网络管理工具由 network 切换为 NetworkManager
interfaces_file="/etc/network/interfaces"
nm_conf_file="/etc/NetworkManager/NetworkManager.conf"
config_changed=0

log_info "配置 Cockpit 网络..."

# 先确认 NetworkManager 已安装：否则注释掉 interfaces 后无人接管网络，重启即失联
if ! command -v nmcli &>/dev/null && ! systemctl list-unit-files NetworkManager.service &>/dev/null; then
  log_warning "NetworkManager 未安装，未做任何网络配置变更"
  exit 0
fi

# 检测 ifupdown 中的静态/手动网卡配置（lo、DHCP、SLAAC 除外）
# 这类配置被注释后 NetworkManager 只会按 DHCP 接管，静态 IP 丢失导致远程失联，因此拒绝自动切换
ifupdown_files=("$interfaces_file")
for f in /etc/network/interfaces.d/*; do
  [[ -f "$f" ]] && ifupdown_files+=("$f")
done
static_ifaces=""
if [[ -f "$interfaces_file" ]]; then
  static_ifaces=$(awk '$1 == "iface" && $2 != "lo" && ($3 == "inet" || $3 == "inet6") \
    && $4 != "dhcp" && $4 != "auto" && $4 != "loopback" {print FILENAME ": " $0}' \
    "${ifupdown_files[@]}" 2>/dev/null) || static_ifaces=""
fi
if [[ -n "$static_ifaces" ]]; then
  log_error "检测到 ifupdown 静态/手动网卡配置，自动切换到 NetworkManager 会丢失静态 IP 并导致失联，已中止："
  while IFS= read -r line; do
    log_error "  ${line}"
  done <<< "$static_ifaces"
  log_info "请先用 nmcli（如 nmcli con add type ethernet ifname <网卡> ipv4.method manual ipv4.addresses <IP/掩码> ipv4.gateway <网关> ipv4.dns <DNS>）"
  log_info "或在 Cockpit 中建立等价连接，再移除上述 ifupdown 配置后重新运行本模块。"
  exit "${ERROR_GENERAL}"
fi

# 注释 /etc/network/interfaces 中的内容，避免与 NetworkManager 冲突
if [[ -f "$interfaces_file" ]]; then
  current_interfaces=$(cat "$interfaces_file")
  commented_interfaces=$(echo "$current_interfaces" | sed '/^[^#]/ s/^/#/')
  if write_file_if_changed "$interfaces_file" "$commented_interfaces"; then
    config_changed=1
    log_success "已注释 $interfaces_file 中的配置。"
  else
    log_info "$interfaces_file 无需变更。"
  fi
else
  log_warning "文件 '$interfaces_file' 不存在，跳过操作。"
fi

# 修改 NetworkManager 配置文件，确保 managed=true
if [[ -f "$nm_conf_file" ]]; then
  current_nm_config=$(cat "$nm_conf_file")
  if ! echo "$current_nm_config" | grep -q '^\[ifupdown\]'; then
    new_nm_config="$current_nm_config

[ifupdown]
managed=true"
    log_info "已添加 [ifupdown] 配置段。"
  else
    # 移除 [ifupdown] 段中的 managed= 行，然后重新插入
    new_nm_config=$(echo "$current_nm_config" | sed '/^\[ifupdown\]/,/^\[/ {/^[ifupdown]/!{/^managed=/d}}' | sed '/^\[ifupdown\]/a managed=true')
  fi
  if write_file_if_changed "$nm_conf_file" "$new_nm_config"; then
    config_changed=1
  fi
else
  log_warning "文件 '$nm_conf_file' 不存在，跳过操作。"
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
