#!/bin/bash
# @module: acl-manager
# @name: ACL 权限
# @category: 系统工具
# @depends: getfacl,setfacl
# @version: 1.0.0
# @order: 75
# 功能：ACL权限管理工具（交互式菜单，支持批量、递归、用户/组/默认ACL等操作）

set -euo pipefail
IFS=$'\n\t'

# 加载公共库，确保依赖函数和常量可用
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/bootstrap.sh"

# 临时文件管理
register_temp_cleanup
ACL_OUTPUT=$(create_temp_file "acl-output")

# 日志文件路径
LOG_FILE="/var/log/debnas/acl-manager.log"

# 检查依赖，自动安装缺失的ACL工具
REQUIRED_CMDS=(getfacl setfacl)
if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
  log_warning "ACL 工具缺失"
  apt_install_packages acl
  if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
    log_error "ACL工具安装失败。请手动安装acl软件包后重试。"
    exit "${ERROR_DEPENDENCY}"
  fi
fi

# 记录ACL操作日志，便于审计和问题追踪
log_acl_action() {
  local action="$1"
  local timestamp
  timestamp=$(date "+%Y-%m-%d %H:%M:%S")
  echo "[$timestamp] $action" >> "$LOG_FILE" 2>/dev/null || log_warning "无法写入日志文件 $LOG_FILE"
}

# 验证权限字符串格式，防止无效输入
validate_permissions() {
  local perms="$1"
  if [[ "$perms" =~ ^[rwx-]{0,3}$ ]]; then
    return 0
  else
    log_error "无效权限"
    return 1
  fi
}

# 查看ACL权限，输出到临时文件
view_acl() {
  local path
  path=$(ui_input "请输入文件或目录路径")
  [[ -z "$path" ]] && { log_info "已取消"; return; }
  if [ ! -e "$path" ]; then
    log_error "$path 不存在"
    return
  fi
  getfacl "$path" 2>&1 | tee "$ACL_OUTPUT"
  log_acl_action "查看ACL: $path"
}

# 为用户设置ACL权限
set_user_acl() {
  local path username permissions recursive
  path=$(ui_input "请输入文件或目录路径")
  [[ -z "$path" ]] && { log_info "已取消"; return; }
  if [ ! -e "$path" ]; then
    log_error "$path 不存在"
    return
  fi
  username=$(ui_input "请输入用户名")
  [[ -z "$username" ]] && { log_info "已取消"; return; }
  permissions=$(ui_input "请输入权限 (如 rwx)" "rwx")
  [[ -z "$permissions" ]] && { log_info "已取消"; return; }
  if ! validate_permissions "$permissions"; then return; fi
  recursive=$(ui_input "是否递归设置？(y/n)" "n")

  [[ "$(ui_confirm "为用户设置ACL权限？" "路径: $path\n用户: $username\n权限: $permissions\n递归: $recursive")" == "0" ]] || {
    log_info "已取消"
    return
  }
  if [[ "$recursive" == "y" ]]; then
    if setfacl -R -m u:"$username":"$permissions" "$path" 2>&1 | tee "$ACL_OUTPUT"; then
      log_success "ACL: u:$username:$permissions $path"
      log_acl_action "设置用户ACL: u:$username:$permissions $path (递归: $recursive)"
    else
      log_error "无法设置权限。请检查输入或查看 $ACL_OUTPUT。"
    fi
  else
    if setfacl -m u:"$username":"$permissions" "$path" 2>&1 | tee "$ACL_OUTPUT"; then
      log_success "ACL: u:$username:$permissions $path"
      log_acl_action "设置用户ACL: u:$username:$permissions $path (递归: $recursive)"
    else
      log_error "无法设置权限。请检查输入或查看 $ACL_OUTPUT。"
    fi
  fi
}

