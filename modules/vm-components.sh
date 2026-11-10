#!/bin/bash
# @module: vm-components
# @name: 安装虚拟机组件
# @category: 管理面板
# @depends:
# @depend_modules: cockpit
# @version: 1.0.0
# @order: 33
# 功能：安装虚拟机管理组件

set -euo pipefail
IFS=$'\n\t'

# 加载公共模块
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/bootstrap.sh"

# ==================== 只读探测契约（docs/ARCHITECTURE.md §4.5） ====================

VM_PINNING_FILE="/etc/apt/preferences.d/cockpit-backports.pref"
VM_SYSCTL_CONF="/etc/sysctl.d/10-debnas-network.conf"

# 排序在 10-debnas-network.conf 之后、把 ip_forward 设为 0 的 sysctl.d 片段（每行一个；只读）
# 说明：这些片段重启后会覆盖本模块配置；/etc/sysctl.conf 的软链接（99-sysctl.conf）由调用方单独处理
_vm_ip_forward_overrides() {
  local f sysctl_real
  sysctl_real=$(readlink -f /etc/sysctl.conf 2>/dev/null) || sysctl_real=""
  for f in /etc/sysctl.d/*.conf; do
    [[ -f "$f" ]] || continue
    [[ "${f##*/}" > "10-debnas-network.conf" ]] || continue
    [[ "$(readlink -f "$f")" == "$sysctl_real" ]] && continue
    if grep -Eq '^[[:space:]]*net\.ipv4\.ip_forward[[:space:]]*=[[:space:]]*0' "$f" 2>/dev/null; then
      printf '%s\n' "$f"
    fi
  done
}

# libvirtd 是否在运行（Debian 为 socket 激活，空闲时 service 未运行而 socket 监听属正常）
_vm_libvirtd_active() {
  systemctl is-active --quiet libvirtd.service 2>/dev/null \
    || systemctl is-active --quiet libvirtd.socket 2>/dev/null
}

# 当前 net.ipv4.ip_forward 运行值（读不到输出空）
_vm_ip_forward() {
  local v=""
  [[ -r /proc/sys/net/ipv4/ip_forward ]] && v=$(< /proc/sys/net/ipv4/ip_forward)
  printf '%s' "${v//[[:space:]]/}"
}

# 当前状态：一行 "状态码|说明"
module_status() {
  local fwd
  fwd=$(_vm_ip_forward)
  if ! pkg_is_installed cockpit-machines; then
    echo "absent|未安装 cockpit-machines（ip_forward=${fwd:-?}）"
    return 0
  fi
  if ! _vm_libvirtd_active; then
    echo "warn|cockpit-machines 已安装，libvirtd 未运行（ip_forward=${fwd:-?}）"
  elif [[ "$fwd" != "1" ]]; then
    echo "partial|libvirtd 运行中，IP 转发未开启（ip_forward=${fwd:-?}）"
  else
    echo "running|libvirtd 运行中 · ip_forward=1"
  fi
}

# 预演：每行 "类型|目标|备注"
module_plan() {
  local IFS=$' \n\t'
  local f fwd

  if ! pinning_file_exists "$VM_PINNING_FILE"; then
    echo "write|${VM_PINNING_FILE}|新建 cockpit/pcp/tuned 的 backports 优先级（仅文件不存在时写入），随后 apt update"
  fi
  if pkg_is_installed cockpit-machines; then
    echo "info|cockpit-machines|已安装，跳过安装"
  else
    echo "pkg|cockpit-machines|apt 安装（连带 libvirt/qemu 等依赖，libvirtd 随包启用）"
  fi

  if [[ -r /etc/sysctl.conf ]] && grep -Eq '^[[:space:]]*net\.ipv4\.ip_forward[[:space:]]*=' /etc/sysctl.conf 2>/dev/null; then
    echo "write|/etc/sysctl.conf|注释其中生效的 net.ipv4.ip_forward 行（原件备份到 /var/backups/debnas/）"
  fi
  if [[ ! -r "$VM_SYSCTL_CONF" ]] || ! grep -qxF 'net.ipv4.ip_forward = 1' "$VM_SYSCTL_CONF" 2>/dev/null; then
    echo "write|${VM_SYSCTL_CONF}|写入 net.ipv4.ip_forward = 1（经 sysctl_persist；已有文件时原件备份到 /var/backups/debnas/）"
  fi
  fwd=$(_vm_ip_forward)
  if [[ "$fwd" != "1" ]]; then
    echo "info|sysctl|立即生效 net.ipv4.ip_forward=1"
    echo "risk|IP 转发|开启 IPv4 转发（虚拟机 NAT 网络需要），主机将可在网卡间转发流量"
  fi
  while IFS= read -r f; do
    echo "risk|${f}|该文件把 ip_forward 设为 0，重启后会覆盖本模块配置（模块只告警不修改）"
  done < <(_vm_ip_forward_overrides)
  echo "service|cockpit|重启使新组件生效（Cockpit 网页会话需重新登录）"
  return 0
}

