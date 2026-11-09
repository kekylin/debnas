#!/bin/bash
# @module: wallpaper
# @name: 登录页壁纸
# @category: 管理面板
# @depends: wget
# @depend_modules: cockpit
# @version: 1.0.0
# @order: 35
# @interactive: true
# @cron: true
# @cron_schedule: 0 0 * * *
# 功能：Cockpit 登录页必应每日壁纸自动管理

set -euo pipefail
IFS=$'\n\t'

# ==================== 库加载 ====================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${SCRIPT_DIR}/lib/bootstrap.sh"

# ==================== 常量 ====================
readonly BRANDING_DIR="/etc/cockpit/branding"
readonly BRANDING_CSS="${BRANDING_DIR}/branding.css"
readonly WALLPAPER_FILE="${BRANDING_DIR}/login-bg.png"
readonly ISSUE_FILE="/etc/cockpit/issue.cockpit"
readonly STATE_FILE="${BRANDING_DIR}/.initialized"
readonly DEFAULT_WALLPAPER_API_URL="https://www.bing.com/HPImageArchive.aspx?format=js&idx=0&n=1&mkt=zh-CN"

# 获取壁纸 API 地址（优先级：debnas.conf > 默认值）
get_wallpaper_api_url() {
  local api_url
  api_url=$(config_read "global" "WALLPAPER_API_URL" 2>/dev/null || true)
  if [[ -n "$api_url" ]]; then
    printf '%s' "$api_url"
    return 0
  fi
  printf '%s' "$DEFAULT_WALLPAPER_API_URL"
}

# ==================== 工具函数 ====================
is_first_run() { [[ ! -f "$STATE_FILE" ]]; }
mark_initialized() { touch "$STATE_FILE"; }

# ==================== Cockpit 版本检查 ====================
check_cockpit_version() {
  local cockpit_version=0

  if command -v cockpit-bridge &>/dev/null; then
    cockpit_version=$(cockpit-bridge --version 2>/dev/null | grep -oP 'Version: \K[0-9]+' | head -n1 || echo "0")
  elif command -v cockpit-ws &>/dev/null; then
    cockpit_version=$(cockpit-ws --version 2>/dev/null | grep -oP 'Version: \K[0-9]+' | head -n1 || echo "0")
  elif command -v dpkg &>/dev/null; then
    cockpit_version=$(dpkg -l 2>/dev/null | grep -oP '^ii\s+cockpit\s+\K[0-9]+' | head -n1 | cut -d. -f1 || echo "0")
  fi

  if [[ "$cockpit_version" -eq 0 ]]; then
    log_error "Cockpit 未安装或版本检测失败"
    return 1
  fi

  if [[ "$cockpit_version" -lt 347 ]]; then
    log_error "Cockpit 版本过低 (${cockpit_version})，需要 347 或更高版本"
    return 1
  fi

  return 0
}

# ==================== 环境初始化 ====================
prepare_env() {
  install -d -m 755 "$BRANDING_DIR"
}

# ==================== 壁纸下载 ====================
update_wallpaper() {
  check_cockpit_version || return 1
  prepare_env
  local bing_json bing_url bing_title bing_copyright full_url first_run=false

  is_first_run && first_run=true

  local wallpaper_api_url
  wallpaper_api_url=$(get_wallpaper_api_url)
  if ! bing_json=$(curl --fail --silent --location --max-time 30 --connect-timeout 10 "$wallpaper_api_url" 2>/dev/null); then
    [[ "$first_run" == "true" ]] && return 1
    return 1
  fi

  bing_url=$(echo "$bing_json" | grep -oP '(?<="url":")[^"]+' | head -n1 || true)
  bing_title=$(echo "$bing_json" | grep -oP '(?<="title":")[^"]+' | head -n1 || true)
  bing_copyright=$(echo "$bing_json" | grep -oP '(?<="copyright":")[^"]+' | head -n1 || true)

  if [[ -z "$bing_url" ]]; then
    [[ "$first_run" == "true" ]] && return 1
    return 1
  fi

  full_url="https://www.bing.com${bing_url}"

  if curl --fail --location --silent --show-error --max-time 60 --connect-timeout 10 -o "${WALLPAPER_FILE}.tmp" "$full_url"; then
    mv -f "${WALLPAPER_FILE}.tmp" "$WALLPAPER_FILE"
    write_file_if_changed "$ISSUE_FILE" "$(printf '%s\n%s\n' "$bing_title" "$bing_copyright")" || true
    mark_initialized
    return 0
  else
    rm -f "${WALLPAPER_FILE}.tmp"
    [[ "$first_run" == "true" ]] && return 1
    return 1
  fi
}