# 为组设置ACL权限
set_group_acl() {
  local path groupname permissions recursive
  path=$(ui_input "请输入文件或目录路径")
  [[ -z "$path" ]] && { log_info "已取消"; return; }
  if [ ! -e "$path" ]; then
    log_error "$path 不存在"
    return
  fi
  groupname=$(ui_input "请输入组名")
  [[ -z "$groupname" ]] && { log_info "已取消"; return; }
  permissions=$(ui_input "请输入权限 (如 rwx)" "rwx")
  [[ -z "$permissions" ]] && { log_info "已取消"; return; }
  if ! validate_permissions "$permissions"; then return; fi
  recursive=$(ui_input "是否递归设置？(y/n)" "n")

  [[ "$(ui_confirm "为组设置ACL权限？" "路径: $path\n组: $groupname\n权限: $permissions\n递归: $recursive")" == "0" ]] || {
    log_info "已取消"
    return
  }
  if [[ "$recursive" == "y" ]]; then
    if setfacl -R -m g:"$groupname":"$permissions" "$path" 2>&1 | tee "$ACL_OUTPUT"; then
      log_success "ACL: g:$groupname:$permissions $path"
      log_acl_action "设置组ACL: g:$groupname:$permissions $path (递归: $recursive)"
    else
      log_error "无法设置权限。请检查输入或查看 $ACL_OUTPUT。"
    fi
  else
    if setfacl -m g:"$groupname":"$permissions" "$path" 2>&1 | tee "$ACL_OUTPUT"; then
      log_success "ACL: g:$groupname:$permissions $path"
      log_acl_action "设置组ACL: g:$groupname:$permissions $path (递归: $recursive)"
    else
      log_error "无法设置权限。请检查输入或查看 $ACL_OUTPUT。"
    fi
  fi
}

# 设置目录的默认ACL权限
set_default_acl() {
  local path entry permissions
  path=$(ui_input "请输入目录路径")
  [[ -z "$path" ]] && { log_info "已取消"; return; }
  if [ ! -d "$path" ]; then
    log_error "目录 $path 不存在，请检查路径。"
    return
  fi
  entry=$(ui_input "请输入用户或组 (u:username 或 g:groupname)")
  [[ -z "$entry" ]] && { log_info "已取消"; return; }
  permissions=$(ui_input "请输入权限 (如 rwx)" "rwx")
  [[ -z "$permissions" ]] && { log_info "已取消"; return; }
  if ! validate_permissions "$permissions"; then return; fi

  [[ "$(ui_confirm "设置默认ACL权限？" "目录: $path\n条目: $entry\n权限: $permissions")" == "0" ]] || {
    log_info "已取消"
    return
  }
  if setfacl -d -m "$entry":"$permissions" "$path" 2>&1 | tee "$ACL_OUTPUT"; then
    log_success "ACL 默认: $path"
    log_acl_action "设置默认ACL: $entry:$permissions $path"
  else
    log_error "无法设置默认ACL权限。请检查输入或查看 $ACL_OUTPUT。"
  fi
}

# 取消目录的默认ACL权限
remove_default_acl() {
  local path
  path=$(ui_input "请输入目录路径")
  [[ -z "$path" ]] && { log_info "已取消"; return; }
  if [ ! -d "$path" ]; then
    log_error "目录 $path 不存在，请检查路径。"
    return
  fi

  [[ "$(ui_confirm "取消默认ACL权限？" "将取消目录 $path 的默认ACL")" == "0" ]] || {
    log_info "已取消"
    return
  }
  if setfacl -k "$path" 2>&1 | tee "$ACL_OUTPUT"; then
    log_success "ACL 默认取消: $path"
    log_acl_action "取消默认ACL: $path"
  else
    log_error "无法取消默认ACL权限。请检查输入或查看 $ACL_OUTPUT。"
  fi
}

