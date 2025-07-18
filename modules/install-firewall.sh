#!/bin/bash
# 功能：安装 firewalld 防火墙服务

set -euo pipefail
IFS=$'\n\t'

# 加载公共模块，确保依赖函数和常量可用
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/core/constants.sh"
source "${SCRIPT_DIR}/lib/core/logging.sh"
source "${SCRIPT_DIR}/lib/system/dependency.sh"

# 检查 apt、systemctl 依赖，确保后续操作可用
REQUIRED_CMDS=(apt systemctl)
if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
  log_error "缺少 apt 或 systemctl，请先手动安装。"
  exit "${ERROR_DEPENDENCY}"
fi

# 定义配置文件路径，便于后续统一管理
declare -r CONFIG_FILE="/etc/firewalld/zones/public.xml"

log_info "开始安装 firewalld 防火墙..."

# 禁用 UFW 防火墙，避免冲突
if command -v ufw &> /dev/null; then
  log_info "检测到 UFW 防火墙，正在停止并禁用..."
  systemctl stop ufw
  systemctl disable ufw
  log_success "UFW 防火墙已停止并禁止开机自启。"
fi

# 安装 firewalld，保障系统安全
log_info "安装 firewalld 防火墙..."
if ! apt update; then
  log_error "apt update 失败。"
  exit "${ERROR_GENERAL}"
fi
if ! apt install firewalld -y; then
  log_error "firewalld 安装失败。"
  exit "${ERROR_GENERAL}"
fi

# 安装完成后，停止 firewalld 服务（不禁用开机自启，便于后续统一管理）
log_info "安装完成，停止 firewalld 服务..."
if systemctl list-unit-files | grep -qw firewalld.service; then
  systemctl stop firewalld
else
  log_warn "firewalld 服务未加载，跳过停止操作。"
fi

# 配置 firewalld 防火墙规则，确保基础服务可用
if [ ! -f "$CONFIG_FILE" ]; then
  log_info "配置 firewalld 防火墙规则..."
  tee "$CONFIG_FILE" > /dev/null <<EOF
<?xml version="1.0" encoding="utf-8"?>
<zone>
  <short>Public</short>
  <description>For use in public areas. You do not trust the other computers on networks to not harm your computer. Only selected incoming connections are accepted.</description>
  <service name="ssh"/>
  <service name="dhcpv6-client"/>
  <service name="cockpit"/>
  <forward/>
</zone>
EOF
else
  # 如已存在，检查并补充 cockpit 配置
  if ! grep -q '<service name="cockpit"/>' "$CONFIG_FILE"; then
    log_info "添加 cockpit 服务配置..."
    sed -i '/<forward\/>/i \  <service name="cockpit"/>' "$CONFIG_FILE"
  fi
fi
