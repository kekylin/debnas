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

# 临时文件管理：register_temp_cleanup 与 ACL_OUTPUT 的创建在 main 中执行（只读探测时顶层无副作用）
ACL_OUTPUT=""
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

# 执行 setfacl，输出同时写入 ACL_OUTPUT，并记录成功/失败
# 参数：$1 - tee 选项（-a 追加，空为覆盖），$2 - 成功提示，$3 - 审计日志内容，$4 - 失败提示，其余 - setfacl 参数
_acl_run() {
  local tee_opt="$1" ok_msg="$2" audit_msg="$3" fail_msg="$4"
  shift 4
  if setfacl "$@" 2>&1 | tee ${tee_opt:+"$tee_opt"} "$ACL_OUTPUT"; then
    log_success "$ok_msg"
    module_mark_action
    log_acl_action "$audit_msg"
  else
    acl_error "$fail_msg"
  fi
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
  if [[ ! -e "$path" ]]; then
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
  if [[ ! -e "$path" ]]; then
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
  local -a rflag=()
  [[ "$recursive" == "y" ]] && rflag=(-R)
  _acl_run "" "ACL: u:$username:$permissions $path" \
    "设置用户ACL: u:$username:$permissions $path (递归: $recursive)" \
    "无法设置权限。请检查输入或查看 $ACL_OUTPUT。" \
    "${rflag[@]}" -m u:"$username":"$permissions" "$path"
}

# 为组设置ACL权限
set_group_acl() {
  local path groupname permissions recursive
  path=$(ui_input "请输入文件或目录路径")
  [[ -z "$path" ]] && { log_info "已取消"; return; }
  if [[ ! -e "$path" ]]; then
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
  local -a rflag=()
  [[ "$recursive" == "y" ]] && rflag=(-R)
  _acl_run "" "ACL: g:$groupname:$permissions $path" \
    "设置组ACL: g:$groupname:$permissions $path (递归: $recursive)" \
    "无法设置权限。请检查输入或查看 $ACL_OUTPUT。" \
    "${rflag[@]}" -m g:"$groupname":"$permissions" "$path"
}

# 设置目录的默认ACL权限
set_default_acl() {
  local path entry permissions
  path=$(ui_input "请输入目录路径")
  [[ -z "$path" ]] && { log_info "已取消"; return; }
  if [[ ! -d "$path" ]]; then
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
  _acl_run "" "ACL 默认: $path" "设置默认ACL: $entry:$permissions $path" \
    "无法设置默认ACL权限。请检查输入或查看 $ACL_OUTPUT。" \
    -d -m "$entry":"$permissions" "$path"
}

# 取消目录的默认ACL权限
remove_default_acl() {
  local path
  path=$(ui_input "请输入目录路径")
  [[ -z "$path" ]] && { log_info "已取消"; return; }
  if [[ ! -d "$path" ]]; then
    log_error "目录 $path 不存在，请检查路径。"
    return
  fi
  if ! validate_acl_path "$path"; then return; fi

  [[ "$(ui_confirm "取消默认ACL权限？" "将取消目录 $path 的默认ACL")" == "0" ]] || {
    log_info "已取消"
    return
  }
  _acl_run "" "ACL 默认取消: $path" "取消默认ACL: $path" \
    "无法取消默认ACL权限。请检查输入或查看 $ACL_OUTPUT。" \
    -k "$path"
}

# 删除ACL权限
remove_acl() {
  local path entry recursive
  path=$(ui_input "请输入文件或目录路径")
  [[ -z "$path" ]] && { log_info "已取消"; return; }
  if [[ ! -e "$path" ]]; then
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
  local -a rflag=()
  [[ "$recursive" == "y" ]] && rflag=(-R)
  _acl_run "" "ACL 删除: $entry" "删除ACL: $entry $path (递归: $recursive)" \
    "无法删除ACL条目。请检查输入或查看 $ACL_OUTPUT。" \
    "${rflag[@]}" -x "$entry" "$path"
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
  local path
  local -a rflag=()
  [[ "$recursive" == "y" ]] && rflag=(-R)
  shopt -s nullglob
  for path in $pattern; do
    if [[ ! -e "$path" ]]; then
      log_warning "$path 不存在，已跳过。"
      continue
    fi
    validate_acl_path "$path" || continue
    _acl_run -a "已为 $path 设置 $entry:$permissions" \
      "批量设置ACL: $entry:$permissions $path (递归: $recursive)" \
      "无法为 $path 设置权限，请查看 $ACL_OUTPUT。" \
      "${rflag[@]}" -m "$entry":"$permissions" "$path"
  done
  shopt -u nullglob
}

# ==================== 只读探测契约（docs/ARCHITECTURE.md §4.5） ====================

# 当前状态：一行 "状态码|说明"（工具型模块：反映 ACL 工具是否可用）
module_status() {
  local ver=""
  ver=$(dpkg-query -W -f='${db:Status-Status} ${Version}' acl 2>/dev/null) || ver=""
  if [[ "$ver" != installed* ]] || ! command -v setfacl &>/dev/null; then
    echo "absent|未安装 acl 软件包（首次操作时自动安装）"
    return 0
  fi
  local n=""
  if [[ -r "$LOG_FILE" ]]; then
    n=$(grep -c . "$LOG_FILE" 2>/dev/null || true)
    echo "applied|ACL 工具可用（acl ${ver#installed }）· 操作日志 ${n:-0} 条"
  else
    echo "applied|ACL 工具可用（acl ${ver#installed }）"
  fi
}

# 预演：每行 "类型|目标|备注"（交互式模块：列出可能的动作范围）
module_plan() {
  local IFS=$' \n\t'   # 全局 IFS 不含空格，拼接数组前需局部设置
  if ! pkg_is_installed acl; then
    echo "pkg|acl|首次选择操作时按 @depends 安装"
  fi
  echo "info|acl-manager|交互式菜单，需逐项输入路径/用户或组/权限并确认：查看 / 设置用户 ACL / 设置组 ACL / 设置默认 ACL / 取消默认 ACL / 删除 ACL / 批量设置"
  echo "write|用户指定的文件或目录|setfacl 修改扩展权限（可选递归）；不另做备份，如需回滚请先 getfacl -R 导出"
  echo "info|系统目录保护|拒绝对 / 及 ${ACL_PROTECTED_DIRS[*]} 下的路径设置 ACL"
  echo "write|${LOG_FILE}|追加操作审计日志"
  echo "risk|递归操作|递归设置/删除会作用于整棵目录树，无法自动撤销"
  return 0
}

# 主循环
main() {
  if [[ "${DEBNAS_CRON_MODE:-0}" -eq 1 ]]; then
    log_info "cron 模式下不支持交互操作，已跳过"
    return 0
  fi
  register_temp_cleanup
  ACL_OUTPUT=$(create_temp_file "acl-output")
  local -a items=(
    "查看 ACL 权限"
    "设置用户 ACL"
    "设置组 ACL"
    "设置默认 ACL"
    "取消默认 ACL"
    "删除 ACL"
    "批量设置 ACL"
  )
  local choice menu_result
  while true; do
    menu_result=$(mktemp)
    # ui_menu 非零（254 Esc 返回上级 / 255 Q 退出等）均结束菜单
    UI_MENU_BLANK_BEFORE=1 UI_MENU_BACK_LABEL="← 返回上级" UI_MENU_RESULT_FILE="$menu_result" ui_menu "ACL 权限管理" "${items[@]}" || {
      rm -f "$menu_result"
      return "$_ACL_FAILED"
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

# 契约守卫：DEBNAS_MODULE_ACTION=status|plan 时只加载函数供只读探测，不执行 main（docs/ARCHITECTURE.md §4.5）
if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi
