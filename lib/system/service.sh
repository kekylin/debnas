#!/bin/bash
# 功能：系统服务管理模块
# 说明：提供 root 权限检查、systemd 服务状态管理、sysctl 参数设置

set -euo pipefail
IFS=$'\n\t'

# 依赖: core/logging.sh, core/constants.sh（由 bootstrap-core.sh 加载）

# ==================== 公共接口 ====================

# 检查当前用户是否为 root
# 参数：无
# 返回：0 是 root，非 0 不是 root
# 说明：非 root 时输出错误提示并退出
require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    log_error "需要 root 权限"
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
    log_error "systemctl 不可用，跳过 ${service_name}"
    return 1
  fi

  case "$target_state" in
    started)
      if systemctl is-active --quiet "$service_name" 2>/dev/null; then
        log_info "服务 ${service_name} 已在运行，跳过启动"
        return 0
      fi
      log_info "启动 ${service_name}..."
      if systemctl start "$service_name" 2>&1; then
        log_success "${service_name} 已启动"
        return 0
      else
        log_error "启动 ${service_name} 失败"
        log_error "请检查日志：journalctl -u ${service_name} -n 20"
        return 1
      fi
      ;;

    stopped)
      if ! systemctl is-active --quiet "$service_name" 2>/dev/null; then
        log_info "服务 ${service_name} 已停止，跳过停止"
        return 0
      fi
      log_info "停止 ${service_name}..."
      if systemctl stop "$service_name" 2>&1; then
        log_success "${service_name} 已停止"
        return 0
      else
        log_error "停止 ${service_name} 失败"
        return 1
      fi
      ;;

    enabled)
      if systemctl is-enabled --quiet "$service_name" 2>/dev/null; then
        log_info "服务 ${service_name} 已设为开机启动，跳过"
        return 0
      fi
      log_info "启用 ${service_name} 开机启动..."
      if systemctl enable "$service_name" 2>&1; then
        log_success "${service_name} 开机启动"
        return 0
      else
        log_error "启用 ${service_name} 开机启动失败"
        return 1
      fi
      ;;

    disabled)
      if ! systemctl is-enabled --quiet "$service_name" 2>/dev/null; then
        log_info "服务 ${service_name} 已禁用开机启动，跳过"
        return 0
      fi
      log_info "禁用 ${service_name} 开机启动..."
      if systemctl disable "$service_name" 2>&1; then
        log_success "${service_name} 已禁用开机启动"
        return 0
      else
        log_error "禁用 ${service_name} 开机启动失败"
        return 1
      fi
      ;;

    restarted)
      log_info "重启 ${service_name}..."
      if systemctl restart "$service_name" 2>&1; then
        log_success "${service_name} 已重启"
        return 0
      else
        log_error "${service_name} 重启失败"
        log_error "请检查日志：journalctl -u ${service_name} -n 20"
        return 1
      fi
      ;;

    *)
      log_error "service_ensure: 无效状态 '${target_state}'"
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
    log_info "sysctl ${param_name} 已设置为 ${param_value}，跳过"
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

# sysctl 持久化目录（不设 readonly，允许测试覆盖）
DEBNAS_SYSCTL_DIR="${DEBNAS_SYSCTL_DIR:-/etc/sysctl.d}"

