#!/bin/bash
# @module: login-mail
# @name: 登录邮件通知
# @category: 通知服务
# @depends: exim4
# @depend_modules: mail-account
# @version: 1.0.0
# @order: 61
# @interactive: true
# 功能：配置用户登录邮件通知（启用/禁用）

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/bootstrap.sh"

# ==================== 只读探测契约（docs/ARCHITECTURE.md §4.5） ====================

# 通知邮箱是否可用：输出 set / unset / noperm（文件存在但当前用户无权读取）
_login_mail_notify_state() {
  local f
  if notify_email_get >/dev/null 2>&1; then
    echo "set"
    return 0
  fi
  for f in "$DEBNAS_NOTIFY_EMAIL_FILE" "$DEBNAS_LEGACY_NOTIFY_EMAIL_FILE"; do
    [[ -n "$f" && -e "$f" ]] || continue
    [[ -r "$f" ]] || { echo "noperm"; return 0; }
    break
  done
  echo "unset"
}

# 当前状态：一行 "状态码|说明"（只读、< 300ms、不联网）
module_status() {
  local pam="$DEBNAS_PAM_SESSION_FILE" script="$DEBNAS_LOGIN_NOTIFY_SCRIPT"
  local legacy="$DEBNAS_LEGACY_LOGIN_NOTIFY_SCRIPT"
  if [[ ! -r "$pam" ]]; then
    echo "unknown|无法读取 ${pam}"
    return 0
  fi
  local has_new=0 has_legacy=0
  login_notify_pam_references "$script" "$pam" && has_new=1
  login_notify_pam_references "$legacy" "$pam" && has_legacy=1

  if [[ "$has_legacy" -eq 1 ]]; then
    echo "warn|PAM 仍引用旧路径 ${legacy}（重新启用会迁移到 ${script}）"
    return 0
  fi
  if [[ "$has_new" -eq 1 ]]; then
    if [[ ! -f "$script" ]]; then
      echo "error|PAM 已引用但脚本 ${script} 不存在，通知不会发送（optional，不影响登录）"
      return 0
    fi
    case "$(_login_mail_notify_state)" in
      unset)  echo "warn|已启用，但未设置通知邮箱，不会发送" ;;
      noperm) echo "applied|已启用 · PAM 调用 ${script}（通知邮箱需 root 查看）" ;;
      *)      echo "applied|已启用 · PAM 调用 ${script}" ;;
    esac
    return 0
  fi
  if [[ -f "$script" ]]; then
    echo "partial|脚本 ${script} 存在，但 ${pam} 无 pam_exec 行（未生效）"
    return 0
  fi
  echo "absent|未启用"
}

# 预演：每行 "类型|目标|备注"（无副作用；交互式模块，列出菜单两个动作的影响范围）
module_plan() {
  local pam="$DEBNAS_PAM_SESSION_FILE" script="$DEBNAS_LOGIN_NOTIFY_SCRIPT"
  local legacy="$DEBNAS_LEGACY_LOGIN_NOTIFY_SCRIPT" script_dir
  script_dir=$(dirname -- "$script")

  echo "info|动作范围|交互菜单：启用 / 禁用登录邮件通知（cron 模式不适用）"
  command -v exim4 >/dev/null 2>&1 \
    || echo "risk|exim4|未安装 exim4：执行前置检查会拦截，需先安装并运行「配置邮件账户」"
  [[ "$(_login_mail_notify_state)" == "unset" ]] \
    && echo "risk|通知邮箱|未设置 ${DEBNAS_NOTIFY_EMAIL_FILE}：启用会失败，先运行「配置邮件账户」"

  # 启用
  [[ -d "$script_dir" ]] || echo "write|${script_dir}/|启用：创建目录（755 root）"
  echo "write|${script}|启用：生成登录通知脚本（750 root）；内容变化时原件备份到 /var/backups/debnas/"
  if [[ -r "$pam" ]] && login_notify_pam_references "$script" "$pam" \
    && ! login_notify_pam_references "$legacy" "$pam"; then
    echo "info|${pam}|启用：pam_exec 行已存在，不改动"
  else
    echo "write|${pam}|启用：统一为一条 pam_exec 行（旧路径行原位替换）；原件备份到 /var/backups/debnas/"
  fi
  [[ -f "$legacy" ]] \
    && echo "write|${legacy}|启用：旧位置脚本不再被引用时备份到 /var/backups/debnas/ 后删除"

  # 禁用
  echo "write|${pam}|禁用：移除新旧两种路径的 pam_exec 行；原件备份到 /var/backups/debnas/"
  echo "write|${script}|禁用：直接删除脚本（旧位置 ${legacy} 同样删除），不另做备份"

  echo "info|隐私|默认不查询登录 IP 归属地（debnas.conf 设 login_mail_geoip=1 才会请求 ip-api.com）"
  echo "risk|PAM|修改 ${pam}（所有登录会话都会加载）；该行为 session optional，脚本立即返回、邮件在后台发送，发送失败不阻断登录；但该文件若被改坏可能影响登录，建议执行时保留一个已登录的 root 会话"
  return 0
}

main() {
  source "${SCRIPT_DIR}/lib/system/state.sh"
  source "${MODULE_DIR}/actions.sh"

  local -a items=("启用登录邮件通知" "禁用登录邮件通知")
  while true; do
    local choice exit_code menu_result
    menu_result=$(mktemp)
    UI_MENU_BLANK_BEFORE=1 UI_MENU_BACK_LABEL="← 返回上级" UI_MENU_RESULT_FILE="$menu_result" ui_menu "登录邮件通知" "${items[@]}" || {
      exit_code=$?
      rm -f "$menu_result"
      case $exit_code in
        254) return 0 ;;   # Esc：返回上级
        255) return 0 ;;   # Q：退出
        *)   continue ;;
      esac
    }
    choice=$(cat "$menu_result")
    rm -f "$menu_result"
    case "$choice" in
      0) enable_login_mail ;;
      1) disable_login_mail ;;
    esac
  done
}

# 契约守卫：DEBNAS_MODULE_ACTION=status|plan 时只加载函数供只读探测，不执行 main（docs/ARCHITECTURE.md §4.5）
if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi
