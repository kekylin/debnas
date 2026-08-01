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
generate_css() {
  check_cockpit_version || return 1
  cat > "$BRANDING_CSS" <<CSSEOF
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
auto_update_mode() {
  update_wallpaper || return 1
  generate_css
  restart_cockpit
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

main "$@"
