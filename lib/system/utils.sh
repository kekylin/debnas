#!/bin/bash
# 功能：系统工具库，包含系统验证、检测等公共函数

set -euo pipefail
IFS=$'\n\t'

# 获取库文件目录
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$LIB_DIR/core/logging.sh"

# 系统兼容性检查结果存储
declare -A SYSTEM_CHECK_RESULTS

# 验证系统支持，仅支持 Debian 12+
# 参数：无
# 返回值：0成功，非0失败
verify_system_support() {
  local system
  if command -v lsb_release >/dev/null 2>&1; then
    system=$(lsb_release -is)
  else
    system=$(grep -oP '^ID=\K.*' /etc/os-release | tr -d '"')
  fi
  system=$(echo "$system" | tr '[:upper:]' '[:lower:]')
  if [[ "$system" != "debian" ]]; then
    log_error "不支持的系统 (${system})，仅支持 Debian 12 及以上版本"
    return 1
  fi
  
  # 检查 Debian 版本
  local version
  if [[ -f /etc/debian_version ]]; then
    version=$(cat /etc/debian_version)
  else
    version=$(grep -oP '^VERSION_ID="\K[0-9.]+' /etc/os-release || echo "0")
  fi
  
  # 检查是否为 Debian 12 或更高版本
  if [[ "$version" =~ ^[0-9]+\.?[0-9]*$ ]]; then
    local major_version=${version%%.*}
    if [[ $major_version -lt 12 ]]; then
      log_error "Debian 版本过低 (${version})，需要 Debian 12 或更高版本"
      return 1
    fi
  fi
  
  return 0
}

# 验证系统支持，仅支持 Debian 12 和 13
# 参数：无
# 返回值：0成功，非0失败
verify_debian_12_13_support() {
  local system
  if command -v lsb_release >/dev/null 2>&1; then
    system=$(lsb_release -is)
  else
    system=$(grep -oP '^ID=\K.*' /etc/os-release | tr -d '"')
  fi
  system=$(echo "$system" | tr '[:upper:]' '[:lower:]')
  if [[ "$system" != "debian" ]]; then
    log_error "不支持的系统 (${system})，仅支持 Debian 12 和 13"
    return 1
  fi
  
  # 获取系统代号
  local codename
  if command -v lsb_release >/dev/null 2>&1; then
    codename=$(lsb_release -cs)
  else
    codename=$(grep -oP '^VERSION_CODENAME=\K.*' /etc/os-release | tr -d '"')
  fi
  
  # 检查是否为支持的版本代号
  case "$codename" in
    "bookworm"|"trixie")
      log_info "检测到支持的 Debian 版本: $codename"
      return 0
      ;;
    *)
      log_error "不支持的 Debian 版本代号: $codename，仅支持 bookworm (Debian 12) 和 trixie (Debian 13)"
      return 1
      ;;
  esac
}

# 获取系统代号
# 参数：无
# 返回值：系统代号字符串
get_system_codename() {
  if command -v lsb_release >/dev/null 2>&1; then
    lsb_release -cs
  else
    grep -oP '^VERSION_CODENAME=\K.*' /etc/os-release | tr -d '"'
  fi
}

# 检查系统代号是否支持
# 参数：$1 - 系统代号
# 返回值：0支持，非0不支持
is_supported_codename() {
  local codename="$1"
  case "$codename" in
    "bookworm"|"trixie")
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# 获取系统名称
# 参数：无
# 返回值：系统名称字符串
get_system_name() {
  if command -v lsb_release >/dev/null 2>&1; then
    lsb_release -is
  else
    grep -oP '^ID=\K.*' /etc/os-release | tr -d '"'
  fi
}

# 获取系统版本
# 参数：无
# 返回值：系统版本字符串
get_system_version() {
  if [[ -f /etc/debian_version ]]; then
    cat /etc/debian_version
  else
    grep -oP '^VERSION_ID="\K[0-9.]+' /etc/os-release || echo "未知"
  fi
}

# 获取主机名
# 参数：无
# 返回值：主机名字符串
get_hostname() {
  local hostname=$(hostname 2>/dev/null)
  if [[ -z "$hostname" || "$hostname" == "(none)" ]]; then
    get_system_name
  else
    echo "$hostname"
  fi
}

# 检查是否为 root 用户
# 参数：无
# 返回值：0是root，非0不是root
is_root_user() {
  [[ $EUID -eq 0 ]]
}

# 检查系统是否为 systemd
# 参数：无
# 返回值：0是systemd，非0不是systemd
is_systemd() {
  [[ -d /run/systemd/system ]]
}

