#!/bin/bash
# 功能：交互菜单系统
# 说明：使用 discover_modules() 自动发现模块并生成菜单
# 兼容：保留与 bin/main.sh 一致的交互体验

set -euo pipefail
IFS=$'\n\t'

# 获取项目根目录
_DEBNAS_SCRIPT="$(readlink -f "${BASH_SOURCE[0]}")"
_DEBNAS_ROOT="$(cd "$(dirname "${_DEBNAS_SCRIPT}")/.." && pwd)"

# 加载统一库
source "${_DEBNAS_ROOT}/lib/bootstrap.sh"

# ==================== 常量定义 ====================

# 分类显示顺序
declare -a MENU_CATEGORY_ORDER=(
  "基础系统"
  "管理面板"
  "安全防护"
  "容器管理"
  "通知服务"
  "系统工具"
  "一键部署"
)

# 兼容映射：旧分类名 → 新分类名
# 当前 bin/main.sh 中使用的分类名与新分类名的映射
declare -A CATEGORY_COMPAT=(
  ["基础配置"]="基础系统"
  ["管理面板"]="管理面板"
  ["安全防护"]="安全防护"
  ["容器管理"]="容器管理"
  ["通知服务"]="通知服务"
  ["系统工具"]="系统工具"
  ["一键部署"]="一键部署"
)

# ==================== 菜单数据 ====================

# 当前菜单模式：auto（自动发现）或 compat（兼容旧菜单）
declare -g MENU_MODE="compat"

# 兼容模式下的模块配置（从 bin/main.sh 移植）
declare -A COMPAT_MODULE_DESC COMPAT_MENU_MAP
declare -a COMPAT_MENU_ORDER

# 初始化兼容模式配置
init_compat_config() {
  COMPAT_MODULE_DESC=(
    [s11]="configure-sources|配置软件源"
    [s12]="install-basic-tools|安装基础工具"
    [w11]="install-cockpit|安装 Cockpit"
    [w12]="install-vm-components|安装虚拟机"
    [w13]="enable-cockpit-external|启用外网访问"
    [w14]="disable-cockpit-external|禁用外网访问"
    [w15]="set-cockpit-network|面板管理网络"
    [w16]="cockpit-auto-bing-wallpaper|面板必应壁纸"
    [m11]="setup-mail-account|配置邮件账户"
    [m12]="enable-login-mail|启用登录通知"
    [m13]="disable-login-mail|禁用登录通知"
    [a11]="configure-security|基础安全配置"
    [a12]="install-firewall|安装 Firewalld"
    [a13]="install-fail2ban|安装 Fail2ban"
    [a14]="block-threat-ips|IP 封禁工具"
    [d11]="install-docker-ce|安装 Docker"
    [d12]="add-docker-mirror|镜像加速"
    [d13]="install-docker-apps|安装应用"
    [d14]="backup-restore|备份恢复"
    [t11]="check-system-compatibility|检查兼容性"
    [t12]="check-system-updates|检查系统更新"
    [t13]="install-service-query|查询服务状态"
    [t14]="auto-update-hosts|更新 Hosts 文件"
    [t15]="install-tunnel|安装 Tailscale"
    [t16]="acl-manager|ACL 权限管理"
    [t17]="bbr-algo-manager|BBR 算法管理"
    [q11]="setup-homenas-basic|一键部署基础环境"
    [q12]="setup-homenas-secure|一键部署安全环境"
  )

  COMPAT_MENU_MAP=(
    ["基础配置"]="s11 s12"
    ["管理面板"]="w11 w12 w13 w14 w15 w16"
    ["通知服务"]="m11 m12 m13"
    ["安全防护"]="a11 a12 a13 a14"
    ["容器管理"]="d11 d12 d13 d14"
    ["系统工具"]="t11 t12 t13 t14 t15 t16 t17"
    ["一键部署"]="q11 q12"
  )

  COMPAT_MENU_ORDER=(
    "基础配置"
    "管理面板"
    "通知服务"
    "安全防护"
    "容器管理"
    "系统工具"
    "一键部署"
  )
}

# ==================== 横幅和菜单显示 ====================

# 显示项目横幅
print_banner() {
  print_separator "="
  print_banner_text "                     DebNAS"
  print_banner_text "                                  QQ群：339169752"
  print_banner_text "作者：kekylin"
  print_banner_text "项目：https://github.com/kekylin/debnas"
  print_separator "-"
  print_title "温馨提示"
  print_title "·一键部署适合自动配置环境，也可按选择单项功能"
  print_title "·安装防火墙后需重启系统以确保服务正常"
  print_separator "="
}

# ==================== 兼容模式菜单 ====================

# 显示兼容模式主菜单
show_compat_main_menu() {
  print_banner
  local i
  for i in "${!COMPAT_MENU_ORDER[@]}"; do
    print_main_menu_item "$((i+1))" "${COMPAT_MENU_ORDER[$i]}"
  done
  print_menu_item "0" "退出" "true"
  print_separator "="
}

# 显示兼容模式子菜单
show_compat_sub_menu() {
  local group="$1"
  local -a items
  IFS=' ' read -ra items <<< "${COMPAT_MENU_MAP[$group]}"

  print_submenu_title "$group"
  local idx=1
  for key in "${items[@]}"; do
    local desc="${COMPAT_MODULE_DESC[$key]}"
    local zh_desc="${desc#*|}"
    print_menu_item "$idx" "$zh_desc"
    ((idx++))
  done
  print_menu_item "0" "返回" "true"
  print_separator "-"
  print_multiselect_prompt
}

# 执行兼容模式选择的模块
execute_compat_modules() {
  local group="$1"
  shift
  local -a selected_keys=("$@")

  for key in "${selected_keys[@]}"; do
    if [[ -z "${COMPAT_MODULE_DESC[$key]+_}" ]]; then
      log_fail "未找到标识 $key 的描述，已跳过"
      continue
    fi
    local desc="${COMPAT_MODULE_DESC[$key]}"
    local script_name="${desc%%|*}"
    local zh_desc="${desc#*|}"
    local mod_path="${_DEBNAS_ROOT}/modules/${script_name}.sh"

    if [[ ! -f "$mod_path" ]]; then
      log_fail "模块 \"$zh_desc\" 不存在，已跳过"
      continue
    fi

    log_action "正在执行模块：\"$zh_desc\""
    if ! (unset _DEBNAS_BOOTSTRAPPED; bash "$mod_path"); then
      log_fail "模块 \"$zh_desc\" 执行失败，已中断"
      break
    fi
    log_success "模块 \"$zh_desc\" 执行完成"
  done
}

# 兼容模式子菜单处理
handle_compat_sub_menu() {
  local group="$1"
  local -a items
  IFS=' ' read -ra items <<< "${COMPAT_MENU_MAP[$group]}"

  while true; do
    show_compat_sub_menu "$group"
    print_prompt "请选择编号: "
    read -r sub_choices

    [[ -z "$sub_choices" ]] && {
      log_fail "输入为空，请重新输入"
      continue
    }

    local -a choices_array
    IFS=' ' read -ra choices_array <<< "$sub_choices"

    # 验证输入
    local valid=true
    for choice in "${choices_array[@]}"; do
      if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
        log_fail "仅支持数字编号"
        valid=false
        break
      fi
    done
    [[ "$valid" == "false" ]] && continue

    # 处理返回
    [[ " $sub_choices " =~ " 0 " ]] && break

    # 收集选择
    local -a selected=()
    for choice in "${choices_array[@]}"; do
      if [[ "$choice" -ge 1 && "$choice" -le "${#items[@]}" ]]; then
        selected+=("${items[$((choice-1))]}")
      fi
    done

    if [[ ${#selected[@]} -eq 0 ]]; then
      log_fail "无效选择，请重新输入"
      continue
    fi

    execute_compat_modules "$group" "${selected[@]}"
    break
  done
}

# 兼容模式主循环
compat_menu_loop() {
  while true; do
    show_compat_main_menu
    print_prompt "请选择编号: "
    read -r main_choice

    if ! [[ "$main_choice" =~ ^[0-9]+$ ]]; then
      log_fail "请输入数字编号"
      continue
    fi

    if [[ "$main_choice" == "0" ]]; then
      log_action "用户选择退出"
      exit 0
    fi

    if [[ "$main_choice" -lt 1 || "$main_choice" -gt "${#COMPAT_MENU_ORDER[@]}" ]]; then
      log_fail "无效选择"
      continue
    fi

    local group="${COMPAT_MENU_ORDER[$((main_choice-1))]}"
    handle_compat_sub_menu "$group"
  done
}

# ==================== 自动发现模式菜单 ====================

# 构建当前有效分类列表（只包含有模块的分类）
declare -a ACTIVE_CATEGORIES=()

build_active_categories() {
  ACTIVE_CATEGORIES=()
  for category in "${MENU_CATEGORY_ORDER[@]}"; do
    local -a modules
    mapfile -t modules < <(get_modules_by_category "$category" 2>/dev/null)
    if [[ ${#modules[@]} -gt 0 ]]; then
      ACTIVE_CATEGORIES+=("$category")
    fi
  done
}

# 显示自动发现模式的主菜单
show_auto_main_menu() {
  print_banner

  local i
  for i in "${!ACTIVE_CATEGORIES[@]}"; do
    print_main_menu_item "$((i+1))" "${ACTIVE_CATEGORIES[$i]}"
  done

  print_menu_item "0" "退出" "true"
  print_separator "="
}

# 显示自动发现模式的子菜单
show_auto_sub_menu() {
  local category="$1"
  local -a modules
  mapfile -t modules < <(get_modules_by_category "$category" 2>/dev/null)

  print_submenu_title "$category"
  local idx=1
  for module_name in "${modules[@]}"; do
    local display_name
    display_name=$(get_module_field "$module_name" "name" "$module_name" 2>/dev/null) || display_name="$module_name"
    print_menu_item "$idx" "$display_name"
    ((idx++))
  done
  print_menu_item "0" "返回" "true"
  print_separator "-"
  print_multiselect_prompt
}

# 执行自动发现模式选择的模块
execute_auto_modules() {
  local category="$1"
  shift
  local -a selected_modules=("$@")

  for module_name in "${selected_modules[@]}"; do
    local display_name
    display_name=$(get_module_field "$module_name" "name" "$module_name" 2>/dev/null) || display_name="$module_name"
    local mod_path
    mod_path=$(get_module_path "$module_name" 2>/dev/null) || {
      log_fail "模块 \"$display_name\" 路径不存在，已跳过"
      continue
    }

    log_action "正在执行模块：\"$display_name\""
    if ! (unset _DEBNAS_BOOTSTRAPPED; bash "$mod_path"); then
      log_fail "模块 \"$display_name\" 执行失败，已中断"
      break
    fi
    log_success "模块 \"$display_name\" 执行完成"
  done
}

# 自动发现模式子菜单处理
handle_auto_sub_menu() {
  local category="$1"
  local -a modules
  mapfile -t modules < <(get_modules_by_category "$category" 2>/dev/null)

  while true; do
    show_auto_sub_menu "$category"
    print_prompt "请选择编号: "
    read -r sub_choices

    [[ -z "$sub_choices" ]] && {
      log_fail "输入为空，请重新输入"
      continue
    }

    local -a choices_array
    IFS=' ' read -ra choices_array <<< "$sub_choices"

    # 验证输入
    local valid=true
    for choice in "${choices_array[@]}"; do
      if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
        log_fail "仅支持数字编号"
        valid=false
        break
      fi
    done
    [[ "$valid" == "false" ]] && continue

    # 处理返回
    [[ " $sub_choices " =~ " 0 " ]] && break

    # 收集选择
    local -a selected=()
    for choice in "${choices_array[@]}"; do
      if [[ "$choice" -ge 1 && "$choice" -le "${#modules[@]}" ]]; then
        selected+=("${modules[$((choice-1))]}")
      fi
    done

    if [[ ${#selected[@]} -eq 0 ]]; then
      log_fail "无效选择，请重新输入"
      continue
    fi

    execute_auto_modules "$category" "${selected[@]}"
    break
  done
}

# 自动发现模式主循环
auto_menu_loop() {
  build_active_categories

  while true; do
    show_auto_main_menu
    print_prompt "请选择编号: "
    read -r main_choice

    if ! [[ "$main_choice" =~ ^[0-9]+$ ]]; then
      log_fail "请输入数字编号"
      continue
    fi

    if [[ "$main_choice" == "0" ]]; then
      log_action "用户选择退出"
      exit 0
    fi

    if [[ "$main_choice" -lt 1 || "$main_choice" -gt "${#ACTIVE_CATEGORIES[@]}" ]]; then
      log_fail "无效选择"
      continue
    fi

    local category="${ACTIVE_CATEGORIES[$((main_choice-1))]}"
    handle_auto_sub_menu "$category"
  done
}

# ==================== 环境设置 ====================

# 设置临时目录和信号处理
setup_environment() {
  init_temp_dir
  _MENU_TMP_DIR=$(mktemp -d "${DEBNAS_TMP_BASE}/menu.XXXXXX")
  chmod 755 "$_MENU_TMP_DIR"
  trap 'log_warning "用户中断操作"; rm -rf "$_MENU_TMP_DIR"; exit 1' INT
  trap 'rm -rf "$_MENU_TMP_DIR"' EXIT
}

# ==================== 主入口 ====================

main() {
  clear 2>/dev/null || true
  init_compat_config
  setup_environment

  # 系统检查
  if ! verify_system_support 2>/dev/null; then
    exit "${ERROR_UNSUPPORTED_OS}"
  fi

  # 发现模块并使用自动发现模式
  discover_modules 2>/dev/null
  auto_menu_loop
}

main "$@"
