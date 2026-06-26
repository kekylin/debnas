#!/bin/bash
# 功能：系统服务管理模块
# 说明：提供 root 权限检查、systemd 服务状态管理、sysctl 参数设置

set -euo pipefail
IFS=$'\n\t'

# 获取库文件目录
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$LIB_DIR/core/logging.sh"
source "$LIB_DIR/core/constants.sh"

# ==================== 公共接口 ====================

# 检查当前用户是否为 root
# 参数：无
# 返回：0 是 root，非 0 不是 root
# 说明：非 root 时输出错误提示并退出
require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    log_error "此操作需要 root 权限，请使用 sudo 或以 root 身份运行"
    return "${ERROR_PERMISSION}"
  fi
  return 0
}

# 确保 systemd 服务处于指定状态
# 参数：$1 - 服务名（如 cockpit、docker）
#       $2 - 目标状态（started|stopped|enabled|disabled|restarted）
# 返回：0 成功，1 失败
# 示例：
#   service_ensure "cockpit" "started"
#   service_ensure "docker" "enabled"
service_ensure() {
  local service_name="${1:?service_ensure: 缺少服务名}"
  local target_state="${2:?service_ensure: 缺少目标状态 (started|stopped|enabled|disabled|restarted)}"

  # 检查 systemctl 是否可用
  if ! command -v systemctl &>/dev/null; then
    log_error "systemctl 不可用，无法管理服务：${service_name}"
    return 1
  fi

  case "$target_state" in
    started)
      if systemctl is-active --quiet "$service_name" 2>/dev/null; then
        log_debug "服务 ${service_name} 已在运行"
        return 0
      fi
      log_info "正在启动服务：${service_name}"
      if systemctl start "$service_name" 2>&1; then
        log_success "服务已启动：${service_name}"
        return 0
      else
        log_error "启动服务失败：${service_name}"
        log_error "请检查日志：journalctl -u ${service_name} -n 20"
        return 1
      fi
      ;;

    stopped)
      if ! systemctl is-active --quiet "$service_name" 2>/dev/null; then
        log_debug "服务 ${service_name} 已停止"
        return 0
      fi
      log_info "正在停止服务：${service_name}"
      if systemctl stop "$service_name" 2>&1; then
        log_success "服务已停止：${service_name}"
        return 0
      else
        log_error "停止服务失败：${service_name}"
        return 1
      fi
      ;;

    enabled)
      if systemctl is-enabled --quiet "$service_name" 2>/dev/null; then
        log_debug "服务 ${service_name} 已设为开机启动"
        return 0
      fi
      log_info "正在启用开机启动：${service_name}"
      if systemctl enable "$service_name" 2>&1; then
        log_success "已启用开机启动：${service_name}"
        return 0
      else
        log_error "启用开机启动失败：${service_name}"
        return 1
      fi
      ;;

    disabled)
      if ! systemctl is-enabled --quiet "$service_name" 2>/dev/null; then
        log_debug "服务 ${service_name} 已禁用开机启动"
        return 0
      fi
      log_info "正在禁用开机启动：${service_name}"
      if systemctl disable "$service_name" 2>&1; then
        log_success "已禁用开机启动：${service_name}"
        return 0
      else
        log_error "禁用开机启动失败：${service_name}"
        return 1
      fi
      ;;

    restarted)
      log_info "正在重启服务：${service_name}"
      if systemctl restart "$service_name" 2>&1; then
        log_success "服务已重启：${service_name}"
        return 0
      else
        log_error "重启服务失败：${service_name}"
        log_error "请检查日志：journalctl -u ${service_name} -n 20"
        return 1
      fi
      ;;

    *)
      log_error "service_ensure: 无效的目标状态 '${target_state}'"
      log_error "支持的状态：started, stopped, enabled, disabled, restarted"
      return 1
      ;;
  esac
}

# 检查服务是否已安装（unit 文件存在）
# 参数：$1 - 服务名
# 返回：0 已安装，1 未安装
service_is_installed() {
  local service_name="${1:?service_is_installed: 缺少服务名}"
  systemctl list-unit-files "${service_name}.service" &>/dev/null
}

# 检查服务是否正在运行
# 参数：$1 - 服务名
# 返回：0 正在运行，1 未运行
service_is_active() {
  local service_name="${1:?service_is_active: 缺少服务名}"
  systemctl is-active --quiet "$service_name" 2>/dev/null
}

# 设置 sysctl 内核参数（幂等，已设置则跳过）
# 参数：$1 - 参数名（如 net.ipv4.tcp_congestion_control）
#       $2 - 参数值（如 bbr）
# 返回：0 成功，1 失败
sysctl_set() {
  local param_name="${1:?sysctl_set: 缺少参数名}"
  local param_value="${2:?sysctl_set: 缺少参数值}"

  # 检查 sysctl 是否可用
  if ! command -v sysctl &>/dev/null; then
    log_error "sysctl 不可用"
    return 1
  fi

  # 读取当前值
  local current_value
  current_value=$(sysctl -n "$param_name" 2>/dev/null) || current_value=""

  # 幂等检查：值相同则跳过
  if [[ "$current_value" == "$param_value" ]]; then
    log_debug "sysctl ${param_name} 已设置为 ${param_value}，跳过"
    return 0
  fi

  log_info "设置 sysctl: ${param_name} = ${param_value}"
  if sysctl -w "${param_name}=${param_value}" 2>&1; then
    log_success "sysctl 已设置：${param_name} = ${param_value}"
    return 0
  else
    log_error "sysctl 设置失败：${param_name} = ${param_value}"
    return 1
  fi
}

# 将 sysctl 参数持久化到配置文件
# 参数：$1 - 参数名
#       $2 - 参数值
#       $3 - 配置文件名（可选，默认 debnas.conf）
# 返回：0 成功，1 失败
sysctl_persist() {
  local param_name="${1:?sysctl_persist: 缺少参数名}"
  local param_value="${2:?sysctl_persist: 缺少参数值}"
  local conf_file="${3:-debnas.conf}"
  local conf_path="/etc/sysctl.d/${conf_file}"

  # 确保目录存在
  mkdir -p /etc/sysctl.d

  local conf_line="${param_name} = ${param_value}"

  # 幂等检查：配置文件中已存在相同配置
  if [[ -f "$conf_path" ]] && grep -qF "$conf_line" "$conf_path" 2>/dev/null; then
    log_debug "sysctl 持久化配置已存在：${conf_path}"
    return 0
  fi

  # 移除旧值（如果有不同值的同名参数）
  if [[ -f "$conf_path" ]]; then
    sed -i "/^${param_name//./\\.}[[:space:]]*=/d" "$conf_path" 2>/dev/null || true
  fi

  # 追加新值
  echo "$conf_line" >> "$conf_path"
  log_info "sysctl 参数已持久化：${conf_path}"

  # 立即生效
  sysctl_set "$param_name" "$param_value"
}