# ==================== CSS 生成 ====================
# 样式内容变化时置 _CSS_CHANGED=1（内容未变不重写文件）
_CSS_CHANGED=0
generate_css() {
  check_cockpit_version || return 1
  local css_content
  css_content=$(cat <<CSSEOF
/* Cockpit 登录页样式（自动生成） */
body.login, body.login-pf {
  background: url("login-bg.png") no-repeat center center fixed !important;
  background-size: cover !important;
  --color-background: rgba(255, 255, 255, 0.18) !important;
  --color-input-background: rgba(255, 255, 255, 0.12) !important;
  --color-border: rgba(255, 255, 255, 0.22) !important;
  --color-text: #ffffff !important;
  --color-text-light: #ffffff !important;
  --color-text-lighter: #ffffff !important;
  --color-secondary-text: #ffffff !important;
}

#brand::before {
  content: "\${NAME}";
  font-size: 18pt;
  text-transform: uppercase;
}

#login label, #login input, #login .control-label, #login .button-text, #login-note {
  color: #ffffff !important;
  text-shadow: 0 1px 2px rgba(0,0,0,0.4);
}

#login input {
  background-color: rgba(255,255,255,0.12) !important;
  border: 1px solid rgba(255,255,255,0.22) !important;
}

#login .login-button {
  background: var(--color-primary, #06c) !important;
  border: 1px solid rgba(255,255,255,0.25) !important;
  color: #fff !important;
}

#login .login-password-toggle {
  background: none !important;
  border: 1px solid rgba(255,255,255,0.22) !important;
  color: #fff !important;
}

body.login-pf #banner {
  position: absolute !important;
  top: 20px !important;
  left: 20px !important;
  margin: 0 !important;
  max-width: 40%;
  text-align: left !important;
  background-color: transparent !important;
  border: none !important;
  box-shadow: none !important;
  z-index: 1000;
}

body.login-pf #banner, body.login-pf #banner * {
  color: #ffffff !important;
  text-shadow: 0 1px 2px rgba(0,0,0,0.4);
}

body.login-pf .pf-v6-c-alert__icon {
  display: none !important;
}

@media (max-width: 992px) {
  body.login, body.login-pf {
    background-position: center top !important;
  }
  body.login-pf #banner {
    top: 16px !important;
    left: 16px !important;
    max-width: 60%;
  }
}

@media (max-width: 768px) {
  body.login, body.login-pf {
    background-position: center top !important;
    background-size: cover !important;
  }
  body.login-pf #banner {
    position: static !important;
    margin: 16px auto 0 auto !important;
    padding: 0 16px !important;
    max-width: 100%;
    text-align: left !important;
  }
}
CSSEOF
)
  if write_file_if_changed "$BRANDING_CSS" "$css_content" 644 1; then
    _CSS_CHANGED=1
  fi
  return 0
}

# ==================== Cockpit 服务管理 ====================
restart_cockpit() {
  if systemctl is-active --quiet cockpit 2>/dev/null; then
    service_ensure cockpit restarted
    log_success "Cockpit 已重启"
    return 0
  fi
  if systemctl is-active --quiet cockpit.socket 2>/dev/null; then
    service_ensure cockpit.socket restarted
    log_success "Cockpit 已重启"
    return 0
  fi
  log_warning "Cockpit 未运行"
  return 1
}

