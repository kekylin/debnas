#!/bin/bash
# @module: acl-manager
# @name: ACL 权限管理
# @category: 系统工具
# @depends: getfacl,setfacl
# @version: 1.0.0
# @order: 75
# @interactive: true
# 功能：ACL权限管理工具（交互式菜单，支持批量、递归、用户/组/默认ACL等操作）

set -euo pipefail
IFS=$'\n\t'

# 加载公共库，确保依赖函数和常量可用
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/bootstrap.sh"

# 临时文件管理
register_temp_cleanup
ACL_OUTPUT=$(create_temp_file "acl-output")
_ACL_FAILED=0

# 日志文件路径
LOG_FILE="/var/log/debnas/acl-manager.log"

# 记录ACL操作日志，便于审计和问题追踪
log_acl_action() {
  local action="$1"
  local timestamp
  timestamp=$(date "+%Y-%m-%d %H:%M:%S")
  echo "[$timestamp] $action" >> "$LOG_FILE" 2>/dev/null || log_warning "无法写入日志文件 $LOG_FILE"
}

# 记录 ACL 操作失败并标记模块最终返回非零
acl_error() {
  log_error "$@"
  _ACL_FAILED=1
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

# 系统目录（含子路径）禁止设置 ACL：误操作（尤其递归）会破坏系统权限
readonly -a ACL_PROTECTED_DIRS=(/bin /boot /dev /etc /lib /lib32 /lib64 /libx32 /proc /root /run /sbin /sys /usr /var)

# 校验目标路径不是根目录或系统目录（按 realpath 解析符号链接后判断）
validate_acl_path() {
  local path="$1" real dir
  real=$(realpath -m -- "$path" 2>/dev/null) || real="$path"
  if [[ "$real" == "/" ]]; then
    log_error "拒绝对根目录 / 设置 ACL"
    return 1
  fi
  for dir in "${ACL_PROTECTED_DIRS[@]}"; do
    if [[ "$real" == "$dir" || "$real" == "$dir"/* ]]; then
      log_error "拒绝对系统目录设置 ACL：$path（解析为 $real）"
      return 1
    fi
  done
  return 0
}

# 校验用户名/组名：只允许合法名称字符且必须存在，防止注入 ","、":" 追加额外 ACL 条目
# 参数：$1 - user|group，$2 - 名称
validate_acl_principal() {
  local kind="$1" name="$2" db="passwd" label="用户"
  if [[ "$kind" == "group" ]]; then
    db="group"
    label="组"
  fi
  if [[ ! "$name" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*\$?$ ]]; then
    log_error "无效的${label}名：$name"
    return 1
  fi
  if ! getent "$db" "$name" >/dev/null 2>&1; then
    log_error "${label} $name 不存在"
    return 1
  fi
  return 0
}

# 校验 u:name / g:name 形式的 ACL 条目
validate_acl_entry() {
  local entry="$1"
  if [[ "$entry" =~ ^u:(.+)$ ]]; then
    validate_acl_principal user "${BASH_REMATCH[1]}"
  elif [[ "$entry" =~ ^g:(.+)$ ]]; then
    validate_acl_principal group "${BASH_REMATCH[1]}"
  else
    log_error "无效的 ACL 条目：$entry（格式应为 u:用户名 或 g:组名）"
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
  getfacl "$path" 2>&1 | tee "$ACL_OUTPUT" || log_error "读取 $path 的 ACL 失败"
  log_acl_action "查看ACL: $path"
  module_mark_action
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
  if ! validate_acl_path "$path"; then return; fi
  username=$(ui_input "请输入用户名")
  [[ -z "$username" ]] && { log_info "已取消"; return; }
  if ! validate_acl_principal user "$username"; then return; fi
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
      module_mark_action
      log_acl_action "设置用户ACL: u:$username:$permissions $path (递归: $recursive)"
    else
      acl_error "无法设置权限。请检查输入或查看 $ACL_OUTPUT。"
    fi
  else
    if setfacl -m u:"$username":"$permissions" "$path" 2>&1 | tee "$ACL_OUTPUT"; then
      log_success "ACL: u:$username:$permissions $path"
      module_mark_action
      log_acl_action "设置用户ACL: u:$username:$permissions $path (递归: $recursive)"
    else
      acl_error "无法设置权限。请检查输入或查看 $ACL_OUTPUT。"
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
  if ! validate_acl_path "$path"; then return; fi
  groupname=$(ui_input "请输入组名")
  [[ -z "$groupname" ]] && { log_info "已取消"; return; }
  if ! validate_acl_principal group "$groupname"; then return; fi
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
      module_mark_action
      log_acl_action "设置组ACL: g:$groupname:$permissions $path (递归: $recursive)"
    else
      acl_error "无法设置权限。请检查输入或查看 $ACL_OUTPUT。"
    fi
  else
    if setfacl -m g:"$groupname":"$permissions" "$path" 2>&1 | tee "$ACL_OUTPUT"; then
      log_success "ACL: g:$groupname:$permissions $path"
      module_mark_action
      log_acl_action "设置组ACL: g:$groupname:$permissions $path (递归: $recursive)"
    else
      acl_error "无法设置权限。请检查输入或查看 $ACL_OUTPUT。"
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
  if ! validate_acl_path "$path"; then return; fi
  entry=$(ui_input "请输入用户或组 (u:username 或 g:groupname)")
  [[ -z "$entry" ]] && { log_info "已取消"; return; }
  if ! validate_acl_entry "$entry"; then return; fi
  permissions=$(ui_input "请输入权限 (如 rwx)" "rwx")
  [[ -z "$permissions" ]] && { log_info "已取消"; return; }
  if ! validate_permissions "$permissions"; then return; fi

  [[ "$(ui_confirm "设置默认ACL权限？" "目录: $path\n条目: $entry\n权限: $permissions")" == "0" ]] || {
    log_info "已取消"
    return
  }
  if setfacl -d -m "$entry":"$permissions" "$path" 2>&1 | tee "$ACL_OUTPUT"; then
    log_success "ACL 默认: $path"
    module_mark_action
    log_acl_action "设置默认ACL: $entry:$permissions $path"
  else
    acl_error "无法设置默认ACL权限。请检查输入或查看 $ACL_OUTPUT。"
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
  if ! validate_acl_path "$path"; then return; fi

  [[ "$(ui_confirm "取消默认ACL权限？" "将取消目录 $path 的默认ACL")" == "0" ]] || {
    log_info "已取消"
    return
  }
  if setfacl -k "$path" 2>&1 | tee "$ACL_OUTPUT"; then
    log_success "ACL 默认取消: $path"
    module_mark_action
    log_acl_action "取消默认ACL: $path"
  else
    acl_error "无法取消默认ACL权限。请检查输入或查看 $ACL_OUTPUT。"
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
  if ! validate_acl_path "$path"; then return; fi
  entry=$(ui_input "请输入要删除的ACL条目 (u:username 或 g:groupname)")
  [[ -z "$entry" ]] && { log_info "已取消"; return; }
  if ! validate_acl_entry "$entry"; then return; fi
  recursive=$(ui_input "是否递归删除？(y/n)" "n")

  [[ "$(ui_confirm "删除ACL权限？" "路径: $path\n条目: $entry\n递归: $recursive")" == "0" ]] || {
    log_info "已取消"
    return
  }
  if [[ "$recursive" == "y" ]]; then
    if setfacl -R -x "$entry" "$path" 2>&1 | tee "$ACL_OUTPUT"; then
      log_success "ACL 删除: $entry"
      module_mark_action
      log_acl_action "删除ACL: $entry $path (递归: $recursive)"
    else
      acl_error "无法删除ACL条目。请检查输入或查看 $ACL_OUTPUT。"
    fi
  else
    if setfacl -x "$entry" "$path" 2>&1 | tee "$ACL_OUTPUT"; then
      log_success "ACL 删除: $entry"
      module_mark_action
      log_acl_action "删除ACL: $entry $path (递归: $recursive)"
    else
      acl_error "无法删除ACL条目。请检查输入或查看 $ACL_OUTPUT。"
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
  if ! validate_acl_entry "$entry"; then return; fi
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
    if ! validate_acl_path "$path"; then
      continue
    fi
    if [[ "$recursive" == "y" ]]; then
      if setfacl -R -m "$entry":"$permissions" "$path" 2>&1 | tee -a "$ACL_OUTPUT"; then
        log_success "已为 $path 设置 $entry:$permissions"
        module_mark_action
        log_acl_action "批量设置ACL: $entry:$permissions $path (递归: $recursive)"
      else
        acl_error "无法为 $path 设置权限，请查看 $ACL_OUTPUT。"
      fi
    else
      if setfacl -m "$entry":"$permissions" "$path" 2>&1 | tee -a "$ACL_OUTPUT"; then
        log_success "已为 $path 设置 $entry:$permissions"
        module_mark_action
        log_acl_action "批量设置ACL: $entry:$permissions $path (递归: $recursive)"
      else
        acl_error "无法为 $path 设置权限，请查看 $ACL_OUTPUT。"
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
    "查看 ACL 权限"
    "设置用户 ACL"
    "设置组 ACL"
    "设置默认 ACL"
    "取消默认 ACL"
    "删除 ACL"
    "批量设置 ACL"
  )
  local choice exit_code menu_result
  while true; do
    menu_result=$(mktemp)
    UI_MENU_BLANK_BEFORE=1 UI_MENU_BACK_LABEL="← 返回上级" UI_MENU_RESULT_FILE="$menu_result" ui_menu "ACL 权限管理" "${items[@]}" || {
      exit_code=$?
      rm -f "$menu_result"
      case $exit_code in
        254) return "$_ACL_FAILED" ;;   # Esc：返回上级
        255) return "$_ACL_FAILED" ;;   # Q：退出
        *)   return "$_ACL_FAILED" ;;
      esac
    }
    choice=$(cat "$menu_result")
    rm -f "$menu_result"

    case $choice in
      0) ensure_module_deps acl-manager || continue; view_acl ;;
      1) ensure_module_deps acl-manager || continue; set_user_acl ;;
      2) ensure_module_deps acl-manager || continue; set_group_acl ;;
      3) ensure_module_deps acl-manager || continue; set_default_acl ;;
      4) ensure_module_deps acl-manager || continue; remove_default_acl ;;
      5) ensure_module_deps acl-manager || continue; remove_acl ;;
      6) ensure_module_deps acl-manager || continue; batch_set_acl ;;
    esac
    echo ""
    sleep 1
  done
}

main "$@"
