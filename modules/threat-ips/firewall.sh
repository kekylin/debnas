#!/bin/bash
# threat-ips: Firewalld 集成模块

set -euo pipefail
IFS=$'\n\t'

reload_firewalld() {
  local need_reload="${1:-0}"
  if [[ ${need_reload} -eq 1 ]]; then
    local cmd_output
    if ! cmd_output=$(firewall-cmd --reload 2>&1); then
      log_error "Firewalld 规则重载失败：${cmd_output}"
      return 1
    fi
    log_success "Firewalld 规则重载成功"
    # --reload 会清空 fail2ban（firewallcmd-ipset）写入的运行时规则，重启 fail2ban 让封禁恢复
    if service_is_active fail2ban; then
      service_ensure fail2ban restarted \
        || log_warning "Fail2ban 重启失败，其封禁规则可能未恢复，请手动重启 fail2ban"
    fi
  fi
}


# 把待移除条目分成两组：与待新增条目重叠的（必须先删，否则 firewalld 判重叠拒绝新增）与其余的
# 参数：$1 - 待新增文件，$2 - 待移除文件，$3/$4 - 输出：先删组 / 后删组
_split_conflicting_removals() {
  local add_file="$1" del_file="$2" first_file="$3" rest_file="$4"
  {
    LC_ALL=C awk "${_THREAT_NET_AWK}"'netparse($1) { printf "%s %03d A %s\n", NKEY, NM, $1 }' "${add_file}"
    LC_ALL=C awk "${_THREAT_NET_AWK}"'{ if (netparse($1)) printf "%s %03d D %s\n", NKEY, NM, $1; else printf "~ 999 D %s\n", $1 }' "${del_file}"
  } | LC_ALL=C sort -k1,1 -k2,2n -k3,3 | LC_ALL=C awk -v first="${first_file}" -v rest="${rest_file}" "${_THREAT_NET_AWK}"'
    # 按网络地址、前缀升序扫描，栈中保存包含当前条目的上级网段；A/D 互为祖先即重叠
    {
      k = $1; m = $2 + 0; t = $3; o = $4
      if (k == "~") { dl[++nd] = o; next }
      while (sp > 0 && !netcontains(SK[sp], SM[sp], k, m)) { if (ST[sp] == "A") na--; sp-- }
      if (t == "D") { dl[++nd] = o; if (na > 0) hit[o] = 1 }
      else for (i = 1; i <= sp; i++) if (ST[i] == "D") hit[SO[i]] = 1
      sp++; SK[sp] = k; SM[sp] = m; ST[sp] = t; SO[sp] = o
      if (t == "A") na++
    }
    END {
      printf "" > first; printf "" > rest
      for (i = 1; i <= nd; i++) print dl[i] > (dl[i] in hit ? first : rest)
    }
  '
}

