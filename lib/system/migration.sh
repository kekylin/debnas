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
  local state_dir tmp
  state_dir=$(dirname "$DEBNAS_VERSION_STATE")
  if ! mkdir -p "$state_dir" 2>/dev/null; then
    log_warning "无法创建版本状态目录：${state_dir}"
    return 1
  fi
  tmp=$(mktemp "${DEBNAS_VERSION_STATE}.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s\n' "$version" > "$tmp" || ! mv -fT -- "$tmp" "$DEBNAS_VERSION_STATE"; then
    rm -f -- "$tmp" 2>/dev/null || true
    return 1
  fi
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

# ==================== 布局迁移（FHS 收敛，与版本号无关） ====================
# 说明：项目自有文件收敛到 /etc/debnas、/var/lib/debnas、/var/log/debnas 等同名目录后，
#       旧位置的文件需要搬过去。规则：旧路径存在且新路径不存在时搬迁；全部幂等，
#       每次 migration_run 都会执行（不依赖版本号变化），单项失败只告警不中断。
#       设置 DEBNAS_SKIP_LAYOUT_MIGRATION=1 可跳过（测试用）。

# 旧版威胁 IP 数据目录 / 日志
DEBNAS_LEGACY_THREAT_IPS_DIR="${DEBNAS_LEGACY_THREAT_IPS_DIR:-/var/lib/firewalld-ipthreat}"
DEBNAS_LEGACY_THREAT_IPS_LOG="${DEBNAS_LEGACY_THREAT_IPS_LOG:-/var/log/firewalld-ipthreat.log}"

# 威胁 IP：/var/lib/firewalld-ipthreat → /var/lib/debnas/threat-ips，
#          /var/log/firewalld-ipthreat.log → /var/log/debnas/threat-ips.log
# 返回：0 成功或无需迁移，1 部分失败
migration_layout_threat_ips() {
  local old_dir="$DEBNAS_LEGACY_THREAT_IPS_DIR"
  local new_dir="${DEBNAS_VAR_DIR}/threat-ips"
  local old_log="$DEBNAS_LEGACY_THREAT_IPS_LOG"
  local new_log="${DEBNAS_LOG_ROOT}/threat-ips.log"
  local rc=0

  if [[ -n "$old_dir" && -d "$old_dir" && ! -L "$old_dir" ]]; then
    # 很早期的版本由 crontab 直接调用数据目录里的脚本：搬走会让该定时任务失效，保留并提示
    if crontab -l 2>/dev/null | grep -qF "${old_dir}/"; then
      log_warning "crontab 仍引用 ${old_dir}，暂不迁移；请运行 debnas run threat-ips 重新启用后再执行 debnas update"
      rc=1
    elif [[ ! -e "$new_dir" ]]; then
      if mkdir -p -- "$(dirname -- "$new_dir")" 2>/dev/null && mv -- "$old_dir" "$new_dir" 2>/dev/null; then
        log_info "已迁移威胁 IP 数据目录：${old_dir} → ${new_dir}"
      else
        log_warning "迁移威胁 IP 数据目录失败：${old_dir} → ${new_dir}"
        rc=1
      fi
    else
      # 新目录已存在：逐个搬入新目录中没有的文件，搬空后删除旧目录
      local entry name
      for entry in "$old_dir"/* "$old_dir"/.[!.]*; do
        [[ -e "$entry" || -L "$entry" ]] || continue
        name="${entry##*/}"
        [[ -n "$name" ]] || continue
        if [[ ! -e "${new_dir}/${name}" ]]; then
          mv -- "$entry" "${new_dir}/${name}" 2>/dev/null || rc=1
        fi
      done
      if ! rmdir -- "$old_dir" 2>/dev/null; then
        log_warning "旧威胁 IP 数据目录非空，已保留：${old_dir}"
      fi
    fi
  fi

  if [[ -n "$old_log" && -f "$old_log" && ! -L "$old_log" && ! -e "$new_log" ]]; then
    if mkdir -p -- "$DEBNAS_LOG_ROOT" 2>/dev/null && mv -- "$old_log" "$new_log" 2>/dev/null; then
      log_info "已迁移威胁 IP 日志：${old_log} → ${new_log}"
    else
      log_warning "迁移威胁 IP 日志失败：${old_log} → ${new_log}"
      rc=1
    fi
  fi
  return "$rc"
}

# 通知邮箱：/etc/exim4/notify_email → /etc/debnas/notify_email（640 root），
#           旧路径改为指向新路径的符号链接（兼容一个版本，供旧登录脚本/外部脚本读取）
# 返回：0 成功或无需迁移，1 失败
migration_layout_notify_email() {
  local old="$DEBNAS_LEGACY_NOTIFY_EMAIL_FILE" new="$DEBNAS_NOTIFY_EMAIL_FILE"
  if [[ -n "$old" && -f "$old" && ! -L "$old" && ! -e "$new" ]]; then
    debnas_backup_file "$old" >/dev/null 2>&1 || true
    if ! mkdir -p -- "$(dirname -- "$new")" 2>/dev/null || ! cp -p -- "$old" "$new" 2>/dev/null; then
      log_warning "迁移通知邮箱失败：${old} → ${new}"
      return 1
    fi
    chmod 640 -- "$new" 2>/dev/null || true
    chown root:root -- "$new" 2>/dev/null || true
    log_info "已迁移通知邮箱：${old} → ${new}"
  fi
  if [[ -f "$new" && -f "$old" && ! -L "$old" ]]; then
    if ! layout_link_legacy_notify_email; then
      log_warning "无法把 ${old} 替换为指向 ${new} 的符号链接"
      return 1
    fi
    manifest_add "$old" || true
  fi
  return 0
}

