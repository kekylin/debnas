#!/bin/bash
# 功能：系统兼容性检查工具（无交互菜单，直接输出结果）

set -euo pipefail
IFS=$'\n\t'

# 加载公共模块，确保依赖函数和常量可用
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/core/constants.sh"
source "${SCRIPT_DIR}/lib/core/logging.sh"
source "${SCRIPT_DIR}/lib/system/dependency.sh"
source "${SCRIPT_DIR}/lib/system/utils.sh"
source "${SCRIPT_DIR}/lib/ui/menu.sh"
source "${SCRIPT_DIR}/lib/ui/styles.sh"

# 检查依赖，确保必备命令已安装
REQUIRED_CMDS=(awk grep df uname)
if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
  log_error "依赖缺失，请先安装必备命令：${REQUIRED_CMDS[*]}。"
  exit "${ERROR_DEPENDENCY}"
fi

# 输出系统摘要信息
get_system_summary() {
  echo "系统: $(get_system_name) $(get_system_version) ($(get_system_architecture))"
  echo "主机名: $(get_hostname)"
  echo "内核: $(get_kernel_version)"
  echo "内存: $(( $(grep MemTotal /proc/meminfo | awk '{print $2}') / 1024 ))MB"
  echo "磁盘可用: $(df / | awk 'NR==2 {print int($4/1024/1024)}')GB"
  echo "用户: $(whoami) (UID: $EUID)"
}

# 输出关键运行指标
get_system_key_metrics() {
  local memory_mb=$(( $(grep MemTotal /proc/meminfo | awk '{print $2}') / 1024 ))
  local disk_gb=$(df / | awk 'NR==2 {print int($4/1024/1024)}')
  local load_avg=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | tr -d ',')
  echo "负载: $load_avg  内存: ${memory_mb}MB  磁盘: ${disk_gb}GB"
  echo "运行时长: $(uptime -p | sed 's/up //')"
}

# 输出硬件信息
get_detailed_hardware_info() {
  local cpu="$(grep 'model name' /proc/cpuinfo | head -1 | cut -d: -f2 | sed 's/^[ \t]*//')"
  local cores="$(grep -c 'processor' /proc/cpuinfo)"
  local arch="$(uname -m)"
  local total_mem=$(( $(grep MemTotal /proc/meminfo | awk '{print $2}') / 1024 ))
  echo "CPU: $cpu ($cores 核心, $arch)"
  echo "总内存: ${total_mem}MB"
  df -h | awk 'NR==1 || /^\/dev\// {printf("磁盘: %s %s/%s 可用:%s 挂载:%s\n", $1, $3, $2, $4, $6)}'
}

# 网络连通性测试
simple_network_test() {
  local urls=("https://mirrors.tuna.tsinghua.edu.cn" "https://www.debian.org")
  for url in "${urls[@]}"; do
    if curl -s --max-time 5 --connect-timeout 5 "$url" >/dev/null 2>&1; then
      echo "网络: $url ✓"
    else
      echo "网络: $url ✗"
    fi
  done
  local domains=("debian.org" "github.com")
  for domain in "${domains[@]}"; do
    if nslookup "$domain" >/dev/null 2>&1; then
      echo "DNS: $domain ✓"
    else
      echo "DNS: $domain ✗"
    fi
  done
}