# 将单个 IPSet 增量同步为目标列表（只删多余、只加缺失），永久与运行时配置分别处理
# 顺序：先删与新条目重叠的旧条目 → 新增 → 再删其余过期条目；新增失败时不做后续移除，并把先删的旧条目加回，
#       避免出现"旧的已删、新的没加上"的封禁空窗
# 不使用 --reload：重载会清空 fail2ban 等组件写入的运行时规则
sync_ipset_entries() {
  local ipset_name="$1" new_file="$2" ip_type="$3"
  local old_file add_file del_file first_file rest_file scope add_count=0 del_count=0
  old_file=$(create_temp_file "ipset_old" ".txt") || return 1
  add_file=$(create_temp_file "ipset_add" ".txt") || return 1
  del_file=$(create_temp_file "ipset_del" ".txt") || return 1
  first_file=$(create_temp_file "ipset_del_first" ".txt") || return 1
  rest_file=$(create_temp_file "ipset_del_rest" ".txt") || return 1
  LC_ALL=C sort -u "${new_file}" -o "${new_file}"

  for scope in permanent runtime; do
    local -a scope_args=()
    if [[ "${scope}" == "permanent" ]]; then
      scope_args=(--permanent)
    fi
    if ! firewall-cmd "${scope_args[@]}" --ipset="${ipset_name}" --get-entries \
      > "${old_file}" 2>/dev/null; then
      log_error "读取 ${ip_type} IPSet（${scope}）失败：${ipset_name}"
      return 1
    fi
    tr ' ' '\n' < "${old_file}" | awk 'NF' | LC_ALL=C sort -u > "${old_file}.sorted"
    mv "${old_file}.sorted" "${old_file}"
    LC_ALL=C comm -23 "${old_file}" "${new_file}" > "${del_file}"
    LC_ALL=C comm -13 "${old_file}" "${new_file}" > "${add_file}"
    : > "${first_file}"
    cp "${del_file}" "${rest_file}"
    if [[ -s "${add_file}" && -s "${del_file}" ]]; then
      _split_conflicting_removals "${add_file}" "${del_file}" "${first_file}" "${rest_file}"
    fi

    if [[ -s "${first_file}" ]] && ! firewall-cmd "${scope_args[@]}" --ipset="${ipset_name}" \
      --remove-entries-from-file="${first_file}" &>/dev/null; then
      log_error "从 ${ip_type} IPSet（${scope}）移除与新条目重叠的旧条目失败：${ipset_name}（现有封禁保持不变）"
      return 1
    fi
    if [[ -s "${add_file}" ]] && ! firewall-cmd "${scope_args[@]}" --ipset="${ipset_name}" \
      --add-entries-from-file="${add_file}" &>/dev/null; then
      log_error "向 ${ip_type} IPSet（${scope}）添加条目失败：${ipset_name}（未移除旧条目）"
      if [[ -s "${first_file}" ]] && ! firewall-cmd "${scope_args[@]}" --ipset="${ipset_name}" \
        --add-entries-from-file="${first_file}" &>/dev/null; then
        log_warning "恢复已移除的 $(wc -l < "${first_file}") 条重叠旧条目失败：${ipset_name}"
      fi
      return 1
    fi
    if [[ -s "${rest_file}" ]] && ! firewall-cmd "${scope_args[@]}" --ipset="${ipset_name}" \
      --remove-entries-from-file="${rest_file}" &>/dev/null; then
      log_error "从 ${ip_type} IPSet（${scope}）移除过期条目失败：${ipset_name}（新条目已添加）"
      return 1
    fi
    if [[ "${scope}" == "permanent" ]]; then
      add_count=$(wc -l < "${add_file}")
      del_count=$(wc -l < "${del_file}")
    fi
  done
  rm -f "${old_file}" "${add_file}" "${del_file}" "${first_file}" "${rest_file}"
  log_info "${ip_type} IPSet 已同步：共 $(wc -l < "${new_file}") 条（新增 ${add_count}，移除 ${del_count}）"
}

# 剔除受保护地址、合并重叠条目后去重排序单个 IP 类型文件
_process_single_ip_file() {
  local temp_file="$1" output_file="$2" ip_type="$3"
  if ! filter_protected_entries "${temp_file}" "${ip_type}"; then
    return 1
  fi
  if ! merge_overlapping_entries "${temp_file}" "${ip_type}"; then
    return 1
  fi
  if ! deduplicate_and_sort_ips "${temp_file}" "${output_file}"; then
    return 1
  fi
  check_and_limit_ip_count "${output_file}" "${ip_type}" >/dev/null
}

# 处理 IP 列表：解析、剔除受保护地址、去重、排序、限制数量（只生成文件，不改防火墙）
# 返回：0 得到非空的有效列表；1 列表为空/全部无效（调用方应保留现有封禁）
process_ip_list() {
  local input_file="$1" output_file_ipv4="$2" output_file_ipv6="$3"
  local temp_file_ipv4 temp_file_ipv6 temp_input

  temp_file_ipv4=$(create_temp_file "expanded_ips_ipv4" ".txt")
  temp_file_ipv6=$(create_temp_file "expanded_ips_ipv6" ".txt")
  : > "${temp_file_ipv4}"
  : > "${temp_file_ipv6}"

  temp_input=$(prepare_input_file "${input_file}") || return 1

  if ! parse_ip_entries "${temp_input}" "${temp_file_ipv4}" "${temp_file_ipv6}"; then
    return 1
  fi

  if [[ ! -s "${temp_file_ipv4}" && ! -s "${temp_file_ipv6}" ]]; then
    log_error "无有效 IP（请检查输入格式）"
    return 1
  fi

  _process_single_ip_file "${temp_file_ipv4}" "${output_file_ipv4}" "IPv4" \
    || return 1
  _process_single_ip_file "${temp_file_ipv6}" "${output_file_ipv6}" "IPv6" \
    || return 1

  if [[ ! -s "${output_file_ipv4}" && ! -s "${output_file_ipv6}" ]]; then
    log_error "过滤后无可封禁的 IP"
    return 1
  fi
}

