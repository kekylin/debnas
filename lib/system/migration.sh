#!/bin/bash
# 功能：版本迁移与配置兼容性检查
# 说明：在更新后检测版本变化，执行必要的配置迁移和状态清理
# 依赖: core/logging.sh, system/config.sh, system/state.sh（由 bootstrap.sh 加载）

set -euo pipefail
IFS=$'\n\t'

# ==================== 常量 ====================

# 版本状态文件（记录当前安装的 DebNAS 版本）
readonly DEBNAS_VERSION_STATE="/var/lib/debnas/state/.debnas_version"

# ==================== 内部函数 ====================

# 读取已安装的版本号
# 参数：无
# 输出：版本号字符串（如 "v2026.06"），无记录则输出空
_get_installed_version() {
  if [[ -f "$DEBNAS_VERSION_STATE" ]]; then
    cat "$DEBNAS_VERSION_STATE" 2>/dev/null || true
  fi
}

# 写入当前版本号
# 参数：$1 - 版本号
_save_version() {
  local version="$1"
  local state_dir
  state_dir=$(dirname "$DEBNAS_VERSION_STATE")
  mkdir -p "$state_dir" 2>/dev/null || true
  echo "$version" > "$DEBNAS_VERSION_STATE"
}

# 比较版本号（简单字符串比较，日期版本号适用）
# 参数：$1 - 旧版本，$2 - 新版本
# 返回：0 相同，1 不同
_version_changed() {
  local old_ver="$1"
  local new_ver="$2"
  [[ "$old_ver" != "$new_ver" ]]
}

# ==================== 迁移步骤注册 ====================
# 每个迁移步骤是一个函数，命名规则：_migrate_<目标版本>
# 函数接收旧版本号作为参数，返回 0 成功 / 1 失败
# 新增版本迁移时，只需添加对应函数即可

# 示例迁移步骤（未来版本按需添加）：
# _migrate_v2026_07() {
#   local old_ver="$1"
#   log_info "执行 v2026.06 → v2026.07 迁移..."
#   # 迁移逻辑...
#   return 0
# }

# ==================== 公共接口 ====================

# 检查并执行版本迁移
# 参数：无（使用 DEBNAS_VERSION 环境变量）
# 返回：0 成功（含无需迁移），1 迁移失败
# 说明：在 cmd_update 完成后调用，检测版本变化并执行迁移
migration_run() {
  local current_version="${DEBNAS_VERSION:-unknown}"
  local installed_version
  installed_version=$(_get_installed_version)

  # 首次安装或版本未知：仅记录版本，不执行迁移
  if [[ -z "$installed_version" ]]; then
    _save_version "$current_version"
    :
    return 0
  fi

  # 版本未变化：跳过
  if ! _version_changed "$installed_version" "$current_version"; then
    :
    return 0
  fi

  log_info "检测到版本变更：${installed_version} → ${current_version}"

  # 执行迁移步骤（按版本顺序）
  local migration_func
  local migration_failed=0

  # 动态查找匹配的迁移函数
  # 将版本号中的 . 替换为 _ 以匹配函数名
  local version_key
  version_key="${current_version//./_}"
  migration_func="_migrate_${version_key}"

  if declare -f "$migration_func" >/dev/null 2>&1; then
    log_info "执行迁移步骤：${migration_func}"
    if ! "$migration_func" "$installed_version"; then
      log_error "迁移步骤失败：${migration_func}"
      migration_failed=1
    fi
  fi

  # 更新版本记录
  _save_version "$current_version"

  if [[ "$migration_failed" -eq 1 ]]; then
    log_warning "部分迁移步骤失败，请检查日志"
    return 1
  fi

  log_success "版本迁移完成：${current_version}"
  return 0
}

# 检查配置兼容性（仅报告，不修改）
# 参数：无
# 返回：0 兼容，1 存在不兼容项
# 说明：在 doctor 命令中调用
migration_check_compatibility() {
  local issues=0

  # 检查关键配置文件存在性
  local -a required_configs=(
    "/etc/debnas/debnas.conf"
  )

  local conf
  for conf in "${required_configs[@]}"; do
    if [[ ! -f "$conf" ]]; then
      log_warning "配置文件缺失：${conf}"
      issues=$((issues + 1))
    fi
  done

  # 检查状态目录完整性
  if [[ ! -d "/var/lib/debnas/state" ]]; then
    log_warning "状态目录缺失：/var/lib/debnas/state"
    issues=$((issues + 1))
  fi

  if [[ "$issues" -gt 0 ]]; then
    log_warning "发现 ${issues} 个兼容性问题"
    return 1
  fi

  return 0
}
