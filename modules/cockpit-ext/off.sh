#!/bin/bash
# Cockpit 外网访问 — 禁用逻辑

disable_cockpit_ext() {
  REQUIRED_CMDS=(sed systemctl)
  if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
    log_error "依赖缺失，请先安装 sed、systemctl。"
    return 1
  fi

  config_file="/etc/cockpit/cockpit.conf"
  config_changed=0
  if [[ -f "$config_file" ]]; then
    current_config=$(cat "$config_file")
    new_config=$(echo "$current_config" | sed '/Origins/d')
    if write_file_if_changed "$config_file" "$new_config"; then
      config_changed=1
      log_success "已删除 Cockpit 外网访问配置。"
    else
      log_info "未检测到外网访问参数，跳过操作。"
    fi
  else
    log_info "未检测到 Cockpit 配置文件，跳过操作。"
  fi

  if [[ "$config_changed" -eq 1 ]]; then
    if service_ensure "cockpit" "restarted"; then
      log_success "外网访问已禁用"
    else
      log_warning "Cockpit 服务重启失败，请手动重启。"
    fi
  fi
}