# ==================== 启用/禁用 ====================
enable_bing_wallpaper() {
  ensure_module_deps wallpaper || return 1
  check_cockpit_version || return 1

  prepare_env
  if update_wallpaper; then
    generate_css
    if restart_cockpit; then
      feature_enable "wallpaper"
      log_success "壁纸已启用"
      module_mark_action
    else
      log_error "Cockpit 未运行，壁纸未启用"
      return 1
    fi
  else
    log_error "壁纸下载失败"
    return 1
  fi
}

disable_bing_wallpaper() {
  feature_disable "wallpaper"
  cron_unregister "wallpaper" || true
  rm -rf "$BRANDING_DIR"
  write_file_if_changed "$ISSUE_FILE" "基于Debian搭建 DebNAS" || true
  restart_cockpit
  log_success "壁纸已禁用"
  module_mark_action
}

# ==================== 自动更新模式（cron 调用） ====================
# 说明：Cockpit 每次请求都从磁盘读取 branding 文件与 issue.cockpit，壁纸/横幅更新
# 无需重启；仅当样式文件变化时才重启，避免每天定时重启断开已登录的用户会话。
auto_update_mode() {
  update_wallpaper || return 1
  _CSS_CHANGED=0
  generate_css
  if [[ "$_CSS_CHANGED" -eq 1 ]]; then
    restart_cockpit
  fi
}

# ==================== 交互菜单 ====================
main_menu() {
  local -a items=("启用壁纸" "禁用壁纸" "定时设置")
  local choice exit_code menu_result
  while true; do
    menu_result=$(mktemp)
    UI_MENU_BLANK_BEFORE=1 UI_MENU_BACK_LABEL="← 返回上级" UI_MENU_RESULT_FILE="$menu_result" ui_menu "登录页壁纸" "${items[@]}" || {
      exit_code=$?
      rm -f "$menu_result"
      case $exit_code in
        254) return 0 ;;   # Esc：返回上级
        255) return 0 ;;   # Q：退出
        *)   return 0 ;;
      esac
    }
    choice=$(cat "$menu_result")
    rm -f "$menu_result"

    case "$choice" in
      0) enable_bing_wallpaper ;;
      1) disable_bing_wallpaper ;;
      2) cron_settings_menu "wallpaper" ;;
    esac
    echo ""
  done
}

# ==================== 只读探测契约（docs/ARCHITECTURE.md §4.5） ====================

# root crontab 中模块条目状态：on / off / unknown（非 root 无法读取 root crontab）
_wp_cron_state() {
  [[ "${EUID:-1}" -eq 0 ]] || { echo "unknown"; return 0; }
  command -v crontab >/dev/null 2>&1 || { echo "off"; return 0; }
  if cron_is_registered "wallpaper" 2>/dev/null; then echo "on"; else echo "off"; fi
}

# Cockpit 是否已安装（只查命令/包，不调用 --version）
_wp_cockpit_installed() {
  command -v cockpit-bridge >/dev/null 2>&1 && return 0
  [[ "$(dpkg-query -W -f='${db:Status-Status}' cockpit-ws 2>/dev/null)" == "installed" ]]
}

# 当前状态：一行 "状态码|说明"（只读、< 300ms、不联网）
module_status() {
  if ! _wp_cockpit_installed; then
    echo "absent|未安装 Cockpit"
    return 0
  fi
  local enabled=0 has_bg=0 has_css=0 cron updated="" cron_desc
  feature_enabled "wallpaper" 2>/dev/null && enabled=1
  [[ -f "$WALLPAPER_FILE" ]] && has_bg=1
  [[ -f "$BRANDING_CSS" ]] && has_css=1
  cron=$(_wp_cron_state)
  [[ "$has_bg" -eq 1 ]] && updated=$(date -r "$WALLPAPER_FILE" '+%Y-%m-%d' 2>/dev/null || true)
  case "$cron" in
    on)  cron_desc="每日更新已开启" ;;
    off) cron_desc="未开启定时更新" ;;
    *)   cron_desc="定时任务需 root 查看" ;;
  esac

  if [[ "$enabled" -eq 1 ]]; then
    if [[ "$has_bg" -eq 1 && "$has_css" -eq 1 ]]; then
      if [[ "$cron" == "on" ]]; then
        echo "running|已启用 · ${cron_desc}${updated:+ · 壁纸更新于 ${updated}}"
      else
        echo "applied|已启用 · ${cron_desc}${updated:+ · 壁纸更新于 ${updated}}"
      fi
    else
      echo "warn|已启用但 branding 文件缺失（login-bg.png/branding.css）"
    fi
    return 0
  fi
  if [[ "$has_bg" -eq 1 || "$has_css" -eq 1 ]]; then
    echo "partial|branding 文件存在但功能未启用 · ${cron_desc}"
    return 0
  fi
  echo "absent|未启用"
}

