#!/bin/bash
# 功能：APT Pinning 配置管理模块，提供统一的软件源优先级配置

set -euo pipefail
IFS=$'\n\t'

# 依赖: core/logging.sh, system/utils.sh（write_file_if_changed，由 bootstrap-core.sh 加载）

# APT Pinning 配置目录（不设 readonly，允许测试覆盖）
APT_PREFERENCES_DIR="${APT_PREFERENCES_DIR:-/etc/apt/preferences.d}"

# 生成 backports 优先级文件内容（纯函数，不含时间戳，内容只由参数决定，保证幂等）
# 参数：$1 - 系统代号；其余 - 包名模式（每个生成一个 Pin 块）
# 输出：stdout 文件内容
pinning_render() {
  local os_codename="$1" pkg_group
  shift
  printf '%s\n' "# 优先从 backports 安装/更新" "# 系统版本: ${os_codename}"
  for pkg_group in "$@"; do
    printf 'Package: %s\nPin: release n=%s-backports\nPin-Priority: 500\n\n' "$pkg_group" "$os_codename"
  done
}

# 写入 backports 优先级文件（内容未变则跳过；变化时经 write_file_if_changed 原子替换、集中备份并登记清单）
# 用法: write_pinning_file <pinning_file> <os_codename> <packages_group_1> [<packages_group_2> ...]
# 返回：0 已写入或内容未变，1 写入失败
write_pinning_file() {
  local pinning_file="$1"
  local os_codename="$2"
  shift 2
  local content rc=0

  content=$(pinning_render "$os_codename" "$@")
  write_file_if_changed "$pinning_file" "$content" "644" 1 || rc=$?
  if [[ "$rc" -eq 2 ]]; then
    return 1
  fi
  return 0
}

# 写入 Cockpit 相关组件的 APT Pinning（始终从 backports 安装最新版）
configure_cockpit_pinning() {
  local os_codename="$1"
  local pinning_file="${APT_PREFERENCES_DIR}/cockpit-backports.pref"
  write_pinning_file "${pinning_file}" "${os_codename}" \
    "cockpit" \
    "cockpit-*" \
    "pcp" \
    "python3-pcp" \
    "tuned" || return 1
  log_success "Cockpit 源优先级已配置"
  return 0
}

# 配置特定组件的 APT Pinning
configure_component_pinning() {
  local os_codename="$1"
  local component="$2"
  local packages="$3"
  local pinning_file="${APT_PREFERENCES_DIR}/${component}-backports.pref"

  log_info "写入 ${component} 源优先级..."
  write_pinning_file "${pinning_file}" "${os_codename}" "${packages}" || return 1
  log_success "${component} 源优先级已配置"
  return 0
}

# 应用 APT Pinning 配置
apply_pinning_config() {
  log_info "应用源优先级..."

  if ! apt_update_safe; then
    log_error "apt update 失败，源优先级可能未生效"
    return 1
  fi

  log_success "源优先级已生效"
  return 0
}

# 判断 APT Pinning 配置文件是否存在（只读、不打日志，供 module_status / module_plan 使用）
# 参数：$1 - 配置文件路径
# 返回：0 存在，1 不存在
pinning_file_exists() {
  [[ -f "${1:-}" ]]
}

# 检查 APT Pinning 配置状态（带日志）
# deprecated：只读判断请用 pinning_file_exists（本函数会输出 INFO/WARN 日志）
check_pinning_status() {
  local pinning_file="$1"

  if pinning_file_exists "${pinning_file}"; then
    log_info "APT Pinning 配置文件存在: ${pinning_file}"
    return 0
  else
    log_warning "APT Pinning 配置文件不存在: ${pinning_file}"
    return 1
  fi
}

# 清理 APT Pinning 配置
cleanup_pinning_config() {
  local pinning_file="$1"

  if [[ -n "${pinning_file}" && -f "${pinning_file}" ]]; then
    # 删除前集中备份并登记清单，便于回滚
    if declare -F debnas_backup_file >/dev/null 2>&1; then
      debnas_backup_file "${pinning_file}" >/dev/null 2>&1 || true
    fi
    rm -f -- "${pinning_file}"
    if declare -F manifest_add >/dev/null 2>&1; then
      manifest_add "${pinning_file}" || true
    fi
    log_info "已清理 APT Pinning 配置: ${pinning_file}"
  fi
  return 0
}