apply_ip_changes() {
  local ip_file="$1" ipset_name="$2" mode="$3"
  local ip_count_before

  if ! check_ipset_exists "${ipset_name}"; then
    log_error "IPSet 不存在：${ipset_name}"
    return 1
  fi

  if ! sort -u "${ip_file}" > "${ip_file}.tmp" 2>/dev/null; then
    log_error "去重失败：${ip_file}"
    return 1
  fi
  mv "${ip_file}.tmp" "${ip_file}"
  ip_count_before=$(wc -l < "${ip_file}")

  if [[ ${ip_count_before} -eq 0 ]]; then
    log_info "输入文件为空，无需${mode}操作"
    return 0
  fi

  if [[ "${mode}" == "add" ]]; then
    if [[ ${ip_count_before} -gt ${MAX_IP_LIMIT} ]]; then
      log_warning \
        "输入条目数超过 IPSet 上限：${ipset_name}（${ip_count_before} > ${MAX_IP_LIMIT}）"
      return 1
    fi
    if ! firewall-cmd --permanent \
      --ipset="${ipset_name}" \
      --add-entries-from-file="${ip_file}" &>/dev/null; then
      log_error "添加 IP 到 IPSet 失败：${ipset_name}"
      return 1
    fi
  elif [[ "${mode}" == "remove" ]]; then
    if ! firewall-cmd --permanent \
      --ipset="${ipset_name}" \
      --remove-entries-from-file="${ip_file}" &>/dev/null; then
      log_error "从 IPSet 移除 IP 失败：${ipset_name}"
      return 1
    fi
  fi
}


remove_ips_from_single_ipset() {
  local ipset_name="$1" temp_file="$2" ip_type="$3"
  local sources
  sources=$(firewall-cmd --permanent \
    --ipset="${ipset_name}" --get-entries 2>/dev/null)
  if [[ -z "${sources}" ]]; then
    return 0
  fi
  printf "%s" "${sources}" | tr ' ' '\n' > "${temp_file}"
  apply_ip_changes "${temp_file}" "${ipset_name}" "remove" || {
    log_warning "移除 ${ip_type} IP 失败，继续执行清理"
  }
}

remove_ips_from_ipsets() {
  local temp_ipv4 temp_ipv6
  temp_ipv4=$(create_temp_file "remove_ipv4" ".txt")
  temp_ipv6=$(create_temp_file "remove_ipv6" ".txt")
  remove_ips_from_single_ipset "${IPSET_NAME_IPV4}" "${temp_ipv4}" "IPv4"
  remove_ips_from_single_ipset "${IPSET_NAME_IPV6}" "${temp_ipv6}" "IPv6"
}

# 从区域解绑单个 IPSet（返回：0 需要重载，1 无需重载）
unbind_single_ipset_from_zone() {
  local ipset_name="$1" ip_type="$2"
  local ipset_bound need_reload=0
  ipset_bound=$(firewall-cmd --permanent --zone=drop --list-sources \
    | grep -w "ipset:${ipset_name}" || true)
  if [[ -z "${ipset_bound}" ]]; then
    return 0
  fi
  log_info "从 drop 区域解绑 ${ip_type} IPSet"
  if firewall-cmd --permanent --zone=drop \
    --remove-source="ipset:${ipset_name}" &>/dev/null; then
    need_reload=1
  else
    log_warning "解绑 ${ip_type} IPSet 失败，继续执行清理"
  fi
  [[ ${need_reload} -eq 1 ]]
}

unbind_ipsets_from_zone() {
  local need_reload=0
  if unbind_single_ipset_from_zone "${IPSET_NAME_IPV4}" "IPv4"; then
    need_reload=1
  fi
  if unbind_single_ipset_from_zone "${IPSET_NAME_IPV6}" "IPv6"; then
    need_reload=1
  fi
  [[ ${need_reload} -eq 1 ]]
}

delete_single_ipset() {
  local ipset_name="$1" ip_type="$2" need_reload=0
  local ipset_old_file="/etc/firewalld/ipsets/${ipset_name}.xml.old"

  if ! check_ipset_exists "${ipset_name}"; then
    if [[ -f "${ipset_old_file}" ]]; then
      rm -f "${ipset_old_file}" 2>/dev/null || true
    fi
    return 0
  fi
  log_info "删除 ${ip_type} IPSet：${ipset_name}"
  if firewall-cmd --permanent --delete-ipset="${ipset_name}" &>/dev/null; then
    need_reload=1
    if [[ -f "${ipset_old_file}" ]]; then
      rm -f "${ipset_old_file}" 2>/dev/null || true
    fi
  else
    log_warning "删除 ${ip_type} IPSet 失败，继续执行清理"
  fi
  [[ ${need_reload} -eq 1 ]]
}

