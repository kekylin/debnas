#!/bin/bash
# @module: firewall
# @name: 配置防火墙
# @category: 安全防护
# @depends:
# @version: 1.0.0
# @order: 41
# 功能：安装 firewalld 防火墙服务

set -euo pipefail
IFS=$'\n\t'

# 加载公共模块，确保依赖函数和常量可用
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/bootstrap.sh"

# 检测 sshd 实际监听端口：firewalld 的 ssh 服务只含 22，自定义端口必须单独放行，否则会被锁在门外
get_sshd_ports() {
  local ports="" cfg
  local -a cfgs=()
  if command -v sshd &> /dev/null; then
    ports=$(sshd -T 2>/dev/null | awk '$1 == "port" && $2 ~ /^[0-9]+$/ {print $2}') || ports=""
  fi
  if [[ -z "$ports" ]]; then
    for cfg in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
      [[ -f "$cfg" ]] && cfgs+=("$cfg")
    done
    if [[ ${#cfgs[@]} -gt 0 ]]; then
      ports=$(awk 'tolower($1) == "port" && $2 ~ /^[0-9]+$/ {print $2}' "${cfgs[@]}" 2>/dev/null) || ports=""
    fi
  fi
  # 未显式配置 Port 时 sshd 默认监听 22
  [[ -z "$ports" ]] && ports="22"
  # 当前 SSH 会话所连的服务端端口一并放行（SSH_CONNECTION 末字段）
  local conn_port="${SSH_CONNECTION:-}"
  conn_port="${conn_port##* }"
  if [[ -n "${SSH_CONNECTION:-}" && "$conn_port" =~ ^[0-9]+$ ]]; then
    ports="${ports}"$'\n'"${conn_port}"
  fi
  printf '%s\n' "$ports" | awk 'NF' | sort -un
}

main() {
  
  # 定义配置文件路径，便于后续统一管理
  declare -r CONFIG_FILE="/etc/firewalld/zones/public.xml"
  
  log_info "安装 Firewalld..."
  
  # 禁用 UFW 防火墙，避免冲突
  if command -v ufw &> /dev/null; then
    log_warning "检测到 UFW，已停用"
    service_ensure ufw stopped
    service_ensure ufw disabled
    log_info "UFW 已禁用"
  fi

  # 需要放行的服务与端口
  local -a services=(ssh dhcpv6-client cockpit)
  local -a ports=()
  local port
  for port in $(get_sshd_ports); do
    if [[ "$port" != "22" ]]; then
      ports+=("$port")
      log_info "检测到 SSH 监听端口 ${port}，将一并放行"
    fi
  done
  # NAS 共享服务：已安装才放行，避免防火墙启用后共享被挡
  if service_is_installed smbd; then
    services+=(samba)
  fi
  if service_is_installed nfs-server; then
    services+=(nfs mountd rpc-bind)
  fi

  local -a zone_entries=()
  local svc
  for svc in "${services[@]}"; do
    zone_entries+=("<service name=\"${svc}\"/>")
  done
  for port in "${ports[@]}"; do
    zone_entries+=("<port protocol=\"tcp\" port=\"${port}\"/>")
  done

  # 配置 firewalld 防火墙规则，确保基础服务可用
  # 必须在安装之前写好：Debian 安装 firewalld 后会立即启动，先写配置才不会在启动瞬间挡掉自定义 SSH 端口
  local entry entries_xml=""
  for entry in "${zone_entries[@]}"; do
    entries_xml+="  ${entry}"$'\n'
  done
  firewall_config='<?xml version="1.0" encoding="utf-8"?>
<zone>
  <short>Public</short>
  <description>For use in public areas. You do not trust the other computers on networks to not harm your computer. Only selected incoming connections are accepted.</description>
'"${entries_xml}"'  <forward/>
</zone>'
  # 上方模板展开后包含 <service name="ssh"/>、<service name="dhcpv6-client"/>、<service name="cockpit"/>

  local config_changed=0
  if [ ! -f "$CONFIG_FILE" ]; then
    log_info "配置防火墙规则..."
    if write_file_if_changed "$CONFIG_FILE" "$firewall_config"; then
      config_changed=1
    fi
  else
    # 如已存在，检查并补充 cockpit 配置（插到 </zone> 之前，不依赖 <forward/> 是否存在）
    if ! grep -q '<service name="cockpit"/>' "$CONFIG_FILE"; then
      log_info "添加 cockpit 服务配置..."
      sed -i '/<\/zone>/i \  <service name="cockpit"/>' "$CONFIG_FILE"
      config_changed=1
    fi
    # 补充自定义 SSH 端口与已安装的共享服务
    for entry in "${zone_entries[@]}"; do
      # dhcpv6-client 属于默认项，用户可能有意删除，不强行补回
      [[ "$entry" == *'"dhcpv6-client"'* ]] && continue
      if ! grep -qF "$entry" "$CONFIG_FILE"; then
        log_info "添加防火墙规则：${entry}"
        sed -i "/<\/zone>/i \  ${entry}" "$CONFIG_FILE"
        config_changed=1
      fi
    done
  fi

  # 安装 firewalld，保障系统安全
  local was_active=0
  if service_is_active firewalld; then
    was_active=1
  fi
  apt_install_packages firewalld

  # 已在运行时把新增规则同步到运行时配置；不用 --reload，避免清掉 fail2ban 的运行时规则
  if [[ $config_changed -eq 1 && $was_active -eq 1 ]] && command -v firewall-cmd &> /dev/null; then
    for svc in "${services[@]}"; do
      firewall-cmd --zone=public --query-service="$svc" &> /dev/null \
        || firewall-cmd --zone=public --add-service="$svc" &> /dev/null \
        || log_warning "运行时放行服务 ${svc} 失败（重启 firewalld 后生效）"
    done
    for port in "${ports[@]}"; do
      firewall-cmd --zone=public --query-port="${port}/tcp" &> /dev/null \
        || firewall-cmd --zone=public --add-port="${port}/tcp" &> /dev/null \
        || log_warning "运行时放行端口 ${port}/tcp 失败（重启 firewalld 后生效）"
    done
  fi
  
  # 启动并启用 firewalld 服务
  service_ensure firewalld started
  service_ensure firewalld enabled
  log_success "Firewalld 就绪"
  
  
}

main "$@"
