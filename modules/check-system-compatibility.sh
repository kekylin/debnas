#!/bin/bash
# 功能：系统兼容性检查工具（检查系统是否满足项目脚本运行要求）

set -euo pipefail
IFS=$'\n\t'

# 加载公共模块，确保依赖函数和常量可用
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/core/constants.sh"
source "${SCRIPT_DIR}/lib/core/logging.sh"
source "${SCRIPT_DIR}/lib/system/dependency.sh"
source "${SCRIPT_DIR}/lib/system/utils.sh"
source "${SCRIPT_DIR}/lib/system/urls.sh"

# 检查依赖，确保必备命令已安装
REQUIRED_CMDS=(awk grep df uname curl)
if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
  log_error "依赖缺失，请先安装必备命令：${REQUIRED_CMDS[*]}。"
  exit "${ERROR_DEPENDENCY}"
fi

# 系统兼容性检查（最小化检查，仅检查项目脚本运行必需项）
check_system_compatibility() {
  local issues_system=()
  local issues_resource=()
  local issues_network=()
  local issues_service=()

  log_info "正在执行系统兼容性检查..."

  # 1. 系统类型和版本检查（必需）
  echo "[系统检查]"
  if ! verify_system_support; then
    issues_system+=("系统不满足要求（需要 Debian 12 或更高版本）")
    echo "- 系统类型：不满足要求"
  else
    local codename
    codename=$(get_system_codename)
    echo "- 系统类型：$(get_system_name) $(get_system_version)"
    echo "- 系统版本：${codename}"
  fi

  # 2. 系统架构检查（必需，项目主要支持 x86-64）
  local arch
  arch=$(get_system_architecture)
  echo "- 系统架构：${arch}"
  if ! verify_architecture_support "x86_64"; then
    issues_system+=("系统架构为 ${arch}，项目主要支持 x86_64")
  fi

  # 3. 资源检查（必需）
  echo "[资源检查]"
  local mem_mb=$(( $(grep MemTotal /proc/meminfo | awk '{print $2}') / 1024 ))
  echo "- 内存：${mem_mb}MB"
  if [[ $mem_mb -lt 1024 ]]; then
    issues_resource+=("内存低于1GB（建议>=1GB）")
  fi

  local disk_gb=$(df / | awk 'NR==2 {print int($4/1024/1024)}')
  echo "- 磁盘可用空间：${disk_gb}GB"
  if [[ $disk_gb -lt 10 ]]; then
    issues_resource+=("根分区可用空间低于10GB（建议>=10GB）")
  fi

  # 4. 网络连通性检查（必需，项目需要下载软件包）
  echo "[网络检查]"
  local mirror_available=false
  local mirror_name
  local url
  
  # 检查国内镜像站连通性
  for url in "${APT_MIRRORS[@]}"; do
    mirror_name=$(get_mirror_name "$url")
    if curl -s --max-time 5 --connect-timeout 5 "$url" >/dev/null 2>&1; then
      echo "- 镜像站: ${mirror_name} ✓"
      mirror_available=true
      break
    fi
  done
  
  # 如果国内镜像站都不可用，检查官方镜像站
  if [[ "$mirror_available" == "false" ]]; then
    if curl -s --max-time 5 --connect-timeout 5 "${APT_OFFICIAL_MIRROR}" >/dev/null 2>&1; then
      echo "- 镜像站: ${APT_OFFICIAL_MIRROR_NAME} ✓"
      mirror_available=true
    else
      echo "- 镜像站: 所有镜像站均不可用 ✗"
      issues_network+=("无法连接到任何镜像站，无法下载软件包")
    fi
  fi

  # 5. 基本服务检查（推荐，但不强制）
  echo "[服务检查]"
  if command -v systemctl >/dev/null 2>&1; then
    # SSH 服务（用于远程管理）
    if systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null; then
      echo "- SSH: 运行中"
    else
      echo "- SSH: 未运行（建议启用，用于远程管理）"
    fi
    
    # Cron 服务（用于定时任务）
    if systemctl is-active --quiet cron 2>/dev/null; then
      echo "- Cron: 运行中"
    else
      echo "- Cron: 未运行（如使用定时任务功能，需要启用）"
    fi
  else
    echo "- 服务状态：无法检测（systemctl 不可用）"
  fi

  # 输出检查结论
  echo ""
  echo "检查结论："
  if [[ ${#issues_system[@]} -eq 0 && ${#issues_resource[@]} -eq 0 && ${#issues_network[@]} -eq 0 ]]; then
    echo "- 兼容性结论：✓ 适合运行项目脚本"
    echo "- 发现问题：无"
  else
    echo "- 兼容性结论：⚠ 存在风险"
    local all_issues=("${issues_system[@]}" "${issues_resource[@]}" "${issues_network[@]}")
    echo "- 发现问题："
    for issue in "${all_issues[@]}"; do
      echo "  • ${issue}"
    done
  fi
}

# 主函数：直接执行检查
main() {
  check_system_compatibility
}

main "$@" 