#!/bin/bash
# @module: cockpit-auto-bing-wallpaper
# @name: 面板必应壁纸
# @category: 管理面板
# @depends: wget,systemctl,crontab
# @depend_modules: install-cockpit
# @version: 1.0.0
# @order: 35
# @cron: true
# @cron_schedule: 0 */6 * * *
# 功能：Cockpit 登录页必应每日壁纸自动管理（自包含模块）
#
# 此模块为自包含设计：复制到 /etc/cockpit/branding/ 后仍可独立运行 --auto 模式。

set -euo pipefail
IFS=$'\n\t'

# ==================== 库加载 ====================
# 检测运行位置：branding 目录（cron 副本）还是项目目录
if [[ "$(dirname "${BASH_SOURCE[0]}")" == "/etc/cockpit/branding" ]]; then
  # cron 副本运行：使用内置简化日志
  log_info()    { printf '\033[1;34m[INFO]\033[0m %s\n' "$*" 2>/dev/null || true; }
  log_success() { printf '\033[1;32m[SUCCESS]\033[0m %s\n' "$*" 2>/dev/null || true; }
  log_error()   { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2 2>/dev/null || true; }
  log_warning() { printf '\033[1;33m[WARNING]\033[0m %s\n' "$*" 2>/dev/null || true; }
  log_to_file() { local f="$1"; shift; "$f" "$@" 2>/dev/null || true; }
  print_prompt(){ printf '%s' "$*" 2>/dev/null || true; }
  show_menu_with_border() { local t="$1"; shift; echo "--- $t ---"; local i=1; for o in "$@"; do echo "$i. $o"; ((i++)); done; echo "0.返回"; }
  # cron 框架函数（简化版）
  cron_register() { return 0; }
  cron_unregister() { return 0; }
  cron_is_registered() { return 1; }
  cron_list() { crontab -l 2>/dev/null || true; }
else
  # 项目目录运行：加载完整库
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  source "${SCRIPT_DIR}/lib/bootstrap.sh"
fi

# ==================== 常量 ====================
readonly BRANDING_DIR="/etc/cockpit/branding"
readonly BRANDING_CSS="${BRANDING_DIR}/branding.css"
readonly WALLPAPER_FILE="${BRANDING_DIR}/login-bg.png"
readonly ISSUE_FILE="/etc/cockpit/issue.cockpit"
readonly STATE_FILE="${BRANDING_DIR}/.initialized"
readonly SCRIPT_COPY="${BRANDING_DIR}/cockpit-bing-wallpaper.sh"
readonly BING_API_URL="https://www.bing.com/HPImageArchive.aspx?format=js&idx=0&n=1&mkt=zh-CN"
readonly SELF_PATH="$(realpath "${BASH_SOURCE[0]}")"
readonly ERROR_DEPENDENCY=2

# ==================== 依赖检查 ====================
REQUIRED_CMDS=(curl crontab)
if ! command -v curl &>/dev/null; then
  log_error "curl 不可用"
  exit "${ERROR_DEPENDENCY}"
fi

# ==================== 工具函数 ====================
log_to_file() { local f="$1"; shift; "$f" "$@" 2>/dev/null || true; }
is_first_run() { [[ ! -f "$STATE_FILE" ]]; }
mark_initialized() { touch "$STATE_FILE"; }
is_auto_mode() { [[ ! -t 0 ]] || [[ -n "${CRON:-}" ]]; }

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

create_script_copy() {
  cp "$SELF_PATH" "$SCRIPT_COPY"
  chmod +x "$SCRIPT_COPY"
}