delete_ipsets() {
  local need_reload=0
  if delete_single_ipset "${IPSET_NAME_IPV4}" "IPv4"; then
    need_reload=1
  fi
  if delete_single_ipset "${IPSET_NAME_IPV6}" "IPv6"; then
    need_reload=1
  fi
  [[ ${need_reload} -eq 1 ]]
}

# 清理 drop 区域配置：仅在区域完全清空时删除自定义配置文件
cleanup_drop_zone_config() {
  local drop_xml_file="/etc/firewalld/zones/drop.xml"
  local remaining_sources drop_zone_info need_reload=0

  remaining_sources=$(firewall-cmd --permanent --zone=drop --list-sources \
    2>/dev/null | grep -v "^$" || true)
  drop_zone_info=$(firewall-cmd --permanent --zone=drop --list-all \
    2>/dev/null || true)

  # 非空的 services/ports/protocols/rich rules 行（为空时 firewall-cmd 输出 "  services: "）
  local has_rules
  has_rules=$(grep -E '^  (services|ports|protocols|rich rules):' <<< "${drop_zone_info}" \
    | grep -vE '^  (services|ports|protocols|rich rules): $' || true)

  if [[ -z "${remaining_sources}" && -z "${has_rules}" ]]; then
    if [[ -f "${drop_xml_file}" ]]; then
      log_info \
        "drop 区域已清空，删除自定义配置文件：${drop_xml_file}"
      if rm -f "${drop_xml_file}"; then
        need_reload=1
        local drop_old_file="/etc/firewalld/zones/drop.xml.old"
        if [[ -f "${drop_old_file}" ]]; then
          rm -f "${drop_old_file}" 2>/dev/null || true
        fi
      else
        log_warning \
          "删除 drop 区域配置文件失败：${drop_xml_file}，继续执行清理"
      fi
    fi
  elif [[ -n "${remaining_sources}" ]]; then
    log_info "drop 区域仍有其他 sources，保留配置文件"
  fi
  [[ ${need_reload} -eq 1 ]]
}

remove_all_ips() {
  local need_reload=0

  if ! check_ipset_exists "${IPSET_NAME_IPV4}" \
    && ! check_ipset_exists "${IPSET_NAME_IPV6}"; then
    log_info "未配置 IPSet"
    return 0
  fi

  remove_ips_from_ipsets

  if unbind_ipsets_from_zone; then
    need_reload=1
  fi
  if delete_ipsets; then
    need_reload=1
  fi
  if cleanup_drop_zone_config; then
    need_reload=1
  fi

  reload_firewalld ${need_reload} || {
    log_warning "Firewalld 重载失败，但继续执行清理"
  }
  log_success "已移除所有封禁 IP"
}


filter_and_add_ips() {
  local temp_txt="$1" temp_file_ipv4="$2" temp_file_ipv6="$3"
  local need_reload=0

  [[ ! -f "${temp_txt}" ]] && {
    log_error "IP 列表文件不存在：${temp_txt}"
    return 1
  }

  # 先解析出新列表；为空或失败时直接返回，绝不先清空现有封禁
  if ! process_ip_list "${temp_txt}" "${temp_file_ipv4}" "${temp_file_ipv6}"; then
    log_error "处理 IP 列表失败，保留现有封禁列表"
    return 1
  fi

  # 仅在新建/绑定 IPSet 或运行时缺失 IPSet 时重载（结构变更只能经重载进入运行时）
  if configure_ipset; then
    need_reload=1
  fi
  local runtime_ipsets
  runtime_ipsets=$(firewall-cmd --get-ipsets 2>/dev/null) || runtime_ipsets=""
  if ! grep -qw "${IPSET_NAME_IPV4}" <<< "${runtime_ipsets}" \
    || ! grep -qw "${IPSET_NAME_IPV6}" <<< "${runtime_ipsets}"; then
    need_reload=1
  fi
  if ! reload_firewalld ${need_reload}; then
    log_error "Firewalld 重载失败"
    return 1
  fi

  sync_ipset_entries "${IPSET_NAME_IPV4}" "${temp_file_ipv4}" "IPv4" || return 1
  sync_ipset_entries "${IPSET_NAME_IPV6}" "${temp_file_ipv6}" "IPv6" || return 1
  log_success "威胁 IP 列表已更新（未重载防火墙）"
}

