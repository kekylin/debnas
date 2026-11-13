#!/bin/bash
# 功能：交互菜单系统
# 说明：Phase 2 — 方向键导航 + ">" 光标指示 + 局部刷新
# 交互菜单入口

set -euo pipefail
IFS=$'\n\t'

# 获取项目根目录
_DEBNAS_SCRIPT="$(readlink -f "${BASH_SOURCE[0]}")"
_DEBNAS_ROOT="$(cd "${_DEBNAS_SCRIPT%/*}/.." && pwd)"  # readlink -f 输出绝对路径，参数展开取目录

# 加载统一库
source "${_DEBNAS_ROOT}/lib/bootstrap.sh"

# ==================== 部署方案 ====================

declare -a SOLUTION_NAMES=()
declare -a SOLUTION_DISPLAY_NAMES=()

# 加载部署方案（config/solutions/*.list）
load_solutions() {
  SOLUTION_NAMES=()
  SOLUTION_DISPLAY_NAMES=()
  local solutions_dir="${_DEBNAS_ROOT}/config/solutions"
  [[ -d "$solutions_dir" ]] || return 0

  local solution_file name display_name
  for solution_file in "$solutions_dir"/*.list; do
    [[ -f "$solution_file" ]] || continue
    name="${solution_file##*/}"; name="${name%.list}"
    display_name=$(sed -n '1s/^#[[:space:]]*//p' "$solution_file" 2>/dev/null)
    [[ -z "$display_name" ]] && display_name="$name"
    SOLUTION_NAMES+=("$name")
    SOLUTION_DISPLAY_NAMES+=("$display_name")
  done
}

# 执行部署方案（按序逐模块调用 module-runner.sh）
execute_solution() {
  local solution_name="$1"
  local solution_file="${_DEBNAS_ROOT}/config/solutions/${solution_name}.list"

  [[ -f "$solution_file" ]] || {
    log_error "方案文件不存在: $solution_file"
    return 1
  }

  local failed=0 module_name
  # 使用 fd 3 读取方案文件，避免 stdin 被重定向污染子进程
  # （否则交互式模块如 mail-account 的 read 会读到方案文件的下一行模块名）
  while IFS= read -r line <&3; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    module_name="${line#"${line%%[![:space:]]*}"}"
    module_name="${module_name%"${module_name##*[![:space:]]}"}"
    [[ -n "$module_name" ]] || continue

    if ! (unset _DEBNAS_BOOTSTRAPPED; trap - INT; bash "${_DEBNAS_ROOT}/bin/module-runner.sh" "$module_name"); then
      log_error "模块 \"$module_name\" 执行失败，已中断部署方案"
      failed=1
      break
    fi
  done 3< "$solution_file"

  [[ $failed -eq 0 ]] && log_success "部署完成"
  return $failed
}

# ==================== 自动发现模式菜单 ====================

# 构建当前有效分类列表
declare -a ACTIVE_CATEGORIES=()

build_active_categories() {
  ACTIVE_CATEGORIES=()
  for category in "${CATEGORY_ORDER[@]}"; do
    if [[ "$category" == "一键部署" ]]; then
      # 部署分类：有方案文件即有内容
      [[ ${#SOLUTION_NAMES[@]} -gt 0 ]] && ACTIVE_CATEGORIES+=("$category")
    else
      local -a modules
      mapfile -t modules < <(get_modules_by_category "$category" 2>/dev/null)
      [[ ${#modules[@]} -gt 0 ]] && ACTIVE_CATEGORIES+=("$category")
    fi
  done
  ACTIVE_CATEGORIES+=("关于项目")
  return 0  # 确保函数始终返回 0（避免 set -e 下因最后一个 [[ 失败而退出）
}

# 执行自动发现模式选择的模块
execute_auto_modules() {
  local category="$1"
  shift
  local -a selected_modules=("$@")

  for module_name in "${selected_modules[@]}"; do
    local display_name
    display_name=$(get_module_field "$module_name" "name" "$module_name" 2>/dev/null) || display_name="$module_name"
    if ! (unset _DEBNAS_BOOTSTRAPPED; trap - INT; bash "${_DEBNAS_ROOT}/bin/module-runner.sh" "$module_name"); then
      log_error "模块 \"$display_name\" 执行失败，已中断"
      break
    fi
  done
}

# ═══════════════════════════════════════════════════════════════
# Phase 2 新菜单循环 — 方向键导航
# ═══════════════════════════════════════════════════════════════

# 关于项目 → 项目简介：打印概况
show_project_intro() {
  local separator
  separator=$(printf '%*s' 46 '' | tr ' ' '-')
  printf '\n'
  printf '%s\n' "$separator"
  printf '\n'
  printf '    %s\n' "一个将 Debian 系统快速配置成准 NAS 系统的脚本。"
  printf '\n'
  printf '    作者：%b%s%b\n' "$COLOR_DIM" "kekylin" "$COLOR_RESET"
  printf '    地址：%b%s%b\n' "$COLOR_DIM" "https://github.com/kekylin/debnas" "$COLOR_RESET"
  printf '    当前版本：%s\n' "${DEBNAS_VERSION:-未知}"
  printf '\n'
  printf '%s\n' "$separator"
  printf '\n'
}

# 关于项目 → 检查脚本更新：只读检查版本指针，确认后调用 debnas update
# 检查逻辑与 debnas check-update / debnas update 共用 release_check_latest
handle_script_update() {
  local install_dir="${DEBNAS_OPT_DIR:-/opt/debnas}"
  # 开发态（从源码目录运行）没有安装标记，用当前代码版本与仓库内的公钥比较
  [[ -d "$install_dir" ]] || install_dir="${_DEBNAS_ROOT:-${DEBNAS_ROOT:-.}}"

  # 优先级：CLI/环境（DEBNAS_REGION）> 配置文件 > 默认 cn
  local region="${DEBNAS_REGION:-}"
  if [[ -z "$region" ]]; then
    region=$(config_read "global" "region" "" 2>/dev/null) || region=""
  fi
  [[ -n "$region" ]] || region="cn"

  local tmp_dir
  tmp_dir=$(create_temp_dir "menu-update") || { log_error "无法创建临时目录"; return 1; }

  log_info "检查更新..."
  local rel_rc=0
  # 面向普通用户：不输出回退来源、主备源切换等内部诊断，只保留最终结论
  _RELEASE_QUIET=1
  release_check_latest "$install_dir" "$tmp_dir" "$region" || rel_rc=$?
  _RELEASE_QUIET=0
  rm -rf -- "${tmp_dir:?}"

  local current="${_REL_INSTALLED_TAG:-${DEBNAS_VERSION:-未知}}"
  local latest="${_REL_LATEST_TAG:-}"

  # 版本号属于状态信息，统一带 [INFO] 标识，不直接裸行展示
  log_info "当前版本：${current}"
  if [[ -n "$latest" ]]; then
    log_info "最新版本：${latest}"
  fi

  case "$rel_rc" in
    0)
      log_success "已是最新版本（${current}）"
      return 0
      ;;
    1)
      log_warning "发现新版本：${latest}"
      ;;
    *)
      # 只用面向用户的一句话结论（内部原因见 debnas check-update 的详细输出）
      if [[ "${_REL_ERROR:-}" == "older" ]]; then
        log_warning "$(release_check_user_text "$_REL_ERROR")"
      else
        log_error "$(release_check_user_text "${_REL_ERROR:-}")"
      fi
      return 0
      ;;
  esac

  # 非交互环境：只报告，不擅自更新
  if [[ ! -t 0 ]]; then
    log_info "非交互环境，仅检查不更新；如需更新请执行：debnas update --tag ${latest}"
    return 0
  fi

  local answer
  answer=$(ui_confirm "更新到 ${latest}？" "当前版本：${current}\n最新版本：${latest}\n\n将下载发布包并校验 GPG 签名与 SHA256，更新过程中请勿关闭终端。")
  if [[ "$answer" != "0" ]]; then
    log_info "已取消更新"
    return 0
  fi

  log_info "开始更新到 ${latest}..."
  if bash "${_DEBNAS_ROOT}/bin/debnas" update --tag "$latest"; then
    update_check_cache_clear
    _UI_UPDATE_HINT=""
    log_success "更新完成，重新进入 DebNAS 后使用新版本"
  else
    log_error "更新失败，详见上方输出"
  fi
  return 0
}

# 关于项目二级菜单：项目简介 / 检查脚本更新
handle_about_sub_menu() {
  local -a items=("项目简介" "检查脚本更新")
  ui_screen_switch  # 清 L1 菜单区 + 渲染 L2 Header
  # 计算旧 L2 区域总行数（Header + 面包屑 + 菜单项 + 底部标签）
  local _hdr_h=4 _bc_lines=1 _ftr_lines=1
  [[ "${_UI_COMPACT_MODE:-0}" -eq 1 ]] && _hdr_h=3
  local _old_area=$((_hdr_h + _bc_lines + ${#items[@]} + _ftr_lines))

  local choice exit_code menu_result
  while true; do
    menu_result=$(mktemp)
    UI_MENU_BACK_LABEL="← 返回上级" UI_MENU_RESULT_FILE="$menu_result" ui_menu "关于项目" "${items[@]}" || {
      exit_code=$?
      rm -f "$menu_result"
      case $exit_code in
        254) return 0 ;;   # Esc：返回一级菜单
        255) ui_cursor_show; log_info "用户退出 DebNAS"; exit 0 ;;
        *)   return 0 ;;
      esac
    }
    choice=$(cat "$menu_result")
    rm -f "$menu_result"

    # 清除子菜单 → 打印快照（留在 scrollback）→ 内容输出追加在快照下方
    ui_clear_menu_area "$_old_area"
    declare -f _ui_print_menu_snapshot >/dev/null 2>&1 && _ui_print_menu_snapshot

    case "$choice" in
      0) show_project_intro ;;
      1) handle_script_update ;;
    esac

    # 在输出末尾重绘 Header + L2 菜单
    ui_screen_init
  done
}

# 部署方案子菜单（新）
handle_solution_sub_menu() {
  ui_screen_switch  # 清 L1 菜单区 + 渲染 L2 Header
  # 计算旧 L2 区域总行数（Header + 面包屑 + 菜单项 + 底部标签）
  local _hdr_h=4 _bc_lines=1 _ftr_lines=1
  [[ "${_UI_COMPACT_MODE:-0}" -eq 1 ]] && { _hdr_h=3; _bc_lines=1; }
  local _old_area=$((_hdr_h + _bc_lines + ${#SOLUTION_DISPLAY_NAMES[@]} + _ftr_lines))

  local choice exit_code menu_result
  while true; do
    menu_result=$(mktemp)
    UI_MENU_BACK_LABEL="← 返回上级" UI_MENU_RESULT_FILE="$menu_result" ui_menu "一键部署" "${SOLUTION_DISPLAY_NAMES[@]}" || {
      exit_code=$?
      rm -f "$menu_result"
      case $exit_code in
        254) return 0 ;;   # Esc：返回上级
        255) ui_cursor_show; log_info "用户退出 DebNAS"; exit 0  ;;
        *)   return 0 ;;
      esac
    }
    choice=$(cat "$menu_result")
    rm -f "$menu_result"

    # 清除旧菜单 → 打印快照（留在 scrollback）→ 模块输出追加在快照下方
    ui_clear_menu_area "$_old_area"
    declare -f _ui_print_menu_snapshot >/dev/null 2>&1 && _ui_print_menu_snapshot

    # 方案失败时 execute_solution 返回 1（已输出错误），不能让 set -e 直接退出整个菜单
    execute_solution "${SOLUTION_NAMES[$choice]}" || true

    # 在日志末尾重绘 Header + L2 菜单
    ui_screen_init
  done
}

# 自动发现模式子菜单处理（新）
handle_auto_sub_menu() {
  local category="$1"
  local -a modules
  mapfile -t modules < <(get_modules_by_category "$category" 2>/dev/null)

  # 构建显示名称数组
  local -a display_names=()
  local module_name display_name
  for module_name in "${modules[@]}"; do
    display_name=$(get_module_field "$module_name" "name" "$module_name" 2>/dev/null) || display_name="$module_name"
    display_names+=("$display_name")
  done

  local choice exit_code menu_result
  ui_screen_switch  # 清 L1 菜单区 + 渲染 L2 Header
  # 计算旧 L2 区域总行数（Header + 面包屑 + 菜单项 + 底部标签）
  local _hdr_h=4 _bc_lines=1 _ftr_lines=1
  [[ "${_UI_COMPACT_MODE:-0}" -eq 1 ]] && { _hdr_h=3; _bc_lines=1; }
  local _old_area=$((_hdr_h + _bc_lines + ${#modules[@]} + _ftr_lines))

  while true; do
    menu_result=$(mktemp)
    UI_MENU_BACK_LABEL="← 返回上级" UI_MENU_RESULT_FILE="$menu_result" ui_menu "$category" "${display_names[@]}" || {
      exit_code=$?
      rm -f "$menu_result"
      case $exit_code in
        254) return 0 ;;   # Esc：返回上级
        255) ui_cursor_show; log_info "用户退出 DebNAS"; exit 0  ;;
        *)   return 0 ;;
      esac
    }
    choice=$(cat "$menu_result")
    rm -f "$menu_result"

    # 清除旧菜单 → 打印快照（留在 scrollback）→ 模块输出追加在快照下方
    ui_clear_menu_area "$_old_area"
    declare -f _ui_print_menu_snapshot >/dev/null 2>&1 && _ui_print_menu_snapshot

    # 执行单个选中模块
    execute_auto_modules "$category" "${modules[$choice]}"

    # 在日志末尾重绘 Header + L2 菜单
    ui_screen_init
  done
}

# ==================== 首页新版本提示 ====================
# 一级菜单 footer 的绿点：缓存有效期内直接显示；缺失/过期时后台补一次（结果下次启动生效）
_UI_UPDATE_HINT=""

update_hint_init() {
  _UI_UPDATE_HINT=""
  local install_dir="${DEBNAS_OPT_DIR:-/opt/debnas}"
  [[ -d "$install_dir" ]] || install_dir="${_DEBNAS_ROOT:-${DEBNAS_ROOT:-.}}"

  if update_check_cache_read && update_check_cache_fresh; then
    if [[ "${_UC_STATE:-}" == "newer" && -n "${_UC_LATEST:-}" ]]; then
      _UI_UPDATE_HINT="$_UC_LATEST"
    fi
    return 0
  fi

  # 缓存缺失/过期：后台静默检查，不阻塞首屏
  # 优先级：CLI/环境（DEBNAS_REGION）> 配置文件 > 默认 cn
  local region="${DEBNAS_REGION:-}"
  if [[ -z "$region" ]]; then
    region=$(config_read "global" "region" "" 2>/dev/null) || region=""
  fi
  [[ -n "$region" ]] || region="cn"
  update_check_spawn "$region" "$install_dir"
  return 0
}

# 主菜单循环（新）
main_menu_loop() {
  # Ctrl+C 在菜单导航中静默忽略（子进程中由 module-runner 自行处理）
  trap ':' INT

  build_active_categories
  update_hint_init

  # 空分类保护：无模块也无方案时直接退出
  if [[ ${#ACTIVE_CATEGORIES[@]} -eq 0 ]]; then
    log_error "未发现任何可用模块，请检查 modules/ 目录"
    ui_cursor_show
    exit "${ERROR_MODULE_NOT_FOUND:-1}"
  fi

  local choice exit_code menu_result
  local first_entry=1
  while true; do
    if [[ $first_entry -eq 1 ]]; then
      ui_screen_init    # 首次：无旧菜单需清除
      first_entry=0
    else
      ui_screen_switch  # 从子菜单返回：清子菜单区 + 渲染 L1
    fi
    menu_result=$(mktemp)
    UI_MENU_QUIT=1 UI_MENU_RESULT_FILE="$menu_result" ui_menu "" "${ACTIVE_CATEGORIES[@]}" || {
      exit_code=$?
      rm -f "$menu_result"
      case $exit_code in
        254) continue ;;   # Esc（主菜单无上级，忽略）
        255) break   ;;   # Q：退出程序
        *)   break   ;;
      esac
    }
    choice=$(cat "$menu_result")
    rm -f "$menu_result"

    local category="${ACTIVE_CATEGORIES[$choice]}"
    if [[ "$category" == "关于项目" ]]; then
      handle_about_sub_menu
    elif [[ "$category" == "一键部署" ]]; then
      handle_solution_sub_menu
    else
      handle_auto_sub_menu "$category"
    fi
  done

  # 当前菜单已保留在屏幕上，退出日志直接追加在菜单下方，避免重复快照
  ui_cursor_show
  log_info "用户退出 DebNAS"
  exit 0
}

# ==================== 环境设置 ====================

# 设置临时目录（复用 tempfile.sh 集中管理，不再覆盖 EXIT/INT trap）
setup_environment() {
  init_temp_dir
  _MENU_TMP_DIR=$(create_temp_dir "menu")
}

# ==================== 主入口 ====================

main() {
  # 终端宽度与文本截断依赖 UTF-8 locale；C/POSIX 下中文会按字节截断。
  # 仅在当前 locale 不是 UTF-8 且系统提供 C.UTF-8 时回退，不覆盖用户已设置的 UTF-8 locale。
  case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *UTF-8|*utf8|*utf-8) ;;
    *)
      if locale -a 2>/dev/null | grep -qiE '^C\.utf-?8$'; then
        export LC_ALL=C.UTF-8
      fi
      ;;
  esac

  # 交互界面：经典菜单（debnas-v2 样式），ui_menu 方向键导航
  ui_screen_clear

  setup_environment

  # 系统检查
  if ! verify_system_support 2>/dev/null; then
    exit "${ERROR_UNSUPPORTED_OS}"
  fi

  # 发现模块并使用自动发现模式
  discover_modules 2>/dev/null
  load_solutions

  main_menu_loop
}

main "$@"
