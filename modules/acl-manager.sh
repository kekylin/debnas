#!/bin/bash
# 功能：ACL权限管理工具（交互式菜单，支持批量、递归、用户/组/默认ACL等操作）

set -euo pipefail
IFS=$'\n\t'

# 加载公共库，确保依赖函数和常量可用
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/core/constants.sh"
source "${SCRIPT_DIR}/lib/core/logging.sh"
source "${SCRIPT_DIR}/lib/system/dependency.sh"
source "${SCRIPT_DIR}/lib/ui/menu.sh"
source "${SCRIPT_DIR}/lib/ui/styles.sh"

# 临时文件管理，避免并发冲突和数据泄露
mkdir -p /tmp/debian-homenas
chmod 700 /tmp/debian-homenas
ACL_OUTPUT=$(mktemp /tmp/debian-homenas/acl-output.XXXXXX)
trap 'rm -f "$ACL_OUTPUT"' EXIT

# 日志文件路径
LOG_FILE="/var/log/homenas_acl_manager.log"

# 检查依赖，自动安装缺失的ACL工具
REQUIRED_CMDS=(getfacl setfacl)
if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
  log_warning "检测到ACL工具缺失，尝试自动安装..."
  apt update && apt install -y acl
  if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
    log_fail "ACL工具安装失败。请手动安装acl软件包后重试。"
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
    log_fail "无效权限。请输入r、w、x的组合（如rwx、rw、-）。"
    return 1
  fi
}

# 查看ACL权限，输出到临时文件
view_acl() {
  print_prompt "请输入文件或目录路径: "
  read -r path
  if [ ! -e "$path" ]; then
    log_error "文件或目录 $path 不存在，请检查路径。"
    return
  fi
  getfacl "$path" 2>&1 | tee "$ACL_OUTPUT"
  log_acl_action "查看ACL: $path"
}

# 为用户设置ACL权限
set_user_acl() {
  print_prompt "请输入文件或目录路径: "
  read -r path
  if [ ! -e "$path" ]; then
    log_error "文件或目录 $path 不存在，请检查路径。"
    return
  fi
  print_prompt "请输入用户名: "
  read -r username
  print_prompt "请输入权限（如rwx）: "
  read -r permissions
  if ! validate_permissions "$permissions"; then return; fi
  print_prompt "是否递归设置？(y/n): "
  read -r recursive
  print_warning "将为用户 $username 设置 $permissions 权限于 $path，确认操作？(y/n): "
  read -r confirm
  if [[ "$confirm" != "y" ]]; then
    log_info "操作已取消。"
    return
  fi
  if [[ "$recursive" == "y" ]]; then
    if setfacl -R -m u:"$username":"$permissions" "$path" 2>&1 | tee "$ACL_OUTPUT"; then
      log_success "已为用户 $username 设置权限 $permissions。"
      log_acl_action "设置用户ACL: u:$username:$permissions $path (递归: $recursive)"
    else
      log_error "无法设置权限。请检查输入或查看 $ACL_OUTPUT。"
    fi
  else
    if setfacl -m u:"$username":"$permissions" "$path" 2>&1 | tee "$ACL_OUTPUT"; then
      log_success "已为用户 $username 设置权限 $permissions。"
      log_acl_action "设置用户ACL: u:$username:$permissions $path (递归: $recursive)"
    else
      log_error "无法设置权限。请检查输入或查看 $ACL_OUTPUT。"
    fi
  fi
}

# 为组设置ACL权限
set_group_acl() {
  print_prompt "请输入文件或目录路径: "
  read -r path
  if [ ! -e "$path" ]; then
    log_error "文件或目录 $path 不存在，请检查路径。"
    return
  fi
  print_prompt "请输入组名: "
  read -r groupname
  print_prompt "请输入权限（如rwx）: "
  read -r permissions
  if ! validate_permissions "$permissions"; then return; fi
  print_prompt "是否递归设置？(y/n): "
  read -r recursive
  print_warning "将为组 $groupname 设置 $permissions 权限于 $path，确认操作？(y/n): "
  read -r confirm
  if [[ "$confirm" != "y" ]]; then
    log_info "操作已取消。"
    return
  fi
  if [[ "$recursive" == "y" ]]; then
    if setfacl -R -m g:"$groupname":"$permissions" "$path" 2>&1 | tee "$ACL_OUTPUT"; then
      log_success "已为组 $groupname 设置权限 $permissions。"
      log_acl_action "设置组ACL: g:$groupname:$permissions $path (递归: $recursive)"
    else
      log_error "无法设置权限。请检查输入或查看 $ACL_OUTPUT。"
    fi
  else
    if setfacl -m g:"$groupname":"$permissions" "$path" 2>&1 | tee "$ACL_OUTPUT"; then
      log_success "已为组 $groupname 设置权限 $permissions。"
      log_acl_action "设置组ACL: g:$groupname:$permissions $path (递归: $recursive)"
    else
      log_error "无法设置权限。请检查输入或查看 $ACL_OUTPUT。"
    fi
  fi
}