# 预演：每行 "类型|目标|备注"（无副作用；交互式模块，列出菜单动作的影响范围）
module_plan() {
  local cron
  cron=$(_wp_cron_state)
  echo "info|动作范围|交互菜单：启用/禁用壁纸、定时设置；非交互调用直接启用；cron 模式更新壁纸"
  _wp_cockpit_installed \
    || echo "risk|Cockpit|未安装：启用会失败（需先运行 cockpit 模块，且版本 ≥ 347）"
  command -v wget >/dev/null 2>&1 || echo "pkg|wget|前置检查自动安装（@depends 声明）"
  command -v curl >/dev/null 2>&1 || echo "risk|curl|未安装 curl：壁纸下载实际使用 curl，启用会失败"
  echo "info|网络|启用/定时更新会访问壁纸 API（默认 bing.com，可由 debnas.conf 的 WALLPAPER_API_URL 覆盖）并下载图片"

  # 启用
  [[ -d "$BRANDING_DIR" ]] || echo "write|${BRANDING_DIR}/|启用：创建目录（755）"
  echo "write|${WALLPAPER_FILE}|启用/定时更新：下载后直接覆盖，不另做备份"
  echo "write|${BRANDING_CSS}|启用：登录页样式；内容变化时原件备份到 /var/backups/debnas/"
  echo "write|${ISSUE_FILE}|启用：写入壁纸标题与版权；原件备份到 /var/backups/debnas/"
  [[ -f "$STATE_FILE" ]] || echo "write|${STATE_FILE}|启用：首次成功后创建初始化标记"
  echo "service|cockpit|启用/禁用：重启 cockpit（或 cockpit.socket）；定时更新仅在样式变化时重启"
  case "$cron" in
    on)  echo "info|定时任务|已开启每日更新" ;;
    *)   echo "cron|wallpaper|定时设置：默认每天 00:00（可自定义 cron 表达式），未启用功能时自动启用" ;;
  esac

  # 禁用
  echo "write|${BRANDING_DIR}|禁用：rm -rf 删除整个目录（含手工放入的品牌文件），不另做备份"
  echo "write|${ISSUE_FILE}|禁用：恢复为默认横幅文字；原件备份到 /var/backups/debnas/"
  echo "cron|wallpaper|禁用：移除 wallpaper 定时条目"
  echo "risk|Cockpit 会话|启用/禁用会重启 Cockpit，已登录的 Web 会话会断开"
  return 0
}

# ==================== 主入口 ====================
main() {
  if [[ "${1:-}" == "enable" ]]; then
    enable_bing_wallpaper
    return $?
  fi
  if [[ "${1:-}" == "disable" ]]; then
    disable_bing_wallpaper
    return $?
  fi

  if [[ "${DEBNAS_CRON_MODE:-0}" -eq 1 ]]; then
    auto_update_mode
  elif [[ -t 0 ]]; then
    main_menu
  else
    log_info "非交互式调用，启用必应壁纸"
    enable_bing_wallpaper
  fi
}

# 契约守卫：DEBNAS_MODULE_ACTION=status|plan 时只加载函数供只读探测，不执行 main（docs/ARCHITECTURE.md §4.5）
if [[ "${DEBNAS_MODULE_ACTION:-run}" == "run" ]]; then main "$@"; fi
