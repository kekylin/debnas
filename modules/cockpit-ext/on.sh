#!/bin/bash
# Cockpit 外网访问 — 启用逻辑

enable_cockpit_ext() {
  REQUIRED_CMDS=(hostname awk sed systemctl)
  if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
    log_error "依赖缺失，请先安装 hostname、awk、sed、systemctl。"
    return 1
  fi

  read -r -p "Cockpit 外网访问地址（如 baidu.com 或 baidu.com:9090）：" domain
  config_file="/etc/cockpit/cockpit.conf"
  domain="${domain#http://}"
  domain="${domain#https://}"
  domain="${domain%%/*}"

  if [[ -z "$domain" ]]; then
    log_error "域名不能为空，请重新执行并输入有效地址。"
    return 1
  fi
  if [[ ! "$domain" =~ ^[a-zA-Z0-9._:-]+$ ]]; then
    log_error "域名格式无效：${domain}，仅允许字母、数字、点、连字符和冒号。"
    return 1
  fi

  internal_ip=$(hostname -I | awk '{print $1}')
  log_info "配置 Cockpit 外网访问地址：$domain"

  origins_line="Origins = https://$domain wss://$domain https://$internal_ip:9090"
  new_config=""

  if [[ -f "$config_file" ]]; then
    current_config=$(cat "$config_file")
    if echo "$current_config" | grep -q "Origins"; then
      new_config=$(echo "$current_config" | sed "s#^Origins = .*#$origins_line#")
    else
      if echo "$current_config" | grep -q '\[WebService\]'; then
        new_config=$(echo "$current_config" | sed "/\[WebService\]/a $origins_line")
      else
        new_config="$current_config

[WebService]
$origins_line"
      fi
    fi
  else
    new_config="[WebService]
$origins_line"
  fi

  if write_file_if_changed "$config_file" "$new_config"; then
    log_info "Origins 配置已更新。"
    if service_ensure "cockpit" "restarted"; then
      log_success "外网访问已启用"
    else
      log_warning "Cockpit 服务重启失败，请手动重启。"
    fi
  else
    log_info "配置未变更，跳过重启。"
  fi

  log_success "https://$domain"
}
