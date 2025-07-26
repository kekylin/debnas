#!/bin/bash
# 功能：主入口脚本，支持交互式主菜单/子菜单/多选批量模块调用

set -euo pipefail
IFS=$'\n\t'

# 加载公共库，确保所有依赖函数和常量可用
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/lib/core/constants.sh"
source "${SCRIPT_DIR}/lib/core/logging.sh"
source "${SCRIPT_DIR}/lib/system/dependency.sh"
source "${SCRIPT_DIR}/lib/system/utils.sh"
source "${SCRIPT_DIR}/lib/ui/menu.sh"
source "${SCRIPT_DIR}/lib/ui/styles.sh"

# 全局变量定义
# MODULE_DESC/MENU_MAP/MENU_ORDER 用于菜单与模块映射，便于后续维护和扩展
declare -A MODULE_DESC MENU_MAP
declare -a MENU_ORDER

# 初始化模块配置，定义各功能模块与菜单结构的映射关系
init_module_config() {
  MODULE_DESC=(
    [s11]="configure-sources|配置软件源"
    [s12]="install-basic-tools|安装基础工具"
    [w11]="install-cockpit|安装 Cockpit"
    [w12]="install-vm-components|安装虚拟机"
    [w13]="enable-cockpit-external|启用外网访问"
    [w14]="disable-cockpit-external|禁用外网访问"
    [w15]="set-cockpit-network|面板管理网络"
    [m11]="setup-mail-account|配置邮件账户"
    [m12]="enable-login-mail|启用登录通知"
    [m13]="disable-login-mail|禁用登录通知"
    [a11]="configure-security|基础安全配置"
    [a12]="install-firewall|安装 Firewalld"
    [a13]="install-fail2ban|安装 Fail2ban"
    [a14]="block-threat-ips|IP 封禁工具"
    [d11]="install-docker|安装 Docker"
    [d12]="add-docker-mirror|镜像加速"
    [d13]="install-docker-apps|安装应用"
    [d14]="backup-restore|备份恢复"
    [t11]="check-system-compatibility|检查兼容性"
    [t12]="check-system-updates|检查系统更新"
    [t13]="install-service-query|查询服务状态"
    [t14]="auto-update-hosts|更新 Hosts 文件"
    [t15]="install-tunnel|安装 Tailscale"
    [t16]="acl-manager|管理ACL权限"
    [q11]="setup-homenas-basic|一键部署基础环境"
    [q12]="setup-homenas-secure|一键部署安全环境"
  )

  # 菜单结构定义
  MENU_MAP=(
    ["基础配置"]="s11 s12"
    ["管理面板"]="w11 w12 w13 w14 w15"
    ["通知服务"]="m11 m12 m13"
    ["安全防护"]="a11 a12 a13 a14"
    ["容器管理"]="d11 d12 d13 d14"
    ["系统工具"]="t11 t12 t13 t14 t15 t16"
    ["一键部署"]="q11 q12"
  )

  MENU_ORDER=(
    "基础配置"
    "管理面板"
    "通知服务"
    "安全防护"
    "容器管理"
    "系统工具"
    "一键部署"
  )
}

# 解析 --tmpdir 参数
TMP_DIR=""
for arg in "$@"; do
  case $arg in
    --tmpdir)
      shift
      TMP_DIR="$1"
      ;;
  esac
  shift || true
  # 兼容无参数时不报错
  [[ $# -eq 0 ]] && break
done

# 设置临时目录和信号处理，确保脚本异常退出时自动清理临时文件
setup_environment() {
  if [[ -n "$TMP_DIR" ]]; then
    trap 'log_warning "用户中断操作，正在清理临时文件并退出。"; rm -rf "$TMP_DIR"; exit 1' INT
    trap 'rm -rf "$TMP_DIR"' EXIT
  else
    TMP_DIR="/tmp/debian-homenas.$(date +%s%N)$$"
    mkdir -p "${TMP_DIR}"
    chmod 700 "${TMP_DIR}"
    trap 'log_warning "用户中断操作，正在清理临时文件并退出。"; rm -rf "${TMP_DIR}"; exit 1' INT
    trap 'rm -rf "${TMP_DIR}"' EXIT
  fi
}

# 显示项目横幅，提供项目信息和重要提示
print_banner() {
  print_separator "="
  print_banner_text "                 Debian-HomeNAS"
  print_banner_text "                                  QQ群：339169752"
  print_banner_text "作者：kekylin"
  print_banner_text "项目：https://github.com/kekylin/Debian-HomeNAS"
  print_separator "-"
  print_title "温馨提示"
  print_title "·一键部署适合自动配置环境，也可按需选择单项功能"
  print_title "·安装防火墙后需重启系统以确保服务正常"
  print_separator "="
}

# 显示主菜单，供用户选择功能模块
show_main_menu() {
  print_banner
  for i in "${!MENU_ORDER[@]}"; do
    print_main_menu_item "$((i+1))" "${MENU_ORDER[$i]}"
  done
  print_menu_item "0" "退出" "true"
  print_separator "="
}

# 将空格分隔的字符串分割为数组
split_string_to_array() {
  local string="$1"
  local -n array_ref="$2"
  
  array_ref=()
  if [[ -n "$string" ]]; then
    IFS=' ' read -ra array_ref <<< "$string"
  fi
}

# 显示子菜单，供用户选择具体操作
show_sub_menu() {
  local group="$1"
  local -a items
  split_string_to_array "${MENU_MAP[$group]}" items
  print_submenu_title "$group"
  local idx=1
  for key in "${items[@]}"; do
    if [[ -z "${MODULE_DESC[$key]+_}" ]]; then
      log_fail "菜单配置错误：未找到标识 $key 的描述。请检查模块映射配置。"
      continue
    fi
    local desc="${MODULE_DESC[$key]}"
    local zh_desc="${desc#*|}"
    print_menu_item "$idx" "$zh_desc"
    ((idx++))
  done
  print_menu_item "0" "返回" "true"
  print_multiselect_prompt
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

# 执行用户选择的功能模块，逐一校验并执行
execute_selected_modules() {
  local -a selected_keys=("$@")
  local group="${selected_keys[-1]}"
  unset "selected_keys[-1]"
  for key in "${selected_keys[@]}"; do
    if [[ -z "${MODULE_DESC[$key]+_}" ]]; then
      log_fail "未找到标识 $key 的描述，已跳过该项。请检查模块配置。"
      continue
    fi
    local desc="${MODULE_DESC[$key]}"
    local script_name="${desc%%|*}"
    local zh_desc="${desc#*|}"
    local rel_path="modules/${script_name}.sh"
    local mod_path="${SCRIPT_DIR}/$rel_path"
    if [[ ! -f "$mod_path" ]]; then
      log_fail "本地模块 \"$zh_desc\" 不存在，操作已跳过。请确认模块文件是否完整。"
      continue
    fi
    log_action "正在执行模块：\"$zh_desc\"。"
    if ! bash "$mod_path"; then
      log_fail "模块 \"$zh_desc\" 执行失败，已中断本轮操作。请检查模块实现或日志。"
      break
    fi
    log_success "模块 \"$zh_desc\" 执行完成。"
  done
}

# 处理子菜单选择，循环等待用户输入并校验
handle_sub_menu() {
  local group="$1"
  local -a items
  split_string_to_array "${MENU_MAP[$group]}" items
  while true; do
    show_sub_menu "$group"
    print_prompt "请选择编号: "
    read -r sub_choices
    [[ -z "$sub_choices" ]] && {
      log_fail "输入为空，请重新输入有效编号。"
      continue
    }
    local -a choices_array
    IFS=' ' read -ra choices_array <<< "$sub_choices"
    for choice in "${choices_array[@]}"; do
      if ! validate_numeric_input "$choice"; then
        log_fail "仅支持数字编号，请重新输入。"
        continue 2
      fi
    done
    [[ " $sub_choices " =~ " 0 " ]] && break
    local -a selected=()
    for choice in "${choices_array[@]}"; do
      if validate_menu_choice "$choice" "${#items[@]}"; then
        selected+=("${items[$((choice-1))]}")
      fi
    done
    if [[ ${#selected[@]} -eq 0 ]]; then
      log_fail "无效选择，请重新输入有效编号。"
      continue
    fi
    execute_selected_modules "${selected[@]}" "$group"
    break
  done
}

# 主交互循环，持续响应用户操作直到退出
main_menu_loop() {
  while true; do
    show_main_menu
    print_prompt "请选择编号: "
    read -r main_choice
    if ! validate_numeric_input "$main_choice"; then
      log_fail "请输入数字编号。"
      continue
    fi
    if [[ "$main_choice" == "0" ]]; then
      log_action "用户选择退出，脚本已终止。"
      exit 0
    fi
    if ! validate_menu_choice "$main_choice" "${#MENU_ORDER[@]}"; then
      log_fail "无效选择，请重新输入有效编号。"
      continue
    fi
    local group="${MENU_ORDER[$((main_choice-1))]}"
    handle_sub_menu "$group"
  done
}

# 执行基础系统兼容性检查，提前发现潜在环境问题
perform_system_checks() {
  local failed_checks=0
  if ! verify_system_support; then
    ((failed_checks++))
  fi
  if ! is_root_user; then
    log_fail "脚本需要以 root 权限运行。请切换到 root 用户后重试。"
    exit "${ERROR_PERMISSION}"
  fi
  if ! check_memory_requirements 256; then
    ((failed_checks++))
  fi
  if ! check_disk_space "/" 2; then
    ((failed_checks++))
  fi
  if [[ $failed_checks -gt 0 ]]; then
    log_warning "系统兼容性检查发现部分问题，但不影响脚本运行。请根据提示优化环境配置。"
    echo
    read -rp "是否继续运行脚本？(y/N): " continue_choice
    if [[ "$continue_choice" != "y" && "$continue_choice" != "Y" ]]; then
      log_action "用户选择退出，脚本已终止。"
      exit 0
    fi
  fi
}

# 主函数，负责初始化、环境检测和主循环
main() {
  clear
  init_module_config
  setup_environment
  perform_system_checks
  main_menu_loop
}

# 程序入口
main 