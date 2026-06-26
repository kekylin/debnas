#!/bin/bash
# cockpit-auto-bing-wallpaper: Cockpit 集成模块
set -euo pipefail
IFS=$'\n\t'
prepare_env() {
  install -d -m 755 "$BRANDING_DIR"
}

create_script_copy() {
  cp "$SELF_PATH" "$SCRIPT_COPY"
  chmod +x "$SCRIPT_COPY"
}

# 壁纸下载与更新

generate_css() {
  check_cockpit_version || return 1
  cat > "$BRANDING_CSS" <<EOF
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

/* 中等屏幕（平板等）调整横幅位置，减小与登录框冲突概率 */
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

/* 小屏幕（手机等）响应式适配 */
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
EOF
}

# Cockpit 服务重启
restart_cockpit() {
  if systemctl is-active --quiet cockpit; then
    systemctl restart cockpit
    log_to_file log_success "Cockpit 服务已重启"
  else
    log_to_file log_warning "Cockpit 服务未运行"
  fi
}


disable_bing_wallpaper() {
  cron_unregister "cockpit-auto-bing-wallpaper" 2>/dev/null || true
  rm -rf "$BRANDING_DIR"
  echo "基于Debian搭建 HomeNAS" > "$ISSUE_FILE"
  restart_cockpit
  log_to_file log_success "壁纸功能已禁用"
}

show_cron_jobs() {
  log_info "当前定时任务："
  if cron_is_registered "cockpit-auto-bing-wallpaper" 2>/dev/null; then
    cron_list 2>/dev/null | grep "cockpit-auto-bing-wallpaper" || log_info "已注册（使用 debnas cron list 查看）"
  else
    echo "(无定时任务)"
  fi
}

# 功能启用
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
  
  if update_wallpaper; then
    generate_css
    restart_cockpit
    log_to_file log_success "壁纸功能已启用"
  else
    log_to_file log_error "壁纸下载失败"
  fi
}

# 自动化更新模式