# ==================== 壁纸下载 ====================
update_wallpaper() {
  check_cockpit_version || return 1
  prepare_env
  local bing_json bing_url bing_title bing_copyright full_url first_run=false

  is_first_run && first_run=true

  # 获取 Bing API 数据
  if ! bing_json=$(curl --fail --silent --location "$BING_API_URL" 2>/dev/null); then
    [[ "$first_run" == "true" ]] && return 1
    exit 0
  fi

  # 解析数据
  bing_url=$(echo "$bing_json" | grep -oP '(?<="url":")[^"]+' | head -n1 || true)
  bing_title=$(echo "$bing_json" | grep -oP '(?<="title":")[^"]+' | head -n1 || true)
  bing_copyright=$(echo "$bing_json" | grep -oP '(?<="copyright":")[^"]+' | head -n1 || true)

  if [[ -z "$bing_url" ]]; then
    [[ "$first_run" == "true" ]] && return 1
    exit 0
  fi

  # 下载壁纸
  full_url="https://www.bing.com${bing_url}"

  if curl --fail --location --silent --show-error -o "${WALLPAPER_FILE}.tmp" "$full_url"; then
    mv -f "${WALLPAPER_FILE}.tmp" "$WALLPAPER_FILE"
    printf '%s\n%s\n' "$bing_title" "$bing_copyright" > "$ISSUE_FILE"
    mark_initialized
    return 0
  else
    rm -f "${WALLPAPER_FILE}.tmp"
    [[ "$first_run" == "true" ]] && return 1
    exit 0
  fi
}

# ==================== CSS 生成 ====================
generate_css() {
  check_cockpit_version || return 1
  cat > "$BRANDING_CSS" <<'CSSEOF'
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
    systemctl restart cockpit
    log_to_file log_success "Cockpit 服务已重启"
  else
    log_to_file log_warning "Cockpit 服务未运行"
  fi
}

# ==================== Cron 管理 ====================
add_cron_job() {
  local cron_expr="$1"
  if cron_register "cockpit-auto-bing-wallpaper" "$cron_expr" 2>/dev/null; then
    log_to_file log_success "定时任务已添加：$cron_expr"
  else
    log_to_file log_error "定时任务注册失败"
    return 1
  fi
}

show_cron_jobs() {
  log_info "当前定时任务："
  if cron_is_registered "cockpit-auto-bing-wallpaper" 2>/dev/null; then
    cron_list 2>/dev/null | grep "cockpit-auto-bing-wallpaper" || log_info "已注册（使用 debnas cron list 查看）"
  else
    echo "(无定时任务)"
  fi
}

# ==================== 启用/禁用 ====================
enable_bing_wallpaper() {
  check_cockpit_version || return 1
  local cron_expr

  if [[ -t 0 ]]; then
    print_prompt "请输入 Cron 表达式（默认每天0点更新）: "
    read -r cron_expr
    [[ -z "$cron_expr" ]] && cron_expr="0 0 * * *"
  else
    cron_expr="0 0 * * *"
    log_info "非交互式模式，使用默认 Cron：$cron_expr"
  fi

  prepare_env
  add_cron_job "$cron_expr"
  create_script_copy

  if update_wallpaper; then
    generate_css
    restart_cockpit
    log_to_file log_success "壁纸功能已启用"
  else
    log_to_file log_error "壁纸下载失败"
  fi
}

disable_bing_wallpaper() {
  cron_unregister "cockpit-auto-bing-wallpaper" 2>/dev/null || true
  rm -rf "$BRANDING_DIR"
  echo "基于Debian搭建 HomeNAS" > "$ISSUE_FILE"
  restart_cockpit
  log_to_file log_success "壁纸功能已禁用"
}

# ==================== 自动更新模式（cron 调用） ====================
auto_update_mode() {
  if update_wallpaper; then
    generate_css
    restart_cockpit
  fi
}

# ==================== 交互菜单 ====================
main_menu() {
  local -a menu_options=("启用必应壁纸" "禁用必应壁纸" "查看壁纸计划")

  while true; do
    show_menu_with_border "Cockpit 必应壁纸" "${menu_options[@]}"
    print_prompt "请选择编号: "
    read -r choice

    if [[ ! "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 0 ]] || [[ "$choice" -gt "${#menu_options[@]}" ]]; then
      log_error "无效选择，请输入 0-${#menu_options[@]}"
      continue
    fi

    case "$choice" in
      1) enable_bing_wallpaper ;;
      2) disable_bing_wallpaper ;;
      3) show_cron_jobs ;;
      0) break ;;
    esac
    echo ""
  done
}

# ==================== 主入口 ====================
main() {
  if [[ "${1:-}" == "--auto" ]] || [[ -n "${CRON:-}" ]]; then
    auto_update_mode
  elif [[ "${1:-}" == "--cron" ]]; then
    auto_update_mode
  elif [[ -t 0 ]]; then
    main_menu
  else
    log_info "非交互式调用，启用必应壁纸"
    enable_bing_wallpaper
  fi
}

main "$@"