main() {
  # 获取系统版本代号
  local codename
  codename=$(get_system_codename) || codename=""
  [[ -n "$codename" ]] || exit "${ERROR_GENERAL}"

  # 检查并配置 Cockpit Pinning（文件不存在时才写入）
  if ! pinning_file_exists "$VM_PINNING_FILE"; then
    log_info "配置 Cockpit Pinning..."
    if ! configure_cockpit_pinning "$codename"; then
      log_error "Cockpit APT Pinning 配置失败。"
      exit "${ERROR_GENERAL}"
    fi

    # 应用 APT Pinning 配置
    if ! apply_pinning_config; then
      log_error "APT Pinning 配置应用失败。"
      exit "${ERROR_GENERAL}"
    fi
  fi

  # 安装 cockpit-machines 组件（智能过滤已安装包）
  log_info "安装 cockpit-machines 组件..."
  if ! apt_install_packages cockpit-machines; then
    log_error "cockpit-machines 组件安装失败。"
    exit "${ERROR_GENERAL}"
  fi

  # 启用 IP 包转发功能（幂等）
  log_info "启用 IP 包转发功能..."

  # 注释 /etc/sysctl.conf 中的生效配置
  # 说明：Debian 上 /etc/sysctl.conf 经 /etc/sysctl.d/99-sysctl.conf 最后加载，
  # 其中的 ip_forward 会覆盖 10-debnas-network.conf。原逻辑在文件中已有任意一行
  # 注释掉的 ip_forward 时直接跳过，导致同文件中生效的那一行被保留；
  # 现无条件注释所有生效行（sed 对已注释行不匹配，幂等）。
  local sysctl_conf="/etc/sysctl.conf" f
  if [[ -f "$sysctl_conf" ]] && grep -Eq '^[[:space:]]*net\.ipv4\.ip_forward[[:space:]]*=' "$sysctl_conf"; then
    # 读出 → 内存中改 → write_file_if_changed 写回（原件备份到 /var/backups/debnas、原子替换、登记文件清单）
    local sysctl_content sysctl_new sysctl_rc=0
    sysctl_content=$(cat -- "$sysctl_conf" 2>/dev/null) || sysctl_content=""
    sysctl_new=$(sed -E 's|^([[:space:]]*)net\.ipv4\.ip_forward[[:space:]]*=[[:space:]]*|\1# net.ipv4.ip_forward = |' <<< "$sysctl_content" 2>/dev/null) || sysctl_new="$sysctl_content"
    [[ -z "$sysctl_new" ]] || write_file_if_changed "$sysctl_conf" "$sysctl_new" "" 1 || sysctl_rc=$?
    if [[ "$sysctl_rc" -eq 2 ]]; then
      log_warning "注释 ${sysctl_conf} 中的 net.ipv4.ip_forward 失败，请手动处理"
    fi
  fi

  # 提示：其他排序在后的 sysctl.d 片段若把 ip_forward 设为 0，重启后仍会覆盖
  while IFS= read -r f; do
    log_warning "${f} 将 net.ipv4.ip_forward 设为 0，重启后会覆盖本模块配置，请手动处理"
  done < <(_vm_ip_forward_overrides)

  # 使用 sysctl_persist 实现幂等 sysctl 配置（写入 10-debnas-network.conf）
  if sysctl_persist "net.ipv4.ip_forward" "1" "10-debnas-network.conf"; then
    log_success "IP 包转发功能已启用。"
  else
    log_warning "IP 包转发配置已写入，但应用失败，请手动执行：systemctl restart systemd-sysctl.service"
  fi

  # 重启 cockpit 服务使新组件生效
  if service_ensure "cockpit" "restarted"; then
    log_success "虚拟机组件 就绪"
  else
    log_warning "cockpit 服务重启失败，但虚拟机组件已安装。"
  fi
}

# 契约守卫：DEBNAS_MODULE_ACTION=status|plan 时只加载函数供只读探测，不执行 main（docs/ARCHITECTURE.md §4.5）
if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi
