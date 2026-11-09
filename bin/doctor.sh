#!/bin/bash
# 功能：DebNAS 系统诊断工具
# 说明：检查系统兼容性、配置一致性、网络连通性和 DebNAS 自身状态
# 原则：仅报告，不自动修改（路线图 §15.2）
#
# 用法：debnas doctor 或 bash bin/doctor.sh

set -euo pipefail
IFS=$'\n\t'

# 获取项目根目录
_DEBNAS_SCRIPT="$(readlink -f "${BASH_SOURCE[0]}")"
_DEBNAS_ROOT="$(cd "${_DEBNAS_SCRIPT%/*}/.." && pwd)"  # readlink -f 输出绝对路径，参数展开取目录

# 加载统一库
source "${_DEBNAS_ROOT}/lib/bootstrap.sh"

# ==================== 诊断项 ====================

# [1] 系统兼容性检查
check_system_compatibility() {
  echo "── 系统 ──"

  local os_name os_version os_codename arch
  os_name=$(get_system_name 2>/dev/null || echo "未知")
  os_version=$(get_system_version 2>/dev/null || echo "未知")
  os_codename=$(get_system_codename 2>/dev/null || echo "未知")
  arch=$(get_system_architecture 2>/dev/null || echo "未知")

  printf "  %-20s %s %s (%s)\n" "系统:" "$os_name" "$os_version" "$os_codename"
  printf "  %-20s %s\n" "架构:" "$arch"

  if verify_system_support 2>/dev/null; then
    printf "  %-20s %s\n" "兼容:" "✅ 支持"
  else
    printf "  %-20s %s\n" "兼容:" "❌ 不支持（需要 Debian 12+）"
  fi

  # 内存检查
  local mem_total
  mem_total=$(awk '/MemTotal/ {printf "%.1f GB", $2/1024/1024}' /proc/meminfo 2>/dev/null) || mem_total="未知"
  printf "  %-20s %s\n" "内存:" "$mem_total"

  echo ""
}

# [2] 磁盘空间检查
check_disk_space() {
  echo "── 磁盘"
  # 任一挂载点不存在时 df 返回非 0，pipefail + set -e 会让诊断中途退出
  df -h / /opt /var /tmp 2>/dev/null | awk 'NR==1 || /^\/dev/' | sed 's/^/  /' || true
  echo ""
}

# [3] APT 源检查
check_apt_sources() {
  echo "── APT 源"

  if [[ -f "/etc/apt/sources.list.d/debian.sources" ]]; then
    local mirror
    # 无匹配行时 grep 返回 1，pipefail + set -e 下会让 doctor 直接退出
    mirror=$(grep "^URIs:" /etc/apt/sources.list.d/debian.sources 2>/dev/null | head -1 | awk '{print $2}') || true
    printf "  %-20s %s\n" "主源格式:" "DEB822（新格式）"
    printf "  %-20s %s\n" "镜像地址:" "${mirror:-未配置}"

    # 测试连通性
    if [[ -n "$mirror" ]] && probe_url "${mirror}" 2>/dev/null; then
      printf "  %-20s %s\n" "连通性:" "✅ 可达"
    elif [[ -n "$mirror" ]]; then
      printf "  %-20s %s\n" "连通性:" "❌ 不可达"
    fi
  elif [[ -f "/etc/apt/sources.list" ]]; then
    printf "  %-20s %s\n" "主源格式:" "传统格式（旧格式）"
    local mirror
    mirror=$(grep "^deb " /etc/apt/sources.list 2>/dev/null | head -1 | awk '{print $2}') || true
    printf "  %-20s %s\n" "镜像地址:" "${mirror:-未配置}"
  else
    printf "  %-20s %s\n" "软件源:" "❌ 未配置"
    echo "  → 建议执行: debnas install sources"
  fi

  echo ""
}

# [4] 网络连通性检查
check_network() {
  echo "── 网络"

  local -a target_urls=(
    "https://deb.debian.org/"
    "https://mirrors.tuna.tsinghua.edu.cn/"
    "https://download.docker.com/"
    "https://github.com/"
    "https://gitee.com/"
  )
  local -a target_labels=(
    "Debian 官方源"
    "清华镜像"
    "Docker 官方"
    "GitHub"
    "Gitee"
  )

  local i
  for ((i=0; i<${#target_urls[@]}; i++)); do
    if probe_url "${target_urls[$i]}" 2>/dev/null; then
      printf "  %-30s %s\n" "${target_labels[$i]}:" "✅ 可达"
    else
      printf "  %-30s %s\n" "${target_labels[$i]}:" "❌ 不可达"
    fi
  done

  echo ""
}

# [5] DebNAS 状态检查
check_debnas_status() {
  echo "── 模块"

  printf "  %-20s %s\n" "版本:" "${DEBNAS_VERSION:-未知}"
  printf "  %-20s %s\n" "安装目录:" "${_DEBNAS_ROOT}"

  # 全局命令
  if [[ -f "/usr/local/bin/debnas" ]]; then
    printf "  %-20s %s\n" "全局命令:" "✅ /usr/local/bin/debnas"
  else
    printf "  %-20s %s\n" "全局命令:" "❌ 未安装"
  fi

  # Region 配置
  local region
  region=$(config_read "global" "region" "未配置" 2>/dev/null) || region="未配置"
  printf "  %-20s %s\n" "Region:" "$region"

  # 已安装模块
  local installed_count=0
  local -a installed_modules=()
  while IFS= read -r mod_name; do
    [[ -n "$mod_name" ]] || continue
    installed_count=$(( installed_count + 1 ))
    installed_modules+=("$mod_name")
  done < <(state_list_installed)
  printf "  %-20s %s 个\n" "模块:" "$installed_count"
  if [[ ${#installed_modules[@]} -gt 0 ]]; then
    # IFS=', ' 时 "${arr[*]}" 只用首字符 "," 连接，改为显式拼接 ", "
    local mod_list
    printf -v mod_list '%s, ' "${installed_modules[@]}"
    printf "  %-20s %s\n" "" "${mod_list%, }"
  fi

  # Cron 任务
  local cron_count=0
  local current_crontab
  current_crontab=$(crontab -l 2>/dev/null || true)
  if [[ -n "$current_crontab" ]]; then
    # grep -c 无匹配时已输出 0 但返回 1，旧写法 || echo "0" 会得到 "0\n0"
    cron_count=$(echo "$current_crontab" | grep -c "DEBNAS-CRON" 2>/dev/null) || true
    [[ -n "$cron_count" ]] || cron_count=0
  fi
  printf "  %-20s %s 个\n" "定时任务:" "$cron_count"

  echo ""
}

# [6] 关键服务检查
check_services() {
  echo "── 服务"

  local -a services=(
    "cockpit:Cockpit 管理面板"
    "docker:Docker 容器引擎"
    "firewalld:Firewalld 防火墙"
    "fail2ban:Fail2ban 入侵防护"
  )

  local entry svc label
  for entry in "${services[@]}"; do
    svc="${entry%%:*}"
    label="${entry#*:}"

    if ! command -v systemctl &>/dev/null; then
      printf "  %-30s %s\n" "${label}:" "⚠️ systemctl 不可用"
      continue
    fi

    if systemctl list-unit-files "${svc}.service" &>/dev/null 2>&1; then
      if systemctl is-active --quiet "$svc" 2>/dev/null; then
        printf "  %-30s %s\n" "${label}:" "✅ 运行中"
      elif systemctl is-enabled --quiet "$svc" 2>/dev/null; then
        printf "  %-30s %s\n" "${label}:" "⚠️ 已安装但未运行"
        echo "  → 建议执行: systemctl start ${svc}"
      else
        printf "  %-30s %s\n" "${label}:" "⚠️ 已安装但已禁用"
      fi
    else
      printf "  %-30s %s\n" "${label}:" "— 未安装"
    fi
  done

  echo ""
}

# [7] 版本兼容性检查
check_version_compatibility() {
  echo "── 版本"

  local installed_ver
  installed_ver=$(cat /var/lib/debnas/state/.debnas_version 2>/dev/null) || installed_ver=""

  if [[ -n "$installed_ver" ]]; then
    printf "  %-20s %s\n" "已记录版本:" "$installed_ver"
    printf "  %-20s %s\n" "当前代码版本:" "${DEBNAS_VERSION:-未知}"
    if [[ "$installed_ver" != "${DEBNAS_VERSION:-}" ]]; then
      printf "  %-20s %s\n" "版本一致性:" "⚠️ 不一致（建议执行 debnas update）"
    else
      printf "  %-20s %s\n" "版本一致性:" "✅ 一致"
    fi
  else
    printf "  %-20s %s\n" "已记录版本:" "未记录（首次安装）"
  fi

  if migration_check_compatibility 2>/dev/null; then
    printf "  %-20s %s\n" "配置兼容性:" "✅ 正常"
  else
    printf "  %-20s %s\n" "配置兼容性:" "⚠️ 存在问题"
  fi

  echo ""
}

# ==================== 主入口 ====================

main() {
  log_info "DebNAS 诊断"
  echo ""

  check_system_compatibility
  check_disk_space
  check_apt_sources
  check_network
  check_debnas_status
  check_services
  check_version_compatibility

  log_success "诊断完成 (7 项)"
}

main "$@"