# 登录通知脚本：/etc/pam.d/login-notify.sh → /usr/local/libexec/debnas/login-notify.sh，
#               同步把 common-session 的 pam_exec 行改为新路径（原位替换，不留两条）
# 返回：0 成功或无需迁移，1 失败
migration_layout_login_notify() {
  local old="$DEBNAS_LEGACY_LOGIN_NOTIFY_SCRIPT" new="$DEBNAS_LOGIN_NOTIFY_SCRIPT"
  local pam="$DEBNAS_PAM_SESSION_FILE" rc=0

  if [[ -n "$old" && -f "$old" && ! -L "$old" && ! -e "$new" ]]; then
    local new_dir
    new_dir=$(dirname -- "$new")
    # 先复制，PAM 行切换成功后再删除旧脚本，保证任意时刻 PAM 引用的脚本都存在
    if mkdir -p -- "$new_dir" 2>/dev/null && cp -p -- "$old" "$new" 2>/dev/null; then
      chmod 755 -- "$new_dir" 2>/dev/null || true
      chmod 750 -- "$new" 2>/dev/null || true
      chown root:root -- "$new" 2>/dev/null || true
      log_info "已迁移登录通知脚本：${old} → ${new}"
    else
      log_warning "迁移登录通知脚本失败：${old} → ${new}"
      return 1
    fi
  fi

  if [[ -f "$new" ]] && login_notify_pam_references "$old" "$pam"; then
    local prc=0
    login_notify_pam_sync "$new" "$pam" || prc=$?
    if [[ "$prc" -eq 2 ]]; then
      log_warning "更新 ${pam} 中的登录通知行失败，仍使用旧脚本 ${old}"
      return 1
    fi
    log_info "已更新 ${pam} 登录通知行 → ${new}"
  fi

  if [[ -n "$old" && -f "$old" && ! -L "$old" && -f "$new" ]] && ! login_notify_pam_references "$old" "$pam"; then
    debnas_backup_file "$old" >/dev/null 2>&1 || true
    if rm -f -- "$old" 2>/dev/null; then
      manifest_add "$old" || true
    else
      log_warning "删除旧登录通知脚本失败：${old}"
      rc=1
    fi
  fi
  return "$rc"
}

# 执行全部布局迁移（幂等；失败只告警）
# 返回：始终 0
migration_run_layout() {
  if [[ "${DEBNAS_SKIP_LAYOUT_MIGRATION:-0}" == "1" ]]; then
    return 0
  fi
  # 依赖 layout.sh / backup.sh / manifest.sh（bootstrap-core.sh 加载）；单独 source 本文件时跳过
  if ! declare -F login_notify_pam_sync >/dev/null 2>&1 \
    || ! declare -F debnas_backup_file >/dev/null 2>&1 \
    || ! declare -F manifest_add >/dev/null 2>&1; then
    return 0
  fi
  local DEBNAS_MANIFEST_SOURCE="${DEBNAS_MANIFEST_SOURCE:-migration}"
  migration_layout_threat_ips || log_warning "威胁 IP 文件布局迁移未完成"
  migration_layout_notify_email || log_warning "通知邮箱布局迁移未完成"
  migration_layout_login_notify || log_warning "登录通知脚本布局迁移未完成"
  return 0
}

# ==================== 公共接口 ====================

# 检查并执行版本迁移
# 参数：无（使用 DEBNAS_VERSION 环境变量）
# 返回：0 成功（含无需迁移），1 迁移失败
# 说明：在 cmd_update 完成后调用，检测版本变化并执行迁移；
#       文件布局迁移（migration_run_layout）幂等且与版本号无关，每次都会先执行
migration_run() {
  local current_version="${DEBNAS_VERSION:-unknown}"
  local installed_version
  installed_version=$(_get_installed_version)

  # 布局迁移：首次记录版本的老安装（无版本文件）同样可能有旧路径文件，因此放在版本判断之前
  migration_run_layout

  # 首次安装或版本未知：仅记录版本，不执行迁移
  if [[ -z "$installed_version" ]]; then
    _save_version "$current_version" || log_warning "版本状态写入失败，下次启动会再次尝试迁移检查"
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
  _save_version "$current_version" || log_warning "版本状态写入失败，下次启动会再次尝试迁移检查"

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

  # 检查旧文件布局残留（由 migration_run_layout 迁移，debnas update 时自动执行）
  if [[ -d "$DEBNAS_LEGACY_THREAT_IPS_DIR" ]]; then
    log_warning "旧版威胁 IP 数据目录未迁移：${DEBNAS_LEGACY_THREAT_IPS_DIR}"
    issues=$((issues + 1))
  fi
  if [[ -n "${DEBNAS_LEGACY_NOTIFY_EMAIL_FILE:-}" && -f "$DEBNAS_LEGACY_NOTIFY_EMAIL_FILE" && ! -L "$DEBNAS_LEGACY_NOTIFY_EMAIL_FILE" ]]; then
    log_warning "通知邮箱仍在旧位置：${DEBNAS_LEGACY_NOTIFY_EMAIL_FILE}（新位置 ${DEBNAS_NOTIFY_EMAIL_FILE}）"
    issues=$((issues + 1))
  fi
  if declare -F login_notify_pam_references >/dev/null 2>&1 \
    && login_notify_pam_references "$DEBNAS_LEGACY_LOGIN_NOTIFY_SCRIPT"; then
    log_warning "${DEBNAS_PAM_SESSION_FILE} 仍引用旧登录通知脚本：${DEBNAS_LEGACY_LOGIN_NOTIFY_SCRIPT}"
    issues=$((issues + 1))
  fi

  if [[ "$issues" -gt 0 ]]; then
    log_warning "发现 ${issues} 个兼容性问题"
    return 1
  fi

  return 0
}
