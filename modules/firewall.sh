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

# ==================== 只读探测契约（docs/ARCHITECTURE.md §4.5） ====================

# 当前状态：一行 "状态码|说明"（只读、不联网）
module_status() {
  local cfg="/etc/firewalld/zones/public.xml"
  if ! pkg_is_installed firewalld; then
    if command -v ufw &>/dev/null && service_is_active ufw; then
      echo "absent|未安装；UFW 运行中，安装时会停用 UFW"
    else
      echo "absent|未安装 firewalld"
    fi
    return 0
  fi
  if ! service_is_active firewalld; then
    echo "warn|已安装但 firewalld 未运行"
    return 0
  fi
  if [[ -r "$cfg" ]] && ! grep -q '<service name="cockpit"/>' "$cfg" 2>/dev/null; then
    echo "partial|运行中 · public 区未放行 cockpit"
    return 0
  fi
  echo "running|运行中 · public 区已放行 ssh/cockpit"
}

# 预演：每行 "类型|目标|备注"（只读，与 main 的判断逻辑保持一致）
module_plan() {
  local IFS=$' \n\t'
  local cfg="/etc/firewalld/zones/public.xml"
  local -a services=(ssh dhcpv6-client cockpit) ports=() missing=()
  local port svc

  if pkg_is_installed firewalld; then
    echo "info|firewalld|已安装，跳过安装"
  else
    echo "pkg|firewalld|apt 安装（Debian 安装后立即启动）"
  fi
  if command -v ufw &>/dev/null; then
    echo "service|ufw|停用并取消开机自启（避免与 firewalld 冲突）"
    echo "risk|UFW|现有 UFW 规则将不再生效"
  fi

  # firewalld 的 ssh 服务只含 22，自定义端口必须单独放行（含当前会话端口），否则会被锁在门外
  for port in $(sshd_listen_ports); do
    [[ "$port" != "22" ]] && ports+=("$port")
  done
  service_is_installed smbd && services+=(samba)
  service_is_installed nfs-server && services+=(nfs mountd rpc-bind)

  if [[ ! -f "$cfg" ]]; then
    echo "write|${cfg}|新建 public 区（放行 ${services[*]}${ports[*]:+ 及端口 ${ports[*]}}）"
  else
    grep -q '<service name="cockpit"/>' "$cfg" 2>/dev/null || missing+=("cockpit")
    for svc in "${services[@]}"; do
      [[ "$svc" == "dhcpv6-client" || "$svc" == "cockpit" ]] && continue
      grep -qF "<service name=\"${svc}\"/>" "$cfg" 2>/dev/null || missing+=("$svc")
    done
    for port in "${ports[@]}"; do
      grep -qF "<port protocol=\"tcp\" port=\"${port}\"/>" "$cfg" 2>/dev/null || missing+=("${port}/tcp")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
      echo "write|${cfg}|追加 ${missing[*]}（sed -i 原地修改，不另做备份）"
    else
      echo "info|${cfg}|规则已齐全，不改动"
    fi
  fi
  for port in "${ports[@]}"; do
    echo "port|${port}/tcp|放行自定义 SSH 端口"
  done
  echo "port|${services[*]}|public 区放行服务（cockpit=9090）"

  if service_is_active firewalld; then
    echo "service|firewalld|已运行：新规则仅追加到运行时（不 reload，保留 fail2ban 规则）"
  else
    echo "service|firewalld|启动并设为开机自启"
  fi

  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    local conn_ip="${SSH_CONNECTION%% *}" conn_port="${SSH_CONNECTION##* }"
    echo "risk|SSH|当前连接来自 ${conn_ip}，服务端端口 ${conn_port} 在放行列表内，不会断连"
  fi
  echo "risk|入站|启用后 public 区未放行的入站端口将被拦截（其他自建服务需另行放行）"
}

main() {
  # 定义配置文件路径，便于后续统一管理
  local -r CONFIG_FILE="/etc/firewalld/zones/public.xml"
  
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
  for port in $(sshd_listen_ports); do
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
  local entry entries_xml="" firewall_config
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
  if [[ ! -f "$CONFIG_FILE" ]]; then
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

# 契约守卫：DEBNAS_MODULE_ACTION=status|plan 时只加载函数供只读探测，不执行 main（docs/ARCHITECTURE.md §4.5）
if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi
