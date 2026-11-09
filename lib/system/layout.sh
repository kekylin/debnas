#!/bin/bash
# 功能：DebNAS 文件布局常量（FHS 同名目录）+ 通知邮箱读写 + 登录通知 PAM 行维护
# 说明：项目自有文件统一放在 /etc/debnas、/var/lib/debnas、/var/log/debnas、/opt/debnas、
#       /var/backups/debnas、/usr/local/libexec/debnas；系统程序必须从固定位置读取的配置
#       （/etc/hosts、firewalld、fail2ban、ssh、apt、pam.d 等）原地修改，不在此列。
#       常量均为 ${VAR:-默认} 形式（不设 readonly），便于测试以普通用户覆盖到 /tmp。
# 依赖: core/logging.sh（由 bootstrap-core.sh 加载）；写文件时使用 utils.sh 的 write_file_if_changed

set -euo pipefail
IFS=$'\n\t'

# ==================== 目录常量 ====================

DEBNAS_ETC_DIR="${DEBNAS_ETC_DIR:-/etc/debnas}"                     # 配置
DEBNAS_VAR_DIR="${DEBNAS_VAR_DIR:-/var/lib/debnas}"                 # 状态/数据/报告
DEBNAS_LOG_ROOT="${DEBNAS_LOG_ROOT:-/var/log/debnas}"               # 日志
DEBNAS_OPT_DIR="${DEBNAS_OPT_DIR:-/opt/debnas}"                     # 程序
DEBNAS_BACKUP_ROOT="${DEBNAS_BACKUP_ROOT:-/var/backups/debnas}"     # 集中备份
DEBNAS_LIBEXEC_DIR="${DEBNAS_LIBEXEC_DIR:-/usr/local/libexec/debnas}" # 供系统程序回调的辅助脚本
DEBNAS_MANIFEST_FILE="${DEBNAS_MANIFEST_FILE:-${DEBNAS_VAR_DIR}/manifest}"

# ==================== 文件常量 ====================

# 系统通知收件邮箱（mail-account 写入；login-mail / ops-report / sys-patches / fail2ban 读取）
DEBNAS_NOTIFY_EMAIL_FILE="${DEBNAS_NOTIFY_EMAIL_FILE:-${DEBNAS_ETC_DIR}/notify_email}"
# 旧位置（v3 及以前）：读取时作为回退，保留一个版本后移除
DEBNAS_LEGACY_NOTIFY_EMAIL_FILE="${DEBNAS_LEGACY_NOTIFY_EMAIL_FILE:-/etc/exim4/notify_email}"

# PAM 登录通知脚本（由 pam_exec 调用）
DEBNAS_LOGIN_NOTIFY_SCRIPT="${DEBNAS_LOGIN_NOTIFY_SCRIPT:-${DEBNAS_LIBEXEC_DIR}/login-notify.sh}"
DEBNAS_LEGACY_LOGIN_NOTIFY_SCRIPT="${DEBNAS_LEGACY_LOGIN_NOTIFY_SCRIPT:-/etc/pam.d/login-notify.sh}"
DEBNAS_PAM_SESSION_FILE="${DEBNAS_PAM_SESSION_FILE:-/etc/pam.d/common-session}"

# ==================== 通知邮箱 ====================

# 读取通知收件邮箱（取首行并去掉空白）
# 参数：无
# 输出：邮箱地址
# 返回：0 已配置，1 未配置/为空
# 说明：新路径不存在时回退旧路径 /etc/exim4/notify_email（兼容一个版本）
notify_email_get() {
  local f email=""
  for f in "$DEBNAS_NOTIFY_EMAIL_FILE" "$DEBNAS_LEGACY_NOTIFY_EMAIL_FILE"; do
    [[ -n "$f" && -f "$f" && -r "$f" ]] || continue
    email=$(head -n 1 -- "$f" 2>/dev/null | tr -d '[:space:]') || email=""
    if [[ -n "$email" ]]; then
      printf '%s' "$email"
      return 0
    fi
    # 新路径存在但为空：视为未配置，不再回退旧路径
    return 1
  done
  return 1
}

# 返回当前生效的通知邮箱文件路径（用于提示信息）
# 输出：新路径存在时输出新路径；否则旧路径存在时输出旧路径；都不存在输出新路径
notify_email_file() {
  if [[ -f "$DEBNAS_NOTIFY_EMAIL_FILE" ]]; then
    printf '%s' "$DEBNAS_NOTIFY_EMAIL_FILE"
  elif [[ -f "$DEBNAS_LEGACY_NOTIFY_EMAIL_FILE" ]]; then
    printf '%s' "$DEBNAS_LEGACY_NOTIFY_EMAIL_FILE"
  else
    printf '%s' "$DEBNAS_NOTIFY_EMAIL_FILE"
  fi
}

# 写入通知收件邮箱（权限 640，属主 root）
# 参数：$1 - 邮箱地址
# 返回：0 已写入或未变更，1 失败
# 说明：旧路径若仍是普通文件，替换为指向新路径的符号链接，避免旧脚本读到过期地址
notify_email_set() {
  local email="${1:-}"
  if [[ -z "$email" ]]; then
    log_error "notify_email_set: 邮箱地址为空"
    return 1
  fi
  local rc=0
  write_file_if_changed "$DEBNAS_NOTIFY_EMAIL_FILE" "$email" 640 1 || rc=$?
  if [[ "$rc" -eq 2 ]]; then
    return 1
  fi
  # 已存在文件 write_file_if_changed 不改属主；这里显式收紧（普通用户测试时 chown 失败忽略）
  chmod 640 -- "$DEBNAS_NOTIFY_EMAIL_FILE" 2>/dev/null || true
  chown root:root -- "$DEBNAS_NOTIFY_EMAIL_FILE" 2>/dev/null || true
  layout_link_legacy_notify_email || true
  return 0
}

# 把旧通知邮箱路径替换为指向新路径的符号链接（幂等）
# 返回：0 已是链接/已替换/无需处理，1 失败
layout_link_legacy_notify_email() {
  local legacy="$DEBNAS_LEGACY_NOTIFY_EMAIL_FILE" target="$DEBNAS_NOTIFY_EMAIL_FILE"
  [[ -n "$legacy" && -n "$target" && -f "$target" ]] || return 0
  if [[ -L "$legacy" ]]; then
    return 0
  fi
  # 旧位置所在目录不存在（如未安装 exim4）：不创建
  [[ -d "$(dirname -- "$legacy")" ]] || return 0
  if [[ -e "$legacy" ]]; then
    [[ -f "$legacy" ]] || return 0
    if declare -F debnas_backup_file >/dev/null 2>&1; then
      debnas_backup_file "$legacy" || true
    fi
    rm -f -- "$legacy" || return 1
  fi
  ln -s -- "$target" "$legacy" || return 1
  return 0
}

# ==================== 登录通知 PAM 行 ====================

# 生成 pam_exec 行
# 参数：$1 - 脚本路径
_layout_pam_notify_line() {
  printf 'session optional pam_exec.so debug /bin/bash %s' "$1"
}

# 把 PAM 文件中的登录通知行统一为指向指定脚本的单一一行（幂等）
# 参数：$1 - 目标脚本路径（空字符串表示移除所有登录通知行）
#       $2 - PAM 文件（可选，默认 DEBNAS_PAM_SESSION_FILE）
# 返回：0 已变更，1 未变更，2 失败
# 说明：识别新旧两种脚本路径的行；旧行原位替换为新行，多余的重复行删除，不会留下两条
login_notify_pam_sync() {
  local script="${1-}"
  local pam_file="${2:-$DEBNAS_PAM_SESSION_FILE}"
  local new_line="" line content="" inserted=0 changed=0
  local old_a old_b
  old_a=$(_layout_pam_notify_line "$DEBNAS_LEGACY_LOGIN_NOTIFY_SCRIPT")
  old_b=$(_layout_pam_notify_line "$DEBNAS_LOGIN_NOTIFY_SCRIPT")
  [[ -z "$script" ]] || new_line=$(_layout_pam_notify_line "$script")

  if [[ ! -f "$pam_file" ]]; then
    [[ -n "$script" ]] || return 1
    log_error "PAM 文件不存在：${pam_file}"
    return 2
  fi

  local -a lines=()
  mapfile -t lines < "$pam_file" || return 2
  for line in "${lines[@]}"; do
    # 只比较去掉首尾空白后的整行，避免误伤注释或其他 pam_exec 行
    local trimmed="${line#"${line%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    if [[ "$trimmed" == "$old_a" || "$trimmed" == "$old_b" || ( -n "$new_line" && "$trimmed" == "$new_line" ) ]]; then
      if [[ -n "$new_line" && "$inserted" -eq 0 ]]; then
        content+="${new_line}"$'\n'
        inserted=1
        [[ "$line" == "$new_line" ]] || changed=1
      else
        changed=1
      fi
      continue
    fi
    content+="${line}"$'\n'
  done
  if [[ -n "$new_line" && "$inserted" -eq 0 ]]; then
    content+="${new_line}"$'\n'
    changed=1
  fi
  [[ "$changed" -eq 1 ]] || return 1
  if [[ -z "${content//[[:space:]]/}" ]]; then
    log_error "拒绝把 PAM 文件写成空文件：${pam_file}"
    return 2
  fi
  # write_file_if_changed 会补一个结尾换行
  content="${content%$'\n'}"
  local rc=0
  write_file_if_changed "$pam_file" "$content" "" 1 || rc=$?
  return "$rc"
}

# 判断 PAM 文件是否仍引用指定脚本
# 参数：$1 - 脚本路径；$2 - PAM 文件（可选）
# 返回：0 引用，1 未引用
login_notify_pam_references() {
  local script="$1" pam_file="${2:-$DEBNAS_PAM_SESSION_FILE}"
  [[ -f "$pam_file" ]] || return 1
  _DEBNAS_PAM_LINE="$(_layout_pam_notify_line "$script")" awk '
    BEGIN { want = ENVIRON["_DEBNAS_PAM_LINE"]; found = 0 }
    { line = $0; sub(/^[[:space:]]+/, "", line); sub(/[[:space:]]+$/, "", line) }
    line == want { found = 1 }
    END { exit(found ? 0 : 1) }
  ' "$pam_file" 2>/dev/null
}
