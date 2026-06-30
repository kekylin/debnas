#!/bin/bash
# @module: firewall
# @name: 防火墙
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

# 安装 firewalld，保障系统安全
apt_install_packages firewalld

# 配置 firewalld 防火墙规则，确保基础服务可用
firewall_config='<?xml version="1.0" encoding="utf-8"?>
<zone>
  <short>Public</short>
  <description>For use in public areas. You do not trust the other computers on networks to not harm your computer. Only selected incoming connections are accepted.</description>
  <service name="ssh"/>
  <service name="dhcpv6-client"/>
  <service name="cockpit"/>
  <forward/>
</zone>'

if [ ! -f "$CONFIG_FILE" ]; then
  log_info "配置防火墙规则..."
  write_file_if_changed "$CONFIG_FILE" "$firewall_config" || true
else
  # 如已存在，检查并补充 cockpit 配置
  if ! grep -q '<service name="cockpit"/>' "$CONFIG_FILE"; then
    log_info "添加 cockpit 服务配置..."
    sed -i '/<forward\/>/i \  <service name="cockpit"/>' "$CONFIG_FILE"
  fi
fi

# 启动并启用 firewalld 服务
service_ensure firewalld started
service_ensure firewalld enabled
log_success "Firewalld 就绪"


}

main "$@"