# 检查系统是否为容器环境
# 参数：无
# 返回值：0是容器，非0不是容器
is_container() {
  [[ -f /.dockerenv ]] || grep -q 'docker\|lxc' /proc/1/cgroup 2>/dev/null
}

# 获取系统架构
# 参数：无
# 返回值：架构字符串
get_system_architecture() {
  uname -m 2>/dev/null || echo "未知"
}

# 获取内核版本
# 参数：无
# 返回值：内核版本字符串
get_kernel_version() {
  uname -r 2>/dev/null || echo "未知"
}

# 检查系统架构兼容性
# 参数：无
# 返回值：0兼容，非0不兼容
check_architecture_compatibility() {
  local arch=$(get_system_architecture)
  local supported_archs=("x86_64" "amd64" "aarch64" "arm64" "armv7l" "armv8l")
  
  for supported in "${supported_archs[@]}"; do
    if [[ "$arch" == "$supported" ]]; then
      SYSTEM_CHECK_RESULTS["architecture"]="兼容 ($arch)"
      return 0
    fi
  done
  
  SYSTEM_CHECK_RESULTS["architecture"]="不兼容 ($arch)"
  log_warn "系统架构 $arch 可能不完全兼容，建议使用 x86_64 或 aarch64"
  return 1
}

# 检查内核版本兼容性
# 参数：无
# 返回值：0兼容，非0不兼容
check_kernel_compatibility() {
  local kernel_version=$(get_kernel_version)
  local major_version=$(echo "$kernel_version" | cut -d. -f1)
  local minor_version=$(echo "$kernel_version" | cut -d. -f2)
  
  # 检查内核版本是否 >= 5.10 (Debian 12 默认内核)
  if [[ "$major_version" -gt 5 ]] || ([[ "$major_version" -eq 5 ]] && [[ "$minor_version" -ge 10 ]]); then
    SYSTEM_CHECK_RESULTS["kernel"]="兼容 ($kernel_version)"
    return 0
  else
    SYSTEM_CHECK_RESULTS["kernel"]="不兼容 ($kernel_version)"
    log_warn "内核版本 $kernel_version 可能过低，建议使用 5.10 或更高版本"
    return 1
  fi
}

# 检查内存大小
# 参数：$1 - 最小内存要求（MB，默认512）
# 返回值：0满足要求，非0不满足
check_memory_requirements() {
  local min_memory="${1:-512}"
  local total_memory_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  local total_memory_mb=$((total_memory_kb / 1024))
  
  if [[ $total_memory_mb -ge $min_memory ]]; then
    SYSTEM_CHECK_RESULTS["memory"]="满足要求 (${total_memory_mb}MB >= ${min_memory}MB)"
    return 0
  else
    SYSTEM_CHECK_RESULTS["memory"]="不满足要求 (${total_memory_mb}MB < ${min_memory}MB)"
    log_warn "系统内存不足，当前 ${total_memory_mb}MB，建议至少 ${min_memory}MB"
    return 1
  fi
}

# 检查磁盘空间
# 参数：$1 - 检查路径（默认/），$2 - 最小空间要求（GB，默认5）
# 返回值：0满足要求，非0不满足
check_disk_space() {
  local check_path="${1:-/}"
  local min_space_gb="${2:-5}"
  local available_space_kb=$(df "$check_path" | awk 'NR==2 {print $4}')
  local available_space_gb=$((available_space_kb / 1024 / 1024))
  
  if [[ $available_space_gb -ge $min_space_gb ]]; then
    SYSTEM_CHECK_RESULTS["disk_space"]="满足要求 (${available_space_gb}GB >= ${min_space_gb}GB)"
    return 0
  else
    SYSTEM_CHECK_RESULTS["disk_space"]="不满足要求 (${available_space_gb}GB < ${min_space_gb}GB)"
    log_warn "磁盘空间不足，当前可用 ${available_space_gb}GB，建议至少 ${min_space_gb}GB"
    return 1
  fi
}

# 检查网络连接
# 参数：$1 - 测试URL（默认https://mirrors.tuna.tsinghua.edu.cn）
# 返回值：0连接正常，非0连接异常
check_network_connectivity() {
  local test_url="${1:-https://mirrors.tuna.tsinghua.edu.cn}"
  local timeout="${2:-10}"
  
  if command -v curl >/dev/null 2>&1; then
    if curl -s --max-time "$timeout" --connect-timeout "$timeout" "$test_url" >/dev/null 2>&1; then
      SYSTEM_CHECK_RESULTS["network"]="连接正常"
      return 0
    fi
  elif command -v wget >/dev/null 2>&1; then
    if wget -q --timeout="$timeout" --tries=1 "$test_url" -O /dev/null 2>/dev/null; then
      SYSTEM_CHECK_RESULTS["network"]="连接正常"
      return 0
    fi
  fi
  
  SYSTEM_CHECK_RESULTS["network"]="连接异常"
  log_warn "网络连接测试失败，可能影响软件包下载"
  return 1
}