# 删除ACL权限
remove_acl() {
  local path entry recursive
  path=$(ui_input "请输入文件或目录路径")
  [[ -z "$path" ]] && { log_info "已取消"; return; }
  if [ ! -e "$path" ]; then
    log_error "$path 不存在"
    return
  fi
  entry=$(ui_input "请输入要删除的ACL条目 (u:username 或 g:groupname)")
  [[ -z "$entry" ]] && { log_info "已取消"; return; }
  recursive=$(ui_input "是否递归删除？(y/n)" "n")

  [[ "$(ui_confirm "删除ACL权限？" "路径: $path\n条目: $entry\n递归: $recursive")" == "0" ]] || {
    log_info "已取消"
    return
  }
  if [[ "$recursive" == "y" ]]; then
    if setfacl -R -x "$entry" "$path" 2>&1 | tee "$ACL_OUTPUT"; then
      log_success "ACL 删除: $entry"
      log_acl_action "删除ACL: $entry $path (递归: $recursive)"
    else
      log_error "无法删除ACL条目。请检查输入或查看 $ACL_OUTPUT。"
    fi
  else
    if setfacl -x "$entry" "$path" 2>&1 | tee "$ACL_OUTPUT"; then
      log_success "ACL 删除: $entry"
      log_acl_action "删除ACL: $entry $path (递归: $recursive)"
    else
      log_error "无法删除ACL条目。请检查输入或查看 $ACL_OUTPUT。"
    fi
  fi
}

# 批量设置ACL权限
batch_set_acl() {
  local pattern entry permissions recursive
  pattern=$(ui_input "请输入匹配模式 (如 *.txt)")
  [[ -z "$pattern" ]] && { log_info "已取消"; return; }
  entry=$(ui_input "请输入用户或组 (u:username 或 g:groupname)")
  [[ -z "$entry" ]] && { log_info "已取消"; return; }
  permissions=$(ui_input "请输入权限 (如 rwx)" "rwx")
  [[ -z "$permissions" ]] && { log_info "已取消"; return; }
  if ! validate_permissions "$permissions"; then return; fi
  recursive=$(ui_input "是否递归设置？(y/n)" "n")

  [[ "$(ui_confirm "批量设置ACL权限？" "匹配: $pattern\n条目: $entry\n权限: $permissions\n递归: $recursive")" == "0" ]] || {
    log_info "已取消"
    return
  }
  shopt -s nullglob
  for path in $pattern; do
    if [ ! -e "$path" ]; then
      log_warning "$path 不存在，已跳过。"
      continue
    fi
    if [[ "$recursive" == "y" ]]; then
      if setfacl -R -m "$entry":"$permissions" "$path" 2>&1 | tee -a "$ACL_OUTPUT"; then
        log_success "已为 $path 设置 $entry:$permissions"
        log_acl_action "批量设置ACL: $entry:$permissions $path (递归: $recursive)"
      else
        log_error "无法为 $path 设置权限，请查看 $ACL_OUTPUT。"
      fi
    else
      if setfacl -m "$entry":"$permissions" "$path" 2>&1 | tee -a "$ACL_OUTPUT"; then
        log_success "已为 $path 设置 $entry:$permissions"
        log_acl_action "批量设置ACL: $entry:$permissions $path (递归: $recursive)"
      else
        log_error "无法为 $path 设置权限，请查看 $ACL_OUTPUT。"
      fi
    fi
  done
  shopt -u nullglob
}

# 主循环
main() {
  if [[ "${DEBNAS_CRON_MODE:-0}" -eq 1 ]]; then
    log_info "cron 模式下不支持交互操作，已跳过"
    return 0
  fi
  local -a items=(
    "查看ACL权限"
    "设置用户ACL"
    "设置组ACL"
    "设置默认ACL"
    "取消默认ACL"
    "删除ACL"
    "批量设置ACL"
  )
  local choice exit_code
  while true; do
    choice=$(UI_MENU_BACK_LABEL="← 返回上级" ui_menu "ACL 权限" "${items[@]}") || {
      exit_code=$?
      case $exit_code in
        254) return 0 ;;   # Esc：返回上级
        255) return 0 ;;   # Q：退出
        *)   return 0 ;;
      esac
    }

    case $choice in
      0) view_acl ;;
      1) set_user_acl ;;
      2) set_group_acl ;;
      3) set_default_acl ;;
      4) remove_default_acl ;;
      5) remove_acl ;;
      6) batch_set_acl ;;
    esac
    echo ""
    sleep 1
  done
}

main "$@"