# 设置目录的默认ACL权限
set_default_acl() {
  print_prompt "请输入目录路径: "
  read -r path
  if [ ! -d "$path" ]; then
    log_error "目录 $path 不存在，请检查路径。"
    return
  fi
  print_prompt "请输入用户或组（u:username 或 g:groupname）: "
  read -r entry
  print_prompt "请输入权限（如rwx）: "
  read -r permissions
  if ! validate_permissions "$permissions"; then return; fi
  print_warning "将为目录 $path 设置默认ACL $entry:$permissions，确认操作？(y/n): "
  read -r confirm
  if [[ "$confirm" != "y" ]]; then
    log_info "操作已取消。"
    return
  fi
  if setfacl -d -m "$entry":"$permissions" "$path" 2>&1 | tee "$ACL_OUTPUT"; then
    log_success "已为目录 $path 设置默认ACL权限。"
    log_acl_action "设置默认ACL: $entry:$permissions $path"
  else
    log_error "无法设置默认ACL权限。请检查输入或查看 $ACL_OUTPUT。"
  fi
}

# 取消目录的默认ACL权限
remove_default_acl() {
  print_prompt "请输入目录路径: "
  read -r path
  if [ ! -d "$path" ]; then
    log_error "目录 $path 不存在，请检查路径。"
    return
  fi
  print_warning "将取消目录 $path 的默认ACL，确认操作？(y/n): "
  read -r confirm
  if [[ "$confirm" != "y" ]]; then
    log_info "操作已取消。"
    return
  fi
  if setfacl -k "$path" 2>&1 | tee "$ACL_OUTPUT"; then
    log_success "已取消目录 $path 的默认ACL权限。"
    log_acl_action "取消默认ACL: $path"
  else
    log_error "无法取消默认ACL权限。请检查输入或查看 $ACL_OUTPUT。"
  fi
}

# 删除ACL权限
remove_acl() {
  print_prompt "请输入文件或目录路径: "
  read -r path
  if [ ! -e "$path" ]; then
    log_error "文件或目录 $path 不存在，请检查路径。"
    return
  fi
  print_prompt "请输入要删除的ACL条目（u:username 或 g:groupname）: "
  read -r entry
  print_prompt "是否递归删除？(y/n): "
  read -r recursive
  print_warning "将删除 $entry 的ACL于 $path，确认操作？(y/n): "
  read -r confirm
  if [[ "$confirm" != "y" ]]; then
    log_info "操作已取消。"
    return
  fi
  if [[ "$recursive" == "y" ]]; then
    if setfacl -R -x "$entry" "$path" 2>&1 | tee "$ACL_OUTPUT"; then
      log_success "已删除ACL条目 $entry。"
      log_acl_action "删除ACL: $entry $path (递归: $recursive)"
    else
      log_error "无法删除ACL条目。请检查输入或查看 $ACL_OUTPUT。"
    fi
  else
    if setfacl -x "$entry" "$path" 2>&1 | tee "$ACL_OUTPUT"; then
      log_success "已删除ACL条目 $entry。"
      log_acl_action "删除ACL: $entry $path (递归: $recursive)"
    else
      log_error "无法删除ACL条目。请检查输入或查看 $ACL_OUTPUT。"
    fi
  fi
}

# 批量设置ACL权限
batch_set_acl() {
  print_prompt "请输入文件或目录路径（支持通配符，如 *.txt）: "
  read -r pattern
  print_prompt "请输入用户或组（u:username 或 g:groupname）: "
  read -r entry
  print_prompt "请输入权限（如rwx）: "
  read -r permissions
  if ! validate_permissions "$permissions"; then return; fi
  print_prompt "是否递归设置？(y/n): "
  read -r recursive
  print_warning "将为匹配 $pattern 的文件设置 $entry:$permissions，确认操作？(y/n): "
  read -r confirm
  if [[ "$confirm" != "y" ]]; then
    log_info "操作已取消。"
    return
  fi
  shopt -s nullglob
  for path in $pattern; do
    if [ ! -e "$path" ]; then
      log_warn "$path 不存在，已跳过。"
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

# 菜单
show_acl_menu() {
  show_menu_with_border "请选择ACL操作" \
    "查看ACL权限" \
    "设置用户ACL" \
    "设置组ACL" \
    "设置默认ACL" \
    "取消默认ACL" \
    "删除ACL" \
    "批量设置ACL"
}

# 主循环
main() {
  local menu_options=(
    "查看ACL权限"
    "设置用户ACL"
    "设置组ACL"
    "设置默认ACL"
    "取消默认ACL"
    "删除ACL"
    "批量设置ACL"
  )
  while true; do
    show_acl_menu
    choice=$(get_user_choice ${#menu_options[@]})
    case $choice in
      1) view_acl ;;
      2) set_user_acl ;;
      3) set_group_acl ;;
      4) set_default_acl ;;
      5) remove_default_acl ;;
      6) remove_acl ;;
      7) batch_set_acl ;;
      0) log_action "返回"; return 0 ;;
    esac
    echo ""
    sleep 1
  done
}

main 