# 基础环境兼容性检查
minimal_compat_check() {
  local issues_resource=()
  local issues_network=()
  local issues_permission=()
  log_info "基础环境兼容性检查..."
  echo "[系统信息]"
  get_system_summary
  echo "[运行指标]"
  get_system_key_metrics
  echo "[硬件信息]"
  get_detailed_hardware_info
  echo "[网络状态]"
  simple_network_test
  local mem_mb=$(( $(grep MemTotal /proc/meminfo | awk '{print $2}') / 1024 ))
  if [[ $mem_mb -lt 512 ]]; then
    issues_resource+=("内存低于512MB")
  fi
  local disk_gb=$(df / | awk 'NR==2 {print int($4/1024/1024)}')
  if [[ $disk_gb -lt 5 ]]; then
    issues_resource+=("根分区可用空间低于5GB")
  fi
  if ! curl -s --max-time 5 --connect-timeout 5 "https://www.debian.org" >/dev/null 2>&1; then
    issues_network+=("无法访问debian.org，网络异常")
  fi
  if ! is_root_user; then
    issues_permission+=("非root用户运行")
  fi
  echo "检查结论："
  if [[ ${#issues_resource[@]} -eq 0 && ${#issues_network[@]} -eq 0 && ${#issues_permission[@]} -eq 0 ]]; then
    echo "- 兼容性结论：适合"
    echo "- 发现问题：无"
  else
    echo "- 兼容性结论：存在风险"
    local all_issues=("${issues_resource[@]}" "${issues_network[@]}" "${issues_permission[@]}")
    echo "- 发现问题：${all_issues[*]}"
  fi
}

# 全面环境兼容性检查
full_compat_check() {
  local issues_resource=()
  local issues_network=()
  local issues_permission=()
  local issues_time=()
  local issues_virtual=()
  local issues_service=()
  local issues_diskhealth=()
  log_info "增强环境兼容性检查..."
  echo "[系统信息]"
  get_system_summary
  echo "[运行指标]"
  get_system_key_metrics
  echo "[硬件信息]"
  get_detailed_hardware_info
  echo "[网络状态]"
  simple_network_test
  local mem_mb=$(( $(grep MemTotal /proc/meminfo | awk '{print $2}') / 1024 ))
  if [[ $mem_mb -lt 1024 ]]; then
    issues_resource+=("内存低于1GB")
  fi
  local disk_gb=$(df / | awk 'NR==2 {print int($4/1024/1024)}')
  if [[ $disk_gb -lt 10 ]]; then
    issues_resource+=("根分区可用空间低于10GB")
  fi
  if ! curl -s --max-time 5 --connect-timeout 5 "https://www.debian.org" >/dev/null 2>&1; then
    issues_network+=("无法访问debian.org，网络异常")
  fi
  if ! is_root_user; then
    issues_permission+=("非root用户运行")
  fi
  echo "[时间同步]"
  if command -v timedatectl >/dev/null 2>&1; then
    if timedatectl show | grep -q 'NTPSynchronized=yes'; then
      echo "- NTP同步：正常"
    else
      echo "- NTP同步：异常"
      issues_time+=("系统时间未同步或无NTP服务")
    fi
  else
    echo "- NTP同步：未检测/未安装"
  fi
  echo "[虚拟化]"
  if command -v egrep >/dev/null 2>&1; then
    if [[ $(egrep -c '(vmx|svm)' /proc/cpuinfo) -eq 0 ]]; then
      echo "- CPU虚拟化：不支持"
      issues_virtual+=("CPU不支持虚拟化")
    else
      echo "- CPU虚拟化：支持"
    fi
  else
    echo "- CPU虚拟化：未检测/未安装"
  fi
  echo "[服务状态]"
  if command -v systemctl >/dev/null 2>&1; then
    for svc in ssh cron; do
      if systemctl is-active --quiet "$svc"; then
        echo "- $svc: 运行中"
      else
        echo "- $svc: 未运行"
        issues_service+=("$svc服务未运行")
      fi
    done
  else
    echo "- 服务状态：未检测/未安装"
  fi
  echo "[安全模块]"
  if command -v aa-status >/dev/null 2>&1; then
    aa_status=$(aa-status --enabled 2>/dev/null | grep 'enabled' || true)
    if [[ -n "$aa_status" ]]; then
      echo "- AppArmor: 启用"
    else
      echo "- AppArmor: 未启用"
    fi
  else
    echo "- AppArmor: 未检测/未安装"
  fi
  echo "[磁盘健康]"
  if command -v smartctl >/dev/null 2>&1; then
    if smartctl -H /dev/sda | grep -q 'PASSED'; then
      echo "- /dev/sda: 健康"
    else
      echo "- /dev/sda: 存在健康风险"
      issues_diskhealth+=("/dev/sda健康异常")
    fi
  else
    echo "- smartctl: 未检测/未安装"
  fi
  echo "检查结论："
  if [[ ${#issues_resource[@]} -eq 0 && ${#issues_network[@]} -eq 0 && ${#issues_permission[@]} -eq 0 && ${#issues_time[@]} -eq 0 && ${#issues_virtual[@]} -eq 0 && ${#issues_service[@]} -eq 0 && ${#issues_diskhealth[@]} -eq 0 ]]; then
    echo "- 兼容性结论：适合"
    echo "- 发现问题：无"
  else
    echo "- 兼容性结论：存在风险"
    local all_issues=("${issues_resource[@]}" "${issues_network[@]}" "${issues_permission[@]}" "${issues_time[@]}" "${issues_virtual[@]}" "${issues_service[@]}" "${issues_diskhealth[@]}")
    echo "- 发现问题：${all_issues[*]}"
  fi
}

# 菜单
show_check_mode_menu() {
  echo "请选择检查模式："
  echo "1) 基础检查"
  echo "2) 增强检查"
  echo "0) 返回"
}

main() {
  while true; do
    show_check_mode_menu
    read -rp "请选择编号: " choice
    case $choice in
      1)
        minimal_compat_check
        break
        ;;
      2)
        full_compat_check
        break
        ;;
      0)
        return 0
        ;;
      *)
        echo "无效选项，请重新输入。"
        ;;
    esac
  done
}

main "$@" 