# 将 sysctl 参数持久化到配置文件
# 参数：$1 - 参数名
#       $2 - 参数值
#       $3 - 配置文件名（可选，默认 debnas.conf）
# 返回：0 成功，1 失败
# 说明：读出现有内容 → 删除同名参数的旧行 → 追加 "名 = 值" → 经 write_file_if_changed 写入
#       （原子替换、修改前集中备份并登记清单）；文件中已有完全相同的行时不改文件、不调用 sysctl_set
sysctl_persist() {
  local param_name="${1:?sysctl_persist: 缺少参数名}"
  local param_value="${2:?sysctl_persist: 缺少参数值}"
  local conf_file="${3:-debnas.conf}"
  local conf_path="${DEBNAS_SYSCTL_DIR}/${conf_file}"
  local conf_line="${param_name} = ${param_value}"
  local line rest new_content="" rc=0

  if [[ -f "$conf_path" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      # 幂等检查：整行精确匹配（子串匹配会把 "vm.swappiness = 10" 误判为已包含 "vm.swappiness = 1"）
      if [[ "$line" == "$conf_line" ]]; then
        log_info "sysctl 持久化配置已存在：${conf_path}"
        return 0
      fi
      # 移除同名参数的旧值（行首为参数名，其后可有空白，再接 =）
      rest="${line#"$param_name"}"
      if [[ "$line" == "$param_name"* && "$rest" =~ ^[[:space:]]*= ]]; then
        continue
      fi
      new_content+="${line}"$'\n'
    done < "$conf_path"
  fi
  new_content+="$conf_line"

  write_file_if_changed "$conf_path" "$new_content" "" 1 || rc=$?
  if [[ "$rc" -eq 2 ]]; then
    log_error "sysctl 参数持久化失败：${conf_path}"
    return 1
  fi
  log_info "sysctl 参数已持久化：${conf_path}"

  # 立即生效
  sysctl_set "$param_name" "$param_value"
}

# sshd 配置路径（不设 readonly，允许测试覆盖）
DEBNAS_SSHD_CONFIG="${DEBNAS_SSHD_CONFIG:-/etc/ssh/sshd_config}"

# 检测 sshd 实际监听端口（防火墙放行、fail2ban 封禁用：ssh 服务名只覆盖 22，自定义端口必须单独处理）
# 参数：$1 - 可选 --no-session：不追加当前 SSH 会话端口
# 输出：每行一个端口，升序去重
# 返回：始终 0（只读，非 root 也可运行）
# 说明：依次尝试 ① sshd -T（需 root，反映 Include/Match 合并后的生效值）
#       ② sshd_config 与 sshd_config.d/*.conf 中的 Port 行 ③ 默认 22；
#       另追加当前 SSH 会话所连的服务端端口（SSH_CONNECTION 第 4 字段），防止把自己锁在门外
#       ListenAddress 自带端口（a.b.c.d:port、[v6]:port）时该端口同样计入（只用 ListenAddress
#       改端口时只认 Port 会把真实端口挡在防火墙外）；端口须在 1..65535
#       注意：sudo 默认 env_reset 不保留 SSH_CONNECTION，经 sudo 运行时会话端口这一兜底通常不生效，
#       只能依赖 ①② 的解析结果
sshd_listen_ports() {
  local with_session=1 key value cfg found=0 port
  local -a ports=() cfgs=()
  [[ "${1:-}" == "--no-session" ]] && with_session=0

  if command -v sshd >/dev/null 2>&1; then
    while IFS=$' \t' read -r key value _; do
      [[ "$key" == "port" && "$value" =~ ^[0-9]{1,5}$ ]] && { ports[10#$value]=1; found=1; }
      if [[ "$key" == "listenaddress" ]]; then
        port=$(_sshd_listenaddress_port "$value") && ports[10#$port]=1
      fi
    done < <(sshd -T 2>/dev/null || true)
  fi
  if (( found == 0 )); then
    for cfg in "$DEBNAS_SSHD_CONFIG" "${DEBNAS_SSHD_CONFIG}.d"/*.conf; do
      [[ -f "$cfg" && -r "$cfg" ]] && cfgs+=("$cfg")
    done
    for cfg in "${cfgs[@]+"${cfgs[@]}"}"; do
      while IFS=$' \t' read -r key value _ || [[ -n "$key" ]]; do
        [[ "${key,,}" == "port" && "$value" =~ ^[0-9]{1,5}$ ]] && { ports[10#$value]=1; found=1; }
        if [[ "${key,,}" == "listenaddress" ]]; then
          port=$(_sshd_listenaddress_port "$value") && ports[10#$port]=1
        fi
      done < "$cfg"
    done
  fi
  # 未显式配置 Port 时 sshd 默认监听 22
  (( found )) || ports[22]=1

  if (( with_session )) && [[ -n "${SSH_CONNECTION:-}" ]]; then
    port="${SSH_CONNECTION##* }"
    [[ "$port" =~ ^[0-9]{1,5}$ ]] && ports[10#$port]=1
  fi
  # 稀疏下标数组按下标升序遍历，即数值升序去重
  for port in "${!ports[@]}"; do
    (( port > 0 && port <= 65535 )) && printf '%s\n' "$port"
  done
  return 0
}

# 从 ListenAddress 的值中取端口（内部）
# 参数：$1 - 如 0.0.0.0:2222、[::1]:2222、host:2222；无端口（0.0.0.0、::、[::1]）时失败
# 输出：端口（1..65535）
# 返回：0 有端口 / 1 无端口或非法
_sshd_listenaddress_port() {
  local addr="$1" p=""
  if [[ "$addr" == \[*\]:* ]]; then
    p="${addr##*\]:}"
  elif [[ "$addr" == *:* && "${addr#*:}" != *:* ]]; then
    # 恰好一个冒号：IPv4/主机名:端口（多个冒号的是不带括号的 IPv6，无端口）
    p="${addr#*:}"
  fi
  [[ "$p" =~ ^[0-9]{1,5}$ ]] && (( 10#$p >= 1 && 10#$p <= 65535 )) || return 1
  printf '%s\n' "$((10#$p))"
}

# sshd 监听端口（逗号分隔，供 fail2ban port= 等使用）
# 参数：同 sshd_listen_ports
# 输出：如 "22,2222"
sshd_listen_ports_csv() {
  local IFS=','
  local -a ports=()
  mapfile -t ports < <(sshd_listen_ports "$@")
  printf '%s\n' "${ports[*]}"
}