# 检查关键服务状态
# 参数：无
# 返回值：0所有服务正常，非0有服务异常
check_critical_services() {
  local failed_services=()
  
  # 检查 systemd 是否正在运行
  if ! is_systemd; then
    failed_services+=("systemd")
  fi

  if [[ ${#failed_services[@]} -eq 0 ]]; then
    SYSTEM_CHECK_RESULTS["services"]="关键服务正常"
    return 0
  else
    SYSTEM_CHECK_RESULTS["services"]="服务异常: ${failed_services[*]}"
    log_warn "发现异常服务: ${failed_services[*]}"
    return 1
  fi
}

# 检查软件包管理器状态
# 参数：无
# 返回值：0正常，非0异常
check_package_manager() {
  if ! command -v apt >/dev/null 2>&1; then
    SYSTEM_CHECK_RESULTS["package_manager"]="apt 未安装"
    log_error "apt 包管理器未安装"
    return 1
  fi
  
  # 检查 apt 是否被锁定（只检查锁定文件，不执行 apt update）
  if [[ -f /var/lib/apt/lists/lock ]] || [[ -f /var/cache/apt/archives/lock ]]; then
    SYSTEM_CHECK_RESULTS["package_manager"]="apt 被锁定"
    log_warn "apt 包管理器被锁定，可能有其他进程在使用"
    return 1
  fi
  
  SYSTEM_CHECK_RESULTS["package_manager"]="apt 正常"
  return 0
}

# 检查用户权限
# 参数：无
# 返回值：0权限足够，非0权限不足
check_user_permissions() {
  if ! is_root_user; then
    SYSTEM_CHECK_RESULTS["permissions"]="需要 root 权限"
    log_error "脚本需要 root 权限运行"
    return 1
  fi
  
  SYSTEM_CHECK_RESULTS["permissions"]="权限足够"
  return 0
}

# 检查容器环境兼容性
# 参数：无
# 返回值：0兼容，非0不兼容
check_container_compatibility() {
  if is_container; then
    SYSTEM_CHECK_RESULTS["container"]="容器环境 (部分功能受限)"
    log_warn "检测到容器环境，部分功能可能受限"
    return 1
  else
    SYSTEM_CHECK_RESULTS["container"]="物理/虚拟机环境"
    return 0
  fi
}

# 执行完整的系统兼容性检查
# 参数：$1 - 是否显示详细信息（默认true）
# 返回值：0所有检查通过，非0有检查失败
perform_system_compatibility_check() {
  local show_details="${1:-true}"
  local failed_checks=0
  
  log_info "开始执行系统兼容性检查..."
  
  # 清空之前的结果
  SYSTEM_CHECK_RESULTS=()
  
  # 基础系统检查
  if ! verify_system_support; then
    ((failed_checks++))
  else
    SYSTEM_CHECK_RESULTS["system"]="兼容 ($(get_system_name) $(get_system_version))"
  fi
  
  # 权限检查
  if ! check_user_permissions; then
    ((failed_checks++))
  fi
  
  # 架构检查
  if ! check_architecture_compatibility; then
    ((failed_checks++))
  fi
  
  # 内核检查
  if ! check_kernel_compatibility; then
    ((failed_checks++))
  fi
  
  # 内存检查
  if ! check_memory_requirements 512; then
    ((failed_checks++))
  fi
  
  # 磁盘空间检查
  if ! check_disk_space "/" 5; then
    ((failed_checks++))
  fi
  
  # 网络连接检查
  if ! check_network_connectivity; then
    ((failed_checks++))
  fi
  
  # 包管理器检查
  if ! check_package_manager; then
    ((failed_checks++))
  fi
  
  # 服务检查
  if ! check_critical_services; then
    ((failed_checks++))
  fi
  
  # 容器环境检查
  if ! check_container_compatibility; then
    ((failed_checks++))
  fi
  
  # 显示检查结果
  if [[ "$show_details" == "true" ]]; then
    echo ""
    log_info "系统兼容性检查结果："
    echo "=================================="
    for key in "${!SYSTEM_CHECK_RESULTS[@]}"; do
      printf "%-15s: %s\n" "$key" "${SYSTEM_CHECK_RESULTS[$key]}"
    done
    echo "=================================="
  fi
  
  if [[ $failed_checks -eq 0 ]]; then
    log_success "系统兼容性检查通过"
    return 0
  else
    log_warn "系统兼容性检查发现 $failed_checks 个问题"
    return 1
  fi
} 