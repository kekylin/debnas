#!/bin/bash
# Cockpit 外网访问 — 启用/禁用逻辑

set -euo pipefail
IFS=$'\n\t'

enable_cockpit_ext() {
  local -a REQUIRED_CMDS=(hostname awk sed systemctl)
  local domain internal_ip origins_line current_config new_config=""
  local config_file="/etc/cockpit/cockpit.conf"
  if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
    log_error "依赖缺失，请先安装 hostname、awk、sed、systemctl。"
    return 1
  fi

  # EOF 时 read 返回非零，不能让 set -e 直接退出整个工具
  read -r -p "Cockpit 外网访问地址（如 baidu.com 或 baidu.com:9090）：" domain || domain=""
  domain="${domain#http://}"
  domain="${domain#https://}"
  domain="${domain%%/*}"

  if [[ -z "$domain" ]]; then
    log_error "域名不能为空，请重新执行并输入有效地址。"
    return 1
  fi
  if [[ ! "$domain" =~ ^[][a-zA-Z0-9._:-]+$ ]]; then
    log_error "域名格式无效：${domain}，仅允许字母、数字、点、连字符、冒号和方括号。"
    return 1
  fi
  # 裸 IPv6 地址（含两个及以上冒号且无方括号）需加方括号才能构成合法 URL
  if [[ "$domain" == *:*:* && "$domain" != \[* ]]; then
    domain="[${domain}]"
  fi

  internal_ip=$(hostname -I 2>/dev/null | awk '{print $1}') || internal_ip=""
  if [[ "$internal_ip" == *:* ]]; then
    internal_ip="[${internal_ip}]"
  fi
  log_info "配置 Cockpit 外网访问地址：$domain"

  origins_line="Origins = https://$domain wss://$domain${internal_ip:+ https://$internal_ip:9090}"

  if [[ -f "$config_file" ]]; then
    current_config=$(cat "$config_file")
    # 只认未注释的 Origins 配置行，注释行不算已配置
    if grep -qE '^[[:space:]]*Origins[[:space:]]*=' <<< "$current_config"; then
      new_config=$(sed -E "s#^[[:space:]]*Origins[[:space:]]*=.*#$origins_line#" <<< "$current_config")
    else
      if grep -q '\[WebService\]' <<< "$current_config"; then
        new_config=$(sed "/\[WebService\]/a $origins_line" <<< "$current_config")
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

  local wrc=0
  write_file_if_changed "$config_file" "$new_config" || wrc=$?
  if [[ "$wrc" -eq 0 ]]; then
    log_info "Origins 配置已更新。"
    if service_ensure "cockpit" "restarted"; then
      log_success "外网访问已启用"
    else
      log_warning "Cockpit 服务重启失败，请手动重启。"
    fi
  elif [[ "$wrc" -eq 2 ]]; then
    log_error "写入 ${config_file} 失败"
    return 1
  else
    log_info "配置未变更，跳过重启。"
  fi

  log_success "https://$domain"
  module_mark_action
}

disable_cockpit_ext() {
  local -a REQUIRED_CMDS=(sed systemctl)
  local config_file="/etc/cockpit/cockpit.conf" config_changed=0 current_config new_config
  if ! check_dependencies "${REQUIRED_CMDS[@]}"; then
    log_error "依赖缺失，请先安装 sed、systemctl。"
    return 1
  fi

  if [[ -f "$config_file" ]]; then
    current_config=$(cat "$config_file")
    # 只删除未注释的 Origins 配置行，保留注释与其他段落
    new_config=$(sed -E '/^[[:space:]]*Origins[[:space:]]*=/d' <<< "$current_config")
    if [[ -z "$new_config" ]]; then
      # write_file_if_changed 不接受空内容：只剩 Origins 时保留空的 [WebService] 段
      new_config="[WebService]"
    fi
    local wrc=0
    write_file_if_changed "$config_file" "$new_config" || wrc=$?
    if [[ "$wrc" -eq 0 ]]; then
      config_changed=1
      log_success "已删除 Cockpit 外网访问配置。"
    elif [[ "$wrc" -eq 2 ]]; then
      log_error "写入 ${config_file} 失败"
      return 1
    else
      log_info "未检测到外网访问参数，跳过操作。"
    fi
  else
    log_info "未检测到 Cockpit 配置文件，跳过操作。"
  fi

  if [[ "$config_changed" -eq 1 ]]; then
    if service_ensure "cockpit" "restarted"; then
      log_success "已移除外网域名的 Origins 白名单（经反向代理/不同域名的访问将被拒绝）"
      module_mark_action
    else
      log_warning "Cockpit 服务重启失败，请手动重启。"
    fi
  fi
  # Origins 只校验跨域来源：路由器端口映射直连 9090 属于同源访问，删除 Origins 拦不住
  log_warning "如通过路由器端口映射直接访问 9090，请同时删除路由器上的端口映射，或在防火墙中限制 cockpit 的来源网段。"
}
