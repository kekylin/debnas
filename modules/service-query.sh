#!/bin/bash
# @module: service-query
# @name: 查询服务状态
# @category: 系统维护
# @depends:
# @depend_modules: cockpit
# @version: 1.0.0
# @order: 72
# 功能：安装并配置服务状态查询工具

set -euo pipefail
IFS=$'\n\t'

# 加载公共模块，确保依赖函数和常量可用
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/bootstrap.sh"
source "${SCRIPT_DIR}/lib/system/state.sh"

# 依赖由 module-runner preflight 自动检测（@depends 元数据）

# 检查指定服务是否处于激活状态，便于后续判断
is_service_active() {
  local svc="$1.service"
  if systemctl is-active --quiet "$svc"; then
    return 0
  else
    return 1
  fi
}

# 打印服务已运行的状态信息和访问地址
print_service_status() {
  log_success "$1 服务已运行。"
  log_info "请通过浏览器访问：$2"
}

# 检查系统服务模块，仅处理 cockpit 服务，如未运行则尝试启动
check_system_services() {
  local host_ip="$1"
  if ! is_service_active cockpit; then
    service_ensure cockpit started
  fi
  if is_service_active cockpit; then
    print_service_status "cockpit" "https://${host_ip}:9090"
  fi
}

# 检查 Docker 容器模块，自动发现 compose 目录下声明了 @web_port 的容器
check_docker_containers() {
  local host_ip="$1"
  local compose_dir="${SCRIPT_DIR}/compose"

  [[ -d "$compose_dir" ]] || return 0

  local yaml_file key web_port
  for yaml_file in "$compose_dir"/*.yaml "$compose_dir"/*.yml; do
    [[ -f "$yaml_file" ]] || continue
    key=$(basename "$yaml_file" | sed 's/\.\(yaml\|yml\)$//')
    # 提取 Web 访问端口（可选元数据），无声明则跳过（非 Web 容器）
    web_port=$(grep -m1 '^# *@web_port:' "$yaml_file" 2>/dev/null | sed 's/^# *@web_port: *//' || true)
    [[ -n "$web_port" ]] || continue

    if docker inspect -f '{{.State.Running}}' "$key" 2>/dev/null | grep -q "true"; then
      print_service_status "$key" "https://${host_ip}:${web_port}"
    fi
  done
}

# 检查指定软件包是否已安装
is_package_installed() {
  local pkg="$1"
  dpkg -s "$pkg" >/dev/null 2>&1 && return 0 || return 1
}

# 显示 firewalld 和 fail2ban 的安装状态提示
display_firewalld_fail2ban_info() {
  local firewalld_installed=$(is_package_installed firewalld && echo "yes" || echo "no")
  local fail2ban_installed=$(is_package_installed fail2ban && echo "yes" || echo "no")

  if [[ "$firewalld_installed" == "yes" ]]; then
    log_info "Firewalld 防火墙服务已安装，请确保已放行必要端口。"
  fi
  if [[ "$fail2ban_installed" == "yes" ]]; then
    log_info "Fail2ban 服务已安装，登录失败达到阈值后将自动封禁访问 IP。"
  fi
}

# 主执行流程，串联各功能模块
main() {
  # 获取主机 IP 地址
  host_ip=$(hostname -I | awk '{print $1}')

  # 检查并显示系统服务状态
  check_system_services "$host_ip"

  # 检查 docker 服务是否活跃，如活跃则检查 Docker 容器状态
  if is_service_active docker; then
    check_docker_containers "$host_ip"
  fi

  # 显示 firewalld 和 fail2ban 的提示信息
  display_firewalld_fail2ban_info
}

main "$@"
