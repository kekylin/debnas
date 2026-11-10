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

# 检查指定服务是否处于激活状态（无后缀时按 .service）
is_service_active() {
  local svc="$1"
  [[ "$svc" == *.* ]] || svc="${svc}.service"
  systemctl is-active --quiet "$svc"
}

# 打印服务已运行的状态信息和访问地址
print_service_status() {
  log_success "$1 服务已运行。"
  log_info "请通过浏览器访问：$2"
}

# 检查系统服务模块，仅查询 cockpit 状态（查询工具不改变系统状态，不自动启动服务）
# 说明：cockpit 为 socket 激活，空闲时 cockpit.service 未运行而 cockpit.socket 监听属正常
check_system_services() {
  local host_ip="$1"
  if is_service_active cockpit || is_service_active cockpit.socket; then
    print_service_status "cockpit" "https://${host_ip}:9090"
  elif pkg_is_installed cockpit; then
    log_warning "cockpit 已安装但未运行，可执行：systemctl enable --now cockpit.socket"
  else
    log_info "cockpit 未安装"
  fi
}

# 检查 Docker 容器模块，自动发现 compose 目录下声明了 @web_port 的容器
# 说明：容器名取 compose 中首个 container_name，未声明时为文件名（与 docker-apps 一致）
check_docker_containers() {
  local host_ip="$1"
  local compose_dir="${SCRIPT_DIR}/compose"

  [[ -d "$compose_dir" ]] || return 0

  local yaml_file key web_port cname line running
  for yaml_file in "$compose_dir"/*.yaml "$compose_dir"/*.yml; do
    [[ -f "$yaml_file" ]] || continue
    key="${yaml_file##*/}"
    key="${key%.yaml}"
    key="${key%.yml}"
    web_port="" cname=""
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ -z "$web_port" && "$line" =~ ^#\ *@web_port:\ *(.*)$ ]]; then
        web_port="${BASH_REMATCH[1]}"
      elif [[ -z "$cname" && "$line" =~ ^[[:space:]]*container_name:[[:space:]]*[\"\']?([A-Za-z0-9][A-Za-z0-9_.-]*) ]]; then
        cname="${BASH_REMATCH[1]}"
      fi
    done < "$yaml_file"
    # 无 Web 端口声明则跳过（非 Web 容器）
    [[ -n "$web_port" ]] || continue

    running=$(docker inspect -f '{{.State.Running}}' "${cname:-$key}" 2>/dev/null) || running=""
    if [[ "$running" == "true" ]]; then
      print_service_status "$key" "https://${host_ip}:${web_port}"
    fi
  done
}

# 显示 firewalld 和 fail2ban 的安装状态提示
display_firewalld_fail2ban_info() {
  if pkg_is_installed firewalld; then
    log_info "Firewalld 防火墙服务已安装，请确保已放行必要端口。"
  fi
  if pkg_is_installed fail2ban; then
    log_info "Fail2ban 服务已安装，登录失败达到阈值后将自动封禁访问 IP。"
  fi
}

# ==================== 只读探测契约（docs/ARCHITECTURE.md §4.5） ====================

# 当前状态：只读工具，无"已应用"概念，给出 unknown + 服务摘要（不计入完成度）
module_status() {
  local cockpit="未安装" docker="未安装"
  if systemctl is-active --quiet cockpit.socket 2>/dev/null || systemctl is-active --quiet cockpit 2>/dev/null; then
    cockpit="运行中"
  elif pkg_is_installed cockpit; then
    cockpit="未运行"
  fi
  if systemctl is-active --quiet docker 2>/dev/null; then
    docker="运行中"
  elif command -v docker >/dev/null 2>&1; then
    docker="未运行"
  fi
  echo "unknown|只读工具 · cockpit ${cockpit} · docker ${docker}"
}

# 预演：只读查询
module_plan() {
  echo "info|-|只读查询，不修改系统"
}

# 主执行流程，串联各功能模块
main() {
  # 获取主机 IP 地址（hostname -I 的第一个）
  local host_ip="" _
  IFS=" " read -r host_ip _ < <(hostname -I 2>/dev/null) || true

  # 检查并显示系统服务状态
  check_system_services "$host_ip"

  # 检查 docker 服务是否活跃，如活跃则检查 Docker 容器状态
  if is_service_active docker; then
    check_docker_containers "$host_ip"
  fi

  # 显示 firewalld 和 fail2ban 的提示信息
  display_firewalld_fail2ban_info
}

# 契约守卫：DEBNAS_MODULE_ACTION=status|plan 时只加载函数供只读探测，不执行 main（docs/ARCHITECTURE.md §4.5）
if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi
