#!/bin/bash
# 功能：主入口脚本，支持交互式主菜单/子菜单/多选批量模块调用
# 作者：kekylin
# 创建时间：2025-07-11
# 修改时间：2025-07-12

set -euo pipefail
IFS=$'\n\t'

# 加载公共库
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/core/constants.sh"
source "${SCRIPT_DIR}/lib/core/logging.sh"
source "${SCRIPT_DIR}/lib/system/dependency.sh"
source "${SCRIPT_DIR}/lib/system/utils.sh"
source "${SCRIPT_DIR}/lib/ui/menu.sh"
source "${SCRIPT_DIR}/lib/ui/styles.sh"

# 全局变量定义
declare -A MODULE_DESC MENU_MAP
declare -a MENU_ORDER

# 初始化模块配置
init_module_config() {
  # 脚本标识与描述映射
  MODULE_DESC=(
    [s11]="configure-sources|软件源配置"
    [s12]="install-basic-tools|基础工具安装"
    [w11]="install-cockpit|安装 Cockpit"
    [w12]="install-vm-components|虚拟机支持"
    [w13]="enable-cockpit-external|启用外网访问"
    [w14]="disable-cockpit-external|禁用外网访问"
    [w15]="set-cockpit-network|管理网络配置"
    [m11]="setup-mail-account|邮件账户配置"
    [m12]="enable-login-mail|启用登录通知"
    [m13]="disable-login-mail|禁用登录通知"
    [a11]="configure-security|基础安全配置"
    [a12]="install-firewall|防火墙安装"
    [a13]="install-fail2ban|fail2ban 安装"
    [a14]="block-threat-ips|IP 封禁工具"
    [d11]="install-docker|Docker 安装"
    [d12]="add-docker-mirror|镜像加速配置"
    [d13]="install-docker-apps|容器应用安装"
    [d14]="backup-restore|Docker 备份恢复"
    [t11]="check-system-compatibility|兼容性检查"
    [t12]="check-system-updates|系统更新检查"
    [t13]="install-service-query|服务状态查询"
    [t14]="auto-update-hosts|hosts 文件更新"
    [t15]="install-tunnel|内网穿透安装"
    [t16]="acl-manager|ACL权限管理"
    [q11]="setup-homenas-basic|基础环境配置"
    [q12]="setup-homenas-secure|安全环境配置"
  )

  # 菜单结构定义
  MENU_MAP=(
    ["系统初始化"]="s11 s12"
    ["Web管理"]="w11 w12 w13 w14 w15"
    ["邮件服务"]="m11 m12 m13"
    [a11]="configure-security|基础安全配置"
    ["安全加固"]="a11 a12 a13 a14"
    ["容器平台"]="d11 d12 d13 d14"
    ["系统工具"]="t11 t12 t13 t14 t15 t16"
    ["快速部署"]="q11 q12"
  )

  MENU_ORDER=(
    "系统初始化"
    "Web管理"
    "邮件服务"
    "安全加固"
    "容器平台"
    "系统工具"
    "快速部署"
  )
}

# 设置临时目录和信号处理
setup_environment() {
  TMP_DIR="/tmp/debian-homenas.$(date +%s%N)$$"
  mkdir -p "${TMP_DIR}"
  chmod 700 "${TMP_DIR}"
  trap 'log_warning "用户中断脚本，正在退出..."; rm -rf "${TMP_DIR}"; exit 1' INT
  trap 'rm -rf "${TMP_DIR}"' EXIT
}

# 显示项目横幅
print_banner() {
  print_separator "="
  print_banner_text "                 Debian-HomeNAS"
  print_banner_text "                                  QQ群：339169752"
  print_banner_text "作者：kekylin"
  print_banner_text "项目：https://github.com/kekylin/Debian-HomeNAS"
  print_separator "-"
  print_title "温馨提示"
  print_title "·"快速部署"自动配置基础环境，也可按需选择单项功能"
  print_title "·安装防火墙后需重启系统以确保服务正常"
  print_title "·网络管理工具切换会改变IP，请手动执行并注意IP变化"
  print_separator "="
}

# 显示主菜单
show_main_menu() {
  print_banner
  for i in "${!MENU_ORDER[@]}"; do
    print_menu_item "$((i+1))" "${MENU_ORDER[$i]}"
  done
  print_menu_item "0" "退出"
}

# 将空格分隔的字符串分割为数组
split_string_to_array() {
  local string="$1"
  local -n array_ref="$2"
  
  array_ref=()
  [[ -n "$string" ]] && IFS=' ' read -ra array_ref <<< "$string"
}

# 显示子菜单
show_sub_menu() {
  local group="$1"
  local -a items
  
  split_string_to_array "${MENU_MAP[$group]}" items
  print_title "---------------- $group ----------------"
  
  local idx=1
  for key in "${items[@]}"; do
    if [[ -z "${MODULE_DESC[$key]+_}" ]]; then
      log_fail "菜单配置错误：未找到标识 $key 的描述"
      continue
    fi
    
    local desc="${MODULE_DESC[$key]}"
    local zh_desc="${desc#*|}"
    print_menu_item "$idx" "$zh_desc"
    ((idx++))
  done
  
  print_menu_item "0" "返回"
  print_prompt "支持多选，空格分隔，如：1 2 3"
}

# 验证用户输入是否为数字
validate_numeric_input() {
  local input="$1"
  [[ "$input" =~ ^[0-9]+$ ]]
}

# 验证用户选择是否有效
validate_menu_choice() {
  local choice="$1"
  local max="$2"
  
  [[ "$choice" -ge 0 && "$choice" -le "$max" ]]
}

# execute_selected_modules 只保留本地文件查找和执行逻辑
execute_selected_modules() {
  local -a selected_keys=("$@")
  local group="${selected_keys[-1]}"
  unset "selected_keys[-1]"

  for key in "${selected_keys[@]}"; do
    if [[ -z "${MODULE_DESC[$key]+_}" ]]; then
      log_fail "未找到标识 $key 的描述，跳过"
      continue
    fi
    local desc="${MODULE_DESC[$key]}"
    local script_name="${desc%%|*}"
    local zh_desc="${desc#*|}"
    local rel_path="modules/${script_name}.sh"
    local mod_path="${SCRIPT_DIR}/$rel_path"
    if [[ ! -f "$mod_path" ]]; then
      log_fail "本地模块 \"$zh_desc\" 不存在"
      continue
    fi
    log_action "正在执行模块：\"$zh_desc\""
    if ! bash "$mod_path"; then
      log_fail "模块 \"$zh_desc\" 执行失败，已中断本轮操作"
      break
    fi
    log_success "模块 \"$zh_desc\" 执行完成"
  done
}

# 处理子菜单选择
handle_sub_menu() {
  local group="$1"
  local -a items
  
  split_string_to_array "${MENU_MAP[$group]}" items
  
  while true; do
    show_sub_menu "$group"
    read -rp "请选择编号: " sub_choices
    
    [[ -z "$sub_choices" ]] && {
      log_fail "输入为空，请重新输入"
      continue
    }
    
    # 验证输入格式
    local -a choices_array
    IFS=' ' read -ra choices_array <<< "$sub_choices"
    
    for choice in "${choices_array[@]}"; do
      if ! validate_numeric_input "$choice"; then
        log_fail "仅支持数字编号"
        continue 2
      fi
    done
    
    # 检查是否选择返回
    [[ " $sub_choices " =~ " 0 " ]] && break
    
    # 解析用户选择
    local -a selected=()
    for choice in "${choices_array[@]}"; do
      if validate_menu_choice "$choice" "${#items[@]}"; then
        selected+=("${items[$((choice-1))]}")
      fi
    done
    
    if [[ ${#selected[@]} -eq 0 ]]; then
      log_fail "无效选择"
      continue
    fi
    
    execute_selected_modules "${selected[@]}" "$group"
    break
  done
}

# 主交互循环
main_menu_loop() {
  while true; do
    show_main_menu
    read -rp "请选择编号: " main_choice
    
    if ! validate_numeric_input "$main_choice"; then
      log_fail "请输入数字编号"
      continue
    fi
    
    if [[ "$main_choice" == "0" ]]; then
      log_action "已退出脚本"
      exit 0
    fi
    
    if ! validate_menu_choice "$main_choice" "${#MENU_ORDER[@]}"; then
      log_fail "无效选择"
      continue
    fi
    
    local group="${MENU_ORDER[$((main_choice-1))]}"
    handle_sub_menu "$group"
  done
}

# 执行基础系统兼容性检查
perform_system_checks() {
  local failed_checks=0

  # 检查系统兼容性
  if ! verify_system_support; then
    ((failed_checks++))
  fi

  # 检查用户权限
  if ! is_root_user; then
    log_fail "脚本需要 root 权限运行"
    exit "${ERROR_PERMISSION}"
  fi

  # 检查内存（基础要求）
  if ! check_memory_requirements 256; then
    ((failed_checks++))
  fi

  # 检查磁盘空间（基础要求）
  if ! check_disk_space "/" 2; then
    ((failed_checks++))
  fi

  if [[ $failed_checks -gt 0 ]]; then
    log_warning "系统兼容性检查发现一些问题，但不影响脚本运行"
    echo
    read -rp "是否继续运行脚本？(y/N): " continue_choice
    if [[ "$continue_choice" != "y" && "$continue_choice" != "Y" ]]; then
      log_action "用户选择退出"
      exit 0
    fi
  fi
}

# 主函数
main() {
  clear
  init_module_config
  setup_environment
  perform_system_checks
  main_menu_loop
}

# 程序入口
main 