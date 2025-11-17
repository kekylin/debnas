#!/bin/bash
# 功能：安装并配置服务状态查询工具

set -euo pipefail
IFS=$'\n\t'

# 加载公共模块，确保依赖函数和常量可用
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/core/constants.sh"
source "${SCRIPT_DIR}/lib/core/logging.sh"
source "${SCRIPT_DIR}/lib/system/dependency.sh"
source "${SCRIPT_DIR}/lib/ui/styles.sh"

# 检查 systemctl、hostname、awk、dpkg 依赖，确保后续操作可用
REQUIRED_CMDS=(systemctl hostname awk dpkg)
if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
  log_info "检测到部分依赖未安装，尝试自动安装..."
  install_missing_dependencies "${REQUIRED_CMDS[@]}"
  if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
    log_error "缺少必要系统工具，请先手动安装。"
    exit "${ERROR_DEPENDENCY}"
  fi
fi

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
    systemctl start cockpit >/dev/null 2>&1
  fi
  if is_service_active cockpit; then
    print_service_status "cockpit" "https://${host_ip}:9090"
  fi
}

# 检查 Docker 容器模块，列出正在运行的容器及其访问地址
check_docker_containers() {
  local host_ip="$1"
  declare -A docker_containers=(
    ["dockge"]="http://${host_ip}:5001"
    ["portainer"]="https://${host_ip}:9443"
  )

  for container in "${!docker_containers[@]}"; do
    if docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null | grep -q "true"; then
      print_service_status "$container" "${docker_containers[$container]}"
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
    log_info "Fail2ban 服务已安装，连续登录失败 5 次将封禁访问 IP 1 小时。"
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